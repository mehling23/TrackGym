import XCTest
import SwiftData
@testable import TrackGym

@MainActor
final class TrainingStatisticsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let schema = Schema([Exercise.self, Workout.self, WorkoutEntry.self, WorkoutSet.self, WorkoutPlan.self, SeedVersion.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        container = nil
    }

    func test_volumeByMuscleGroup_aggregatesPerGroup() throws {
        makeCompletedEntry(muscleGroup: .chest, sets: [(100, 10)], daysAgo: 1)
        makeCompletedEntry(muscleGroup: .chest, sets: [(50, 10)], daysAgo: 2)
        makeCompletedEntry(muscleGroup: .legs, sets: [(200, 5)], daysAgo: 1)

        let result = TrainingStatistics.volumeByMuscleGroup(entries: allEntries(), since: nil)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.group, .chest)
        XCTAssertEqual(result.first?.volumeKg ?? 0, 1500, accuracy: 0.001)
        XCTAssertEqual(result.last?.volumeKg ?? 0, 1000, accuracy: 0.001)
    }

    func test_volumeByMuscleGroup_respectsSinceDate() throws {
        makeCompletedEntry(muscleGroup: .chest, sets: [(100, 10)], daysAgo: 1)
        makeCompletedEntry(muscleGroup: .chest, sets: [(100, 10)], daysAgo: 20)

        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let result = TrainingStatistics.volumeByMuscleGroup(entries: allEntries(), since: weekAgo)

        XCTAssertEqual(result.first?.volumeKg ?? 0, 1000, accuracy: 0.001)
    }

    func test_volumeByMuscleGroup_excludesPendingAndOrphanedEntries() throws {
        // Pending: Eintrag ohne Workout
        let exercise = Exercise(name: "Bench", muscleGroup: .chest, equipmentType: .freeWeight)
        context.insert(exercise)
        let pending = WorkoutEntry(date: Date(), exercise: exercise)
        context.insert(pending)
        let set = WorkoutSet(setNumber: 1, weight: 100, reps: 10, workoutEntry: pending)
        context.insert(set)
        pending.sets.append(set)
        // Verwaist: Eintrag ohne Übung
        let workout = Workout(name: "W", date: Date(), duration: 60)
        context.insert(workout)
        let orphan = WorkoutEntry(date: Date(), exercise: nil)
        orphan.workout = workout
        context.insert(orphan)

        let result = TrainingStatistics.volumeByMuscleGroup(entries: allEntries(), since: nil)

        XCTAssertTrue(result.isEmpty)
    }

    func test_volumeByMuscleGroup_usesStableOrderForEqualVolumes() throws {
        makeCompletedEntry(muscleGroup: .legs, sets: [(100, 10)], daysAgo: 1)
        makeCompletedEntry(muscleGroup: .chest, sets: [(100, 10)], daysAgo: 1)
        let entries = allEntries()

        let result = TrainingStatistics.volumeByMuscleGroup(entries: entries, since: nil)
        let reversedResult = TrainingStatistics.volumeByMuscleGroup(entries: entries.reversed(), since: nil)

        XCTAssertEqual(result.map(\.group), [.chest, .legs])
        XCTAssertEqual(reversedResult.map(\.group), result.map(\.group))
    }

    // MARK: - Helpers

    private func allEntries() -> [WorkoutEntry] {
        (try? context.fetch(FetchDescriptor<WorkoutEntry>())) ?? []
    }

    @discardableResult
    private func makeCompletedEntry(muscleGroup: MuscleGroup, sets: [(weight: Double, reps: Int)], daysAgo: Int) -> WorkoutEntry {
        let exercise = Exercise(name: "Ex-\(UUID().uuidString.prefix(6))", muscleGroup: muscleGroup, equipmentType: .freeWeight)
        context.insert(exercise)
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let workout = Workout(name: "W", date: date, duration: 3600)
        context.insert(workout)
        let entry = WorkoutEntry(date: date, exercise: exercise)
        entry.workout = workout
        context.insert(entry)
        for (index, pair) in sets.enumerated() {
            let set = WorkoutSet(setNumber: index + 1, weight: pair.weight, reps: pair.reps, workoutEntry: entry)
            context.insert(set)
            entry.sets.append(set)
        }
        return entry
    }
}
