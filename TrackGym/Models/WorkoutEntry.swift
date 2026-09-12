import Foundation
import SwiftData

@Model
final class WorkoutEntry {
    var date: Date
    var exercise: Exercise?
    var workout: Workout?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.workoutEntry)
    var sets: [WorkoutSet] = []

    var sortedSets: [WorkoutSet] {
        sets.sorted { $0.setNumber < $1.setNumber }
    }

    var maxWeight: Double {
        sets.map(\.weight).max() ?? 0
    }

    var totalVolume: Double {
        sets.reduce(0) { $0 + $1.weight * Double($1.reps) }
    }

    /// New workouts require at least one completed set. Zero additional
    /// weight remains valid for bodyweight exercises.
    var hasValidSets: Bool {
        !sets.isEmpty && sets.allSatisfy {
            $0.weight.isFinite && $0.weight >= 0 && $0.reps > 0 &&
            ($0.weight * Double($0.reps)).isFinite
        } && totalVolume.isFinite
    }

    /// Preserve gaps left by deleted sets. An imported maximum integer
    /// cannot be incremented, so repair numbering before adding another set.
    func prepareNextSetNumber() -> Int {
        let highestNumber = max(sets.map(\.setNumber).max() ?? 0, 0)
        guard highestNumber == Int.max else { return highestNumber + 1 }
        let ordered = sortedSets
        for (index, set) in ordered.enumerated() {
            set.setNumber = index + 1
        }
        return ordered.count + 1
    }

    init(date: Date, exercise: Exercise?) {
        self.date = date
        self.exercise = exercise
    }
}
