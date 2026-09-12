import XCTest
import SwiftData
@testable import TrackGym

@MainActor
final class TrackGymTests: XCTestCase {
    private var container: ModelContainer!

    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let schema = Schema([
            Exercise.self,
            Workout.self,
            WorkoutEntry.self,
            WorkoutSet.self,
            WorkoutPlan.self,
            SeedVersion.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - WorkoutEntry computed properties

    func test_maxWeight_returnsHighestWeightAcrossSets() throws {
        let entry = makeEntry(weights: [(1, 60, 10), (2, 80, 8), (3, 70, 9)])
        XCTAssertEqual(entry.maxWeight, 80, accuracy: 0.001)
    }

    func test_maxWeight_isZero_whenNoSets() throws {
        let entry = makeEntry(weights: [])
        XCTAssertEqual(entry.maxWeight, 0)
    }

    func test_totalVolume_sumsWeightTimesReps() throws {
        let entry = makeEntry(weights: [(1, 60, 10), (2, 80, 8)])
        XCTAssertEqual(entry.totalVolume, 60 * 10 + 80 * 8, accuracy: 0.001)
    }

    func test_weightUnit_convertsStoredKilogramsForDisplay() throws {
        let set = WorkoutSet(setNumber: 1, weight: 100, reps: 5)
        XCTAssertEqual(set.weight(in: .kg), 100, accuracy: 0.001)
        XCTAssertEqual(set.weight(in: .lbs), 220.462, accuracy: 0.001)
    }

    func test_workoutSetStoresPoundsAsKilograms() throws {
        let set = WorkoutSet(setNumber: 1, weight: 220.462, reps: 5, unit: .lbs)
        XCTAssertEqual(set.weight, 100, accuracy: 0.001)

        set.setWeight(110, unit: .lbs)
        XCTAssertEqual(set.weight, 49.895, accuracy: 0.001)
    }

    func test_sortedSets_ordersBySetNumber() throws {
        let entry = makeEntry(weights: [(3, 70, 9), (1, 60, 10), (2, 80, 8)])
        XCTAssertEqual(entry.sortedSets.map(\.setNumber), [1, 2, 3])
    }

    func test_hasValidSets_acceptsCompletedWeightedAndBodyweightSets() {
        let entry = makeEntry(weights: [(1, 0, 12), (2, 80, 8)])
        XCTAssertTrue(entry.hasValidSets)
    }

    func test_hasValidSets_rejectsEmptyAndUnfinishedEntries() {
        XCTAssertFalse(makeEntry(weights: []).hasValidSets)
        XCTAssertFalse(makeEntry(weights: [(1, 50, 0)]).hasValidSets)
    }

    func test_hasValidSets_rejectsNegativeAndNonfiniteValues() {
        for weight in [-1.0, Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(makeEntry(weights: [(1, weight, 10)]).hasValidSets)
        }
        XCTAssertFalse(makeEntry(weights: [(1, 50, -1)]).hasValidSets)
    }

    func test_hasValidSets_rejectsOverflowingSetAndEntryVolume() {
        XCTAssertFalse(makeEntry(weights: [(1, .greatestFiniteMagnitude, 2)]).hasValidSets)
        let largeWeight = Double.greatestFiniteMagnitude * 0.75
        XCTAssertFalse(makeEntry(weights: [(1, largeWeight, 1), (2, largeWeight, 1)]).hasValidSets)
    }

    // MARK: - DefaultExercises seeding

    func test_seed_insertsAllExercisesOnFirstRun() throws {
        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()

        let count = try context.fetch(FetchDescriptor<Exercise>()).count
        XCTAssertEqual(count, DefaultExercises.exercises.count)
    }

    func test_seed_doesNotDuplicateOnSecondRun() throws {
        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()
        let firstCount = try context.fetch(FetchDescriptor<Exercise>()).count

        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()
        let secondCount = try context.fetch(FetchDescriptor<Exercise>()).count

        XCTAssertEqual(firstCount, secondCount)
    }

    func test_seed_doesNotDuplicateCustomExerciseThatDiffersOnlyInCase() throws {
        // AddExerciseView and the importer treat names case-insensitively;
        // the seed must agree, or a later seed version produces a pair the
        // importer then rejects as duplicates.
        let defaultName = try XCTUnwrap(DefaultExercises.exercises.first?.name)
        let custom = Exercise(name: defaultName.lowercased(), muscleGroup: .chest, equipmentType: .machine, isCustom: true)
        context.insert(custom)
        try context.save()

        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()

        let matching = try context.fetch(FetchDescriptor<Exercise>())
            .filter { Exercise.normalizedName($0.name) == Exercise.normalizedName(defaultName) }
        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(matching.first?.isCustom == true, "the user's exercise wins over the seed")
    }

    func test_resetSeedFlag_allowsReSeedingAfterWipe() throws {
        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()
        for exercise in try context.fetch(FetchDescriptor<Exercise>()) {
            context.delete(exercise)
        }
        try context.save()

        DefaultExercises.resetSeedFlag(context: context)
        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()

        let count = try context.fetch(FetchDescriptor<Exercise>()).count
        XCTAssertEqual(count, DefaultExercises.exercises.count)
    }

    // MARK: - Seed flag rollback (MHE-24)

    func test_seedVersion_isPersistedInSwiftData() throws {
        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<SeedVersion>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.version, DefaultExercises.currentSeedVersion)
    }

    func test_rollback_reverts_unsavedSeedVersionUpsert() throws {
        // Simulates the SettingsView delete-all flow where the re-seed save
        // throws and rollback() must revert the seed-version marker too.
        DefaultExercises.seedDefaultExercises(context: context)
        context.rollback()

        let rows = try context.fetch(FetchDescriptor<SeedVersion>())
        XCTAssertTrue(rows.isEmpty)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertTrue(exercises.isEmpty)
    }

    func test_seed_bailsOut_whenSeedVersionAlreadyAtCurrent() throws {
        context.insert(SeedVersion(version: DefaultExercises.currentSeedVersion))
        try context.save()

        DefaultExercises.seedDefaultExercises(context: context)
        try context.save()

        let count = try context.fetch(FetchDescriptor<Exercise>()).count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Exercise identity

    func test_backfillStableIDs_assignsMissingExerciseIDs() throws {
        let exercise = Exercise(name: "Legacy Bench", muscleGroup: .chest, equipmentType: .freeWeight)
        exercise.stableID = nil
        context.insert(exercise)
        try context.save()

        try Exercise.backfillStableIDs(context: context)

        XCTAssertNotNil(exercise.stableID)
    }

    // MARK: - DataExporter round-trip

    func test_export_then_import_preservesExercises() throws {
        let custom = Exercise(name: "Custom Bench", muscleGroup: .chest, equipmentType: .freeWeight, isCustom: true)
        let machine = Exercise(name: "Leg Press", muscleGroup: .legs, equipmentType: .machine)
        context.insert(custom)
        context.insert(machine)
        try context.save()

        let exported = try DataExporter.exportData(context: context)
        try DataExporter.importData(from: exported, context: context)

        let names = try context.fetch(FetchDescriptor<Exercise>()).map(\.name).sorted()
        XCTAssertEqual(names, ["Custom Bench", "Leg Press"])
    }

    func test_export_then_import_preservesWorkoutWithSets() throws {
        let exercise = Exercise(name: "Squat", muscleGroup: .legs, equipmentType: .freeWeight)
        context.insert(exercise)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = Workout(name: "Leg Day", date: date, duration: 3600)
        context.insert(workout)

        let entry = WorkoutEntry(date: date, exercise: exercise)
        entry.workout = workout
        context.insert(entry)

        let s1 = WorkoutSet(setNumber: 1, weight: 100, reps: 5, workoutEntry: entry)
        let s2 = WorkoutSet(setNumber: 2, weight: 110, reps: 5, workoutEntry: entry)
        context.insert(s1)
        context.insert(s2)
        try context.save()

        let exported = try DataExporter.exportData(context: context)
        try DataExporter.importData(from: exported, context: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.count, 1)
        let restored = try XCTUnwrap(workouts.first)
        XCTAssertEqual(restored.name, "Leg Day")
        XCTAssertEqual(restored.duration, 3600)
        XCTAssertEqual(restored.entries.count, 1)

        let restoredEntry = try XCTUnwrap(restored.entries.first)
        XCTAssertEqual(restoredEntry.exercise?.name, "Squat")
        XCTAssertEqual(restoredEntry.sortedSets.map(\.weight), [100, 110])
        XCTAssertEqual(restoredEntry.sortedSets.map(\.reps), [5, 5])
    }

    func test_import_usesExerciseIDBeforeLegacyName() throws {
        let exerciseID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ExportData(
            exercises: [
                ExportExercise(id: exerciseID.uuidString, name: "Renamed Bench", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [
                ExportWorkoutPlan(name: "Push", exerciseIDs: [exerciseID.uuidString], exerciseNames: ["Old Bench"]),
            ],
            workouts: [
                ExportWorkout(
                    name: "Push",
                    date: date,
                    duration: 1800,
                    entries: [
                        ExportWorkoutEntry(
                            exerciseID: exerciseID.uuidString,
                            exerciseName: "Old Bench",
                            date: date,
                            sets: [
                                ExportWorkoutSet(setNumber: 1, weight: 100, weightUnit: WeightUnit.kg.rawValue, reps: 5),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let restoredEntry = try XCTUnwrap(workouts.first?.entries.first)
        XCTAssertEqual(restoredEntry.exercise?.stableID, exerciseID)
        XCTAssertEqual(restoredEntry.exercise?.name, "Renamed Bench")

        let plans = try context.fetch(FetchDescriptor<WorkoutPlan>())
        XCTAssertEqual(plans.first?.exercises.first?.stableID, exerciseID)
    }

    func test_import_invalidJSON_doesNotDestroyExistingData() throws {
        let exercise = Exercise(name: "Existing", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(exercise)
        try context.save()

        let invalidData = Data("not valid json".utf8)
        XCTAssertThrowsError(try DataExporter.importData(from: invalidData, context: context))

        let names = try context.fetch(FetchDescriptor<Exercise>()).map(\.name)
        XCTAssertEqual(names, ["Existing"])
    }

    func test_import_replacesOrphanedEntriesAndDetachedSets() throws {
        let exercise = Exercise(name: "Existing", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(exercise)
        let orphan = WorkoutEntry(date: .now, exercise: exercise)
        context.insert(orphan)
        let orphanSet = WorkoutSet(setNumber: 1, weight: 50, reps: 10, workoutEntry: orphan)
        context.insert(orphanSet)
        let detachedSet = WorkoutSet(setNumber: 1, weight: 20, reps: 10)
        context.insert(detachedSet)
        try context.save()

        let data = try encodedBackup(ExportData(exercises: [], workoutPlans: [], workouts: []))
        try DataExporter.importData(from: data, context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Exercise>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutSet>()).isEmpty)
    }

    func test_import_rejectsDuplicatePlanIDsBeforeReplacingExistingData() throws {
        let existing = Exercise(name: "Existing", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(existing)
        try context.save()
        let payload = ExportData(exercises: [], workoutPlans: [
            ExportWorkoutPlan(id: "same-id", name: "Push", exerciseNames: []),
            ExportWorkoutPlan(id: "same-id", name: "Pull", exerciseNames: []),
        ], workouts: [])

        XCTAssertThrowsError(try DataExporter.importData(from: encodedBackup(payload), context: context)) { error in
            guard case DataExporterError.duplicatePlanIDs(let ids) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(ids, ["same-id"])
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).map(\.name), ["Existing"])
    }

    func test_import_rejectsInvalidWorkoutValuesBeforeReplacingExistingData() throws {
        let existing = Exercise(name: "Existing", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(existing)
        try context.save()
        let invalidSets = [
            ExportWorkoutSet(setNumber: 0, weight: 50, reps: 10),
            ExportWorkoutSet(setNumber: 1, weight: -50, reps: 10),
            ExportWorkoutSet(setNumber: 1, weight: 50, reps: -1),
            ExportWorkoutSet(setNumber: 1, weight: .greatestFiniteMagnitude, reps: 2),
        ]
        for invalidSet in invalidSets {
            let payload = ExportData(exercises: [], workoutPlans: [], workouts: [
                ExportWorkout(name: "Invalid", date: .now, duration: 60, entries: [
                    ExportWorkoutEntry(date: .now, sets: [invalidSet]),
                ]),
            ])
            XCTAssertThrowsError(try DataExporter.importData(from: encodedBackup(payload), context: context)) { error in
                guard case DataExporterError.invalidWorkoutData = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).map(\.name), ["Existing"])
        }
    }

    func test_import_rejectsNegativeDuration() throws {
        let payload = ExportData(exercises: [], workoutPlans: [], workouts: [
            ExportWorkout(name: "Invalid", date: .now, duration: -1, entries: []),
        ])
        XCTAssertThrowsError(try DataExporter.importData(from: encodedBackup(payload), context: context)) { error in
            guard case DataExporterError.invalidWorkoutData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_import_preservesLegacyZeroRepSets() throws {
        let payload = ExportData(exercises: [], workoutPlans: [], workouts: [
            ExportWorkout(name: "Legacy", date: .now, duration: 0, entries: [
                ExportWorkoutEntry(date: .now, sets: [ExportWorkoutSet(setNumber: 1, weight: 0, reps: 0)]),
            ]),
        ])
        try DataExporter.importData(from: encodedBackup(payload), context: context)
        let sets = try context.fetch(FetchDescriptor<WorkoutSet>())
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.reps, 0)
    }

    func test_import_planFallsBackToNamesForUnresolvedExerciseIDs() throws {
        let benchID = UUID()
        let payload = ExportData(exercises: [
            ExportExercise(id: benchID.uuidString, name: "Bench", muscleGroup: "chest", equipmentType: "freeWeight", isCustom: false),
            ExportExercise(name: "Row", muscleGroup: "back", equipmentType: "cable", isCustom: false),
            ExportExercise(name: "Squat", muscleGroup: "legs", equipmentType: "freeWeight", isCustom: false),
        ], workoutPlans: [
            ExportWorkoutPlan(name: "Mixed", exerciseIDs: [benchID.uuidString, UUID().uuidString, "legacy-id"], exerciseNames: ["Old Bench", "Row", "Squat"]),
        ], workouts: [])

        try DataExporter.importData(from: encodedBackup(payload), context: context)
        let plan = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkoutPlan>()).first)
        XCTAssertEqual(plan.orderedExercises.map(\.name), ["Bench", "Row", "Squat"])
    }

    func test_import_rejectsDuplicateExerciseNames_caseInsensitive() throws {
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
                ExportExercise(id: nil, name: " bench press ", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.machine.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        XCTAssertThrowsError(try DataExporter.importData(from: data, context: context)) { error in
            guard case DataExporterError.duplicateExerciseNames = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_import_rejectsDuplicateExerciseIDs() throws {
        let exerciseID = UUID().uuidString
        let payload = ExportData(
            exercises: [
                ExportExercise(id: exerciseID, name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
                ExportExercise(id: exerciseID, name: "Squat", muscleGroup: MuscleGroup.legs.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        XCTAssertThrowsError(try DataExporter.importData(from: data, context: context)) { error in
            guard case DataExporterError.duplicateExerciseIDs = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }


    func test_import_stripsHTTPExerciseImageURL() throws {
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: "http://example.com/image.png"),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(exercises.first?.imageURL)
    }

    func test_import_stripsHTTPSExerciseImageURL() throws {
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: "https://example.com/image.png"),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(exercises.first?.imageURL)
    }

    func test_import_convertsPoundBackupWeightsToStoredKilograms() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: [
                ExportWorkout(
                    name: "Push",
                    date: date,
                    duration: 1200,
                    entries: [
                        ExportWorkoutEntry(
                            exerciseID: nil,
                            exerciseName: "Bench Press",
                            date: date,
                            sets: [
                                ExportWorkoutSet(setNumber: 1, weight: 220.462, weightUnit: WeightUnit.lbs.rawValue, reps: 5),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let sets = try context.fetch(FetchDescriptor<WorkoutSet>())
        let importedSet = try XCTUnwrap(sets.first)
        XCTAssertEqual(importedSet.weight, 100, accuracy: 0.001)
        XCTAssertEqual(importedSet.weight(in: .lbs), 220.462, accuracy: 0.001)
    }

    func test_normalizedName_collapsesCaseWhitespaceAndDiacritics() {
        XCTAssertEqual(
            Exercise.normalizedName("  Bänkdrücken  "),
            Exercise.normalizedName("bankdrucken")
        )
    }

    // MARK: - WatchConnectivity payload validation

    func test_addSetPayloadValidation_acceptsReasonableValues() {
        XCTAssertTrue(PhoneConnectivityManager.isValidAddSetPayload(weight: 0, reps: 1))
        XCTAssertTrue(PhoneConnectivityManager.isValidAddSetPayload(weight: 120.5, reps: 12))
        XCTAssertTrue(PhoneConnectivityManager.isValidAddSetPayload(
            weight: PhoneConnectivityManager.maximumAcceptedWeight,
            reps: PhoneConnectivityManager.maximumAcceptedReps
        ))
    }

    func test_addSetPayloadValidation_rejectsInvalidWeight() {
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(weight: -0.5, reps: 10))
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(weight: .nan, reps: 10))
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(weight: .infinity, reps: 10))
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(
            weight: PhoneConnectivityManager.maximumAcceptedWeight + 0.5,
            reps: 10
        ))
    }

    func test_addSetPayloadValidation_rejectsInvalidReps() {
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(weight: 100, reps: 0))
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(weight: 100, reps: -1))
        XCTAssertFalse(PhoneConnectivityManager.isValidAddSetPayload(
            weight: 100,
            reps: PhoneConnectivityManager.maximumAcceptedReps + 1
        ))
    }

    // MARK: - Workout-plan link (MHE-27)

    func test_export_then_import_preservesWorkoutPlanLink() throws {
        let exercise = Exercise(name: "Squat", muscleGroup: .legs, equipmentType: .freeWeight)
        context.insert(exercise)
        let plan = WorkoutPlan(name: "Leg Day")
        plan.exercises = [exercise]
        context.insert(plan)
        let workout = Workout(name: "Leg Day", date: Date(timeIntervalSince1970: 1_700_000_000), duration: 3600)
        workout.plan = plan
        context.insert(workout)
        try context.save()

        let exported = try DataExporter.exportData(context: context)
        try DataExporter.importData(from: exported, context: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let restored = try XCTUnwrap(workouts.first)
        XCTAssertEqual(restored.plan?.name, "Leg Day")
    }

    func test_import_fallsBackToPlanName_whenFileHasNoPlanIDs() throws {
        let payload = ExportData(
            exercises: [],
            workoutPlans: [
                ExportWorkoutPlan(name: "Push", exerciseIDs: nil, exerciseNames: []),
            ],
            workouts: [
                ExportWorkout(
                    name: "Push",
                    planName: "Push",
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 600,
                    entries: []
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.first?.plan?.name, "Push")
    }

    // MARK: - WorkoutPlan exercise order

    func test_orderedExercises_followsTheOrderSetOnThePlan() throws {
        let squat = Exercise(name: "Squat", muscleGroup: .legs, equipmentType: .freeWeight)
        let bench = Exercise(name: "Bench", muscleGroup: .chest, equipmentType: .freeWeight)
        let row = Exercise(name: "Row", muscleGroup: .back, equipmentType: .cable)
        [squat, bench, row].forEach { context.insert($0) }
        let plan = WorkoutPlan(name: "Full Body")
        context.insert(plan)
        plan.setExercises([squat, row, bench])
        try context.save()

        // The relationship itself is unordered; only orderedExercises is stable.
        XCTAssertEqual(plan.orderedExercises.map(\.name), ["Squat", "Row", "Bench"])
    }

    func test_orderedExercises_appendsUnlistedExercisesAlphabetically() throws {
        // Plans written before exerciseOrderIDs existed have an empty order
        // list; they must still come out deterministic.
        let squat = Exercise(name: "Squat", muscleGroup: .legs, equipmentType: .freeWeight)
        let bench = Exercise(name: "Bench", muscleGroup: .chest, equipmentType: .freeWeight)
        let row = Exercise(name: "Row", muscleGroup: .back, equipmentType: .cable)
        [squat, bench, row].forEach { context.insert($0) }
        let plan = WorkoutPlan(name: "Legacy")
        context.insert(plan)
        plan.exercises = [squat, bench, row]
        plan.exerciseOrderIDs = [row.ensureStableID()]
        try context.save()

        XCTAssertEqual(plan.orderedExercises.map(\.name), ["Row", "Bench", "Squat"])
    }

    func test_export_then_import_preservesPlanExerciseOrder() throws {
        let squat = Exercise(name: "Squat", muscleGroup: .legs, equipmentType: .freeWeight)
        let bench = Exercise(name: "Bench", muscleGroup: .chest, equipmentType: .freeWeight)
        let row = Exercise(name: "Row", muscleGroup: .back, equipmentType: .cable)
        [squat, bench, row].forEach { context.insert($0) }
        let plan = WorkoutPlan(name: "Full Body")
        context.insert(plan)
        plan.setExercises([row, squat, bench])
        try context.save()

        let exported = try DataExporter.exportData(context: context)
        try DataExporter.importData(from: exported, context: context)

        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkoutPlan>()).first)
        XCTAssertEqual(restored.orderedExercises.map(\.name), ["Row", "Squat", "Bench"])
    }

    func test_deletePlan_nullifiesWorkoutPlanReference() throws {
        let plan = WorkoutPlan(name: "Pull")
        context.insert(plan)
        let workout = Workout(name: "Pull", date: Date(), duration: 100)
        workout.plan = plan
        context.insert(workout)
        try context.save()

        context.delete(plan)
        try context.save()

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let survivor = try XCTUnwrap(workouts.first)
        XCTAssertNil(survivor.plan)
    }

    // MARK: - Import robustness (MHE-28, MHE-29)

    func test_import_preservesUnknownMuscleGroupAndEquipmentRaw() throws {
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Neck Curls", muscleGroup: "neck", equipmentType: "resistance_band", isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let imported = try XCTUnwrap(exercises.first)
        XCTAssertEqual(imported.muscleGroupRaw, "neck")
        XCTAssertEqual(imported.equipmentTypeRaw, "resistance_band")
        XCTAssertEqual(imported.muscleGroup, .unknown)
        XCTAssertEqual(imported.equipmentType, .unknown)
    }

    func test_import_rejectsDuplicateExerciseIDs_caseInsensitive() throws {
        let exerciseID = UUID().uuidString
        let payload = ExportData(
            exercises: [
                ExportExercise(id: exerciseID.uppercased(), name: "Bench Press", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
                ExportExercise(id: exerciseID.lowercased(), name: "Squat", muscleGroup: MuscleGroup.legs.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        XCTAssertThrowsError(try DataExporter.importData(from: data, context: context)) { error in
            guard case DataExporterError.duplicateExerciseIDs = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_import_resolvesLowercaseExerciseIDReferences() throws {
        let exerciseID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ExportData(
            exercises: [
                ExportExercise(id: exerciseID.uuidString, name: "Bench", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil),
            ],
            workoutPlans: [],
            workouts: [
                ExportWorkout(
                    name: "Push",
                    date: date,
                    duration: 600,
                    entries: [
                        ExportWorkoutEntry(
                            exerciseID: exerciseID.uuidString.lowercased(),
                            exerciseName: nil,
                            date: date,
                            sets: []
                        ),
                    ]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let entry = try XCTUnwrap(workouts.first?.entries.first)
        XCTAssertEqual(entry.exercise?.stableID, exerciseID)
    }

    // MARK: - Übungs-Notizen

    func test_export_then_import_preservesExerciseNotes() throws {
        let exercise = Exercise(name: "Bench", muscleGroup: .chest, equipmentType: .freeWeight, isCustom: true)
        exercise.notes = "Sitz auf Position 4, enger Griff"
        context.insert(exercise)
        try context.save()

        let exported = try DataExporter.exportData(context: context)
        try DataExporter.importData(from: exported, context: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.first?.notes, "Sitz auf Position 4, enger Griff")
    }

    func test_import_normalizesEmptyNotesToNil() throws {
        let payload = ExportData(
            exercises: [
                ExportExercise(id: nil, name: "Bench", muscleGroup: MuscleGroup.chest.rawValue, equipmentType: EquipmentType.freeWeight.rawValue, isCustom: true, imageURL: nil, notes: "   "),
            ],
            workoutPlans: [],
            workouts: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        try DataExporter.importData(from: data, context: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(exercises.first?.notes)
    }

    // MARK: - Helpers

    private func encodedBackup(_ payload: ExportData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func makeEntry(weights: [(setNumber: Int, weight: Double, reps: Int)]) -> WorkoutEntry {
        let exercise = Exercise(name: "Test", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(exercise)
        let entry = WorkoutEntry(date: Date(), exercise: exercise)
        context.insert(entry)
        for triple in weights {
            let set = WorkoutSet(
                setNumber: triple.setNumber,
                weight: triple.weight,
                reps: triple.reps,
                workoutEntry: entry
            )
            context.insert(set)
        }
        return entry
    }
}
