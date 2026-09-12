import Foundation
import SwiftData

// MARK: - Export/Import DTOs

struct ExportData: Codable {
    var exercises: [ExportExercise]
    var workoutPlans: [ExportWorkoutPlan]
    var workouts: [ExportWorkout]
}

struct ExportExercise: Codable {
    var id: String?
    var name: String
    var muscleGroup: String
    var equipmentType: String
    var isCustom: Bool
    var imageURL: String?
    var notes: String?
}

struct ExportWorkoutPlan: Codable {
    /// File-scoped identifier so workouts can reference their plan.
    /// Only unique within one export file; not a persistent ID.
    var id: String?
    var name: String
    var exerciseIDs: [String]?
    var exerciseNames: [String]
}

struct ExportWorkout: Codable {
    var name: String
    /// References `ExportWorkoutPlan.id` within the same file. `planName` is
    /// the fallback for hand-edited files that carry no plan ids.
    var planID: String?
    var planName: String?
    var date: Date
    var duration: Int
    var entries: [ExportWorkoutEntry]
}

struct ExportWorkoutEntry: Codable {
    var exerciseID: String?
    /// Optional so entries whose exercise was deleted (or never linked) survive
    /// a round-trip without being silently dropped on import.
    var exerciseName: String?
    var date: Date
    var sets: [ExportWorkoutSet]
}

struct ExportWorkoutSet: Codable {
    var setNumber: Int
    var weight: Double
    var weightUnit: String?
    var reps: Int

    var resolvedWeightUnit: WeightUnit {
        weightUnit.flatMap(WeightUnit.init(rawValue:)) ?? .kg
    }
}

// MARK: - Errors

enum DataExporterError: LocalizedError {
    /// Two or more exercises in the export share the same name, which would
    /// silently merge them on import and re-link history to the wrong row.
    case duplicateExerciseNames([String])
    /// Two or more exercises in the export share the same stable identity,
    /// which would make ID-based re-linking ambiguous.
    case duplicateExerciseIDs([String])
    /// Plan IDs are file-scoped, but must still identify exactly one plan.
    case duplicatePlanIDs([String])
    case invalidWorkoutData(String)

    var errorDescription: String? {
        switch self {
        case .duplicateExerciseNames(let names):
            let joined = names.joined(separator: ", ")
            return "Import abgebrochen: doppelte Übungsnamen erkannt (\(joined))."
        case .duplicateExerciseIDs(let ids):
            let joined = ids.joined(separator: ", ")
            return "Import abgebrochen: doppelte Übungs-IDs erkannt (\(joined))."
        case .duplicatePlanIDs(let ids):
            return "Import abgebrochen: doppelte Trainingsplan-IDs erkannt (\(ids.joined(separator: ", ")))."
        case .invalidWorkoutData(let detail):
            return "Import abgebrochen: ungültige Trainingsdaten (\(detail))."
        }
    }
}

// MARK: - Exporter

enum DataExporter {
    static func exportData(context: ModelContext) throws -> Data {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let plans = try context.fetch(FetchDescriptor<WorkoutPlan>())
        let workouts = try context.fetch(FetchDescriptor<Workout>())

        let exportExercises = exercises.map { exercise in
            ExportExercise(
                id: exercise.ensureStableID().uuidString,
                name: exercise.name,
                muscleGroup: exercise.muscleGroupRaw,
                equipmentType: exercise.equipmentTypeRaw,
                isCustom: exercise.isCustom,
                imageURL: exercise.imageURL,
                notes: exercise.notes
            )
        }

        var planExportIDs: [PersistentIdentifier: String] = [:]
        let exportPlans = plans.enumerated().map { index, plan in
            let exportID = String(index)
            planExportIDs[plan.persistentModelID] = exportID
            return ExportWorkoutPlan(
                id: exportID,
                name: plan.name,
                exerciseIDs: plan.orderedExercises.map { $0.ensureStableID().uuidString },
                exerciseNames: plan.orderedExercises.map(\.name)
            )
        }

        let exportWorkouts = workouts.map { workout in
            ExportWorkout(
                name: workout.name,
                planID: workout.plan.flatMap { planExportIDs[$0.persistentModelID] },
                planName: workout.plan?.name,
                date: workout.date,
                duration: workout.duration,
                entries: workout.entries.map { entry in
                    ExportWorkoutEntry(
                        exerciseID: entry.exercise?.ensureStableID().uuidString,
                        exerciseName: entry.exercise?.name,
                        date: entry.date,
                        sets: entry.sortedSets.map { set in
                            ExportWorkoutSet(
                                setNumber: set.setNumber,
                                weight: set.weight,
                                weightUnit: WeightUnit.kg.rawValue,
                                reps: set.reps
                            )
                        }
                    )
                }
            )
        }

        let exportData = ExportData(
            exercises: exportExercises,
            workoutPlans: exportPlans,
            workouts: exportWorkouts
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportData)
    }

    static func importData(from data: Data, context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importData = try decoder.decode(ExportData.self, from: data)

        // Reject ambiguous names before replacing the store: legacy backups
        // and missing-ID fallbacks still resolve exercises by name.
        let normalizedToOriginal = importData.exercises.reduce(into: [String: String]()) { mapping, exercise in
            let normalized = Exercise.normalizedName(exercise.name)
            mapping[normalized] = mapping[normalized] ?? exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let duplicates = importData.exercises
            .map { Exercise.normalizedName($0.name) }
            .reduce(into: [String: Int]()) { counts, name in counts[name, default: 0] += 1 }
            .filter { $0.value > 1 }
            .compactMap { normalizedToOriginal[$0.key] }
            .sorted()
        if !duplicates.isEmpty {
            throw DataExporterError.duplicateExerciseNames(duplicates)
        }
        // Normalize through UUID parsing before checking: UUID(uuidString:) is
        // case-insensitive, so the same UUID in upper- and lowercase must count
        // as a duplicate — otherwise both exercises silently share a stableID
        // and the next export becomes un-importable.
        let duplicateIDs = importData.exercises
            .compactMap { $0.id.flatMap(Self.normalizedUUIDString) }
            .reduce(into: [String: Int]()) { counts, id in counts[id, default: 0] += 1 }
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
        if !duplicateIDs.isEmpty {
            throw DataExporterError.duplicateExerciseIDs(duplicateIDs)
        }

        let duplicatePlanIDs = importData.workoutPlans.compactMap(\.id)
            .reduce(into: [String: Int]()) { counts, id in counts[id, default: 0] += 1 }
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
        if !duplicatePlanIDs.isEmpty {
            throw DataExporterError.duplicatePlanIDs(duplicatePlanIDs)
        }
        try validateWorkouts(importData.workouts)

        do {
            // Interrupted workouts can leave entries without a Workout, and
            // older stores can contain detached sets. They have no root that
            // could cascade-delete them when replacing the backup.
            let detachedSets = try context.fetch(FetchDescriptor<WorkoutSet>(
                predicate: #Predicate { $0.workoutEntry == nil }
            ))
            let detachedEntries = try context.fetch(FetchDescriptor<WorkoutEntry>(
                predicate: #Predicate { $0.workout == nil }
            ))
            for set in detachedSets { context.delete(set) }
            for entry in detachedEntries { context.delete(entry) }
            // Delete remaining roots through the relationship cascade rules;
            // a single save/rollback covers the entire replacement.
            try deleteAll(Workout.self, in: context)
            try deleteAll(WorkoutPlan.self, in: context)
            try deleteAll(Exercise.self, in: context)

            var exerciseMapByID: [String: Exercise] = [:]
            var exerciseMapByName: [String: Exercise] = [:]
            for ex in importData.exercises {
                let stableID = ex.id.flatMap(UUID.init(uuidString:)) ?? UUID()
                // Construct with .unknown, then restore the raw strings
                // verbatim: unknown categories from a newer app version (or an
                // edited file) must survive the round-trip instead of being
                // silently reclassified as chest/machine. The computed getters
                // already fall back to .unknown for display.
                let exercise = Exercise(
                    name: ex.name,
                    muscleGroup: .unknown,
                    equipmentType: .unknown,
                    isCustom: ex.isCustom,
                    stableID: stableID
                )
                exercise.muscleGroupRaw = ex.muscleGroup
                exercise.equipmentTypeRaw = ex.equipmentType
                exercise.imageURL = nil
                exercise.notes = ex.notes.flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                context.insert(exercise)
                if let normalizedID = ex.id.flatMap(Self.normalizedUUIDString) {
                    exerciseMapByID[normalizedID] = exercise
                }
                exerciseMapByName[Exercise.normalizedName(ex.name)] = exercise
            }

            var planMapByExportID: [String: WorkoutPlan] = [:]
            var planMapByName: [String: WorkoutPlan] = [:]
            for planData in importData.workoutPlans {
                let plan = WorkoutPlan(name: planData.name)
                context.insert(plan)
                // File order is the user's order; setExercises records it.
                if let exerciseIDs = planData.exerciseIDs {
                    plan.setExercises(exerciseIDs.enumerated().compactMap { index, id in
                        if let exercise = Self.normalizedUUIDString(id).flatMap({ exerciseMapByID[$0] }) {
                            return exercise
                        }
                        // Match workout-entry fallback behavior for legacy or
                        // hand-edited files whose IDs no longer resolve.
                        guard planData.exerciseNames.indices.contains(index) else { return nil }
                        return exerciseMapByName[Exercise.normalizedName(planData.exerciseNames[index])]
                    })
                } else {
                    plan.setExercises(planData.exerciseNames.compactMap {
                        exerciseMapByName[Exercise.normalizedName($0)]
                    })
                }
                if let id = planData.id {
                    planMapByExportID[id] = plan
                }
                if planMapByName[planData.name] == nil {
                    planMapByName[planData.name] = plan
                }
            }

            for workoutData in importData.workouts {
                let workout = Workout(name: workoutData.name, date: workoutData.date, duration: workoutData.duration)
                // Restore the plan link so per-plan history (WorkoutDetailView)
                // survives a backup round-trip; fall back to the plan name for
                // files that carry no plan ids.
                workout.plan = workoutData.planID.flatMap { planMapByExportID[$0] }
                    ?? workoutData.planName.flatMap { planMapByName[$0] }
                context.insert(workout)

                for entryData in workoutData.entries {
                    // MHE-6: Preserve entries whose exercise reference is nil
                    // (or whose name didn't resolve, e.g. data from an older
                    // export with an empty string). The Workout model already
                    // tolerates `exercise: nil`, so dropping these silently
                    // was the only thing causing data loss.
                    let exercise = entryData.exerciseID
                        .flatMap(Self.normalizedUUIDString)
                        .flatMap { exerciseMapByID[$0] }
                        ?? entryData.exerciseName.flatMap { exerciseMapByName[Exercise.normalizedName($0)] }
                    let entry = WorkoutEntry(date: entryData.date, exercise: exercise)
                    entry.workout = workout
                    context.insert(entry)

                    for setData in entryData.sets {
                        let workoutSet = WorkoutSet(
                            setNumber: setData.setNumber,
                            weight: setData.weight,
                            reps: setData.reps,
                            unit: setData.resolvedWeightUnit,
                            workoutEntry: entry
                        )
                        context.insert(workoutSet)
                        entry.sets.append(workoutSet)
                    }
                }
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<T>())
        for item in items { context.delete(item) }
    }

    private static func validateWorkouts(_ workouts: [ExportWorkout]) throws {
        for workout in workouts {
            guard workout.duration >= 0 else {
                throw DataExporterError.invalidWorkoutData("negative Dauer in \(workout.name)")
            }
            var totalVolume = 0.0
            for entry in workout.entries {
                for set in entry.sets {
                    let weightKg = set.resolvedWeightUnit.kilograms(from: set.weight)
                    let volume = weightKg * Double(set.reps)
                    // Older app versions saved placeholder sets with zero
                    // reps. Keep those backups readable, but reject values
                    // that would corrupt totals or chart scales.
                    guard set.setNumber > 0, set.weight.isFinite, set.weight >= 0,
                          set.reps >= 0, weightKg.isFinite, volume.isFinite else {
                        throw DataExporterError.invalidWorkoutData("ungültiger Satz in \(workout.name)")
                    }
                    totalVolume += volume
                    guard totalVolume.isFinite else {
                        throw DataExporterError.invalidWorkoutData("zu großes Volumen in \(workout.name)")
                    }
                }
            }
        }
    }

    /// Canonical (uppercase) UUID string, or nil for unparseable input.
    /// Used for duplicate detection and map keys so case variants of the
    /// same UUID cannot slip past the checks.
    private nonisolated static func normalizedUUIDString(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString
    }
}
