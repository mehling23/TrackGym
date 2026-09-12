import XCTest
import SwiftData
@testable import TrackGym

@MainActor
final class WorkoutHistoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let schema = Schema([
            Exercise.self,
            Workout.self,
            WorkoutEntry.self,
            WorkoutSet.self,
            WorkoutPlan.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - previousEntry

    func test_previousEntry_returnsNil_forNilExercise() {
        XCTAssertNil(WorkoutHistory.previousEntry(for: nil, in: context))
    }

    func test_previousEntry_returnsNil_whenNoHistory() {
        let exercise = makeExercise("Bench Press")
        XCTAssertNil(WorkoutHistory.previousEntry(for: exercise, in: context))
    }

    func test_previousEntry_returnsMostRecentMatchingEntry() throws {
        let exercise = makeExercise("Bench Press")
        let older = makeEntry(for: exercise, daysAgo: 7)
        let newer = makeEntry(for: exercise, daysAgo: 1)
        try context.save()

        let result = WorkoutHistory.previousEntry(for: exercise, in: context)
        XCTAssertEqual(result?.persistentModelID, newer.persistentModelID)
        _ = older
    }

    func test_previousEntry_ignoresOtherExercises() throws {
        let bench = makeExercise("Bench Press")
        let squat = makeExercise("Squat")
        _ = makeEntry(for: squat, daysAgo: 1)
        try context.save()

        XCTAssertNil(WorkoutHistory.previousEntry(for: bench, in: context))
    }

    func test_previousEntry_matchesExerciseIdentityAfterRename() throws {
        let exercise = makeExercise("Bench Press")
        let entry = makeEntry(for: exercise, daysAgo: 1)
        try context.save()

        exercise.name = "Renamed Bench"
        try context.save()

        let result = WorkoutHistory.previousEntry(for: exercise, in: context)
        XCTAssertEqual(result?.persistentModelID, entry.persistentModelID)
    }

    func test_previousEntry_doesNotMatchDifferentExerciseWithSameName() throws {
        let original = makeExercise("Bench Press")
        _ = makeEntry(for: original, daysAgo: 1)
        let duplicateName = makeExercise("Bench Press")
        try context.save()

        XCTAssertNil(WorkoutHistory.previousEntry(for: duplicateName, in: context))
    }

    func test_previousEntry_excludesCurrentInProgressEntries() throws {
        let exercise = makeExercise("Bench Press")
        let current = makeEntry(for: exercise, daysAgo: 1)
        try context.save()

        let result = WorkoutHistory.previousEntry(
            for: exercise,
            in: context,
            excluding: [current]
        )
        XCTAssertNil(result)
    }

    func test_previousEntry_excludesEntriesFromActiveWorkout() throws {
        let exercise = makeExercise("Bench Press")
        let workout = Workout(name: "Today", date: .now, duration: 0)
        context.insert(workout)
        let activeEntry = makeEntry(for: exercise, daysAgo: 0)
        activeEntry.workout = workout
        try context.save()

        let result = WorkoutHistory.previousEntry(
            for: exercise,
            in: context,
            activeWorkout: workout
        )
        XCTAssertNil(result)
    }

    func test_previousEntry_fallsBackThroughHistory_whenRecentIsExcluded() throws {
        let exercise = makeExercise("Bench Press")
        let older = makeEntry(for: exercise, daysAgo: 7)
        let newer = makeEntry(for: exercise, daysAgo: 1)
        try context.save()

        let result = WorkoutHistory.previousEntry(
            for: exercise,
            in: context,
            excluding: [newer]
        )
        XCTAssertEqual(result?.persistentModelID, older.persistentModelID)
    }

    func test_previousEntry_ignoresEntriesWithoutWorkout() throws {
        // A placeholder left behind by an interrupted workout carries today's
        // date and would otherwise shadow the real last training.
        let exercise = makeExercise("Bench Press")
        let real = makeEntry(for: exercise, daysAgo: 3)
        _ = makeOrphanEntry(for: exercise, daysAgo: 0)
        try context.save()

        let result = WorkoutHistory.previousEntry(for: exercise, in: context)
        XCTAssertEqual(result?.persistentModelID, real.persistentModelID)
    }

    // MARK: - deleteOrphanedEntries

    func test_deleteOrphanedEntries_removesOnlyEntriesWithoutWorkout() throws {
        let exercise = makeExercise("Bench Press")
        let kept = makeEntry(for: exercise, daysAgo: 1)
        let orphan = makeOrphanEntry(for: exercise, daysAgo: 0)
        let orphanSet = WorkoutSet(setNumber: 1, weight: 60, reps: 10, workoutEntry: orphan)
        context.insert(orphanSet)
        try context.save()

        let removed = try WorkoutHistory.deleteOrphanedEntries(in: context)

        XCTAssertEqual(removed, 1)
        let entries = try context.fetch(FetchDescriptor<WorkoutEntry>())
        XCTAssertEqual(entries.map(\.persistentModelID), [kept.persistentModelID])
        // Cascade: the orphan's sets go with it.
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutSet>()).count, 0)
    }

    func test_deleteOrphanedEntries_isNoOp_whenNothingIsOrphaned() throws {
        let exercise = makeExercise("Bench Press")
        _ = makeEntry(for: exercise, daysAgo: 1)
        try context.save()

        XCTAssertEqual(try WorkoutHistory.deleteOrphanedEntries(in: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutEntry>()).count, 1)
    }

    // MARK: - appendSet

    func test_appendSet_assignsSetNumberOne_whenEntryIsEmpty() throws {
        let exercise = makeExercise("Bench Press")
        let entry = makeEntry(for: exercise, daysAgo: 0)
        try context.save()

        let added = WorkoutHistory.appendSet(weight: 60, reps: 10, to: entry, in: context)

        XCTAssertEqual(added.setNumber, 1)
        XCTAssertEqual(added.weight, 60)
        XCTAssertEqual(added.reps, 10)
        XCTAssertEqual(entry.sets.count, 1)
    }

    func test_appendSet_incrementsFromHighestExistingSetNumber() throws {
        let exercise = makeExercise("Bench Press")
        let entry = makeEntry(for: exercise, daysAgo: 0)
        let s1 = WorkoutSet(setNumber: 1, weight: 60, reps: 10, workoutEntry: entry)
        let s3 = WorkoutSet(setNumber: 3, weight: 70, reps: 8, workoutEntry: entry)
        context.insert(s1)
        context.insert(s3)
        entry.sets = [s1, s3]
        try context.save()

        let added = WorkoutHistory.appendSet(weight: 80, reps: 6, to: entry, in: context)

        XCTAssertEqual(added.setNumber, 4)
        XCTAssertEqual(entry.sets.count, 3)
    }

    func test_appendSet_inserts_intoModelContext() throws {
        let exercise = makeExercise("Bench Press")
        let entry = makeEntry(for: exercise, daysAgo: 0)
        let initialSetCount = entry.sets.count
        try context.save()

        let added = WorkoutHistory.appendSet(weight: 50, reps: 12, to: entry, in: context)
        try context.save()

        let allSets = try context.fetch(FetchDescriptor<WorkoutSet>())
        XCTAssertEqual(allSets.count, 1)
        XCTAssertEqual(allSets.first?.weight, 50)
        // Guard against regressions that insert the set into the context but
        // forget to attach it to `entry.sets` (MHE-28).
        XCTAssertEqual(entry.sets.count, initialSetCount + 1)
        XCTAssertTrue(entry.sets.contains { $0.persistentModelID == added.persistentModelID })
    }

    func test_appendSet_repairsImportedNumberingThatWouldOverflow() throws {
        let exercise = makeExercise("Bench Press")
        let entry = makeEntry(for: exercise, daysAgo: 0)
        let first = WorkoutSet(setNumber: 3, weight: 60, reps: 10, workoutEntry: entry)
        let last = WorkoutSet(setNumber: Int.max, weight: 70, reps: 8, workoutEntry: entry)
        context.insert(first)
        context.insert(last)
        entry.sets = [last, first]
        try context.save()

        let added = WorkoutHistory.appendSet(weight: 80, reps: 6, to: entry, in: context)
        try context.save()

        XCTAssertEqual(added.setNumber, 3)
        XCTAssertEqual(entry.sortedSets.map(\.setNumber), [1, 2, 3])
        XCTAssertEqual(entry.sortedSets.map(\.weight), [60, 70, 80])
    }

    // MARK: - Helpers

    private func makeExercise(_ name: String) -> Exercise {
        let exercise = Exercise(name: name, muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(exercise)
        return exercise
    }

    /// Creates a saved entry, i.e. one attached to a Workout. Entries without
    /// a workout are unsaved placeholders and must never count as history.
    private func makeEntry(for exercise: Exercise, daysAgo: Int) -> WorkoutEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let workout = Workout(name: "Session", date: date)
        context.insert(workout)
        let entry = WorkoutEntry(date: date, exercise: exercise)
        context.insert(entry)
        entry.workout = workout
        return entry
    }

    private func makeOrphanEntry(for exercise: Exercise, daysAgo: Int) -> WorkoutEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let entry = WorkoutEntry(date: date, exercise: exercise)
        context.insert(entry)
        return entry
    }
}
