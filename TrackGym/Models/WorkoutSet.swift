import Foundation
import SwiftData

@Model
final class WorkoutSet {
    var setNumber: Int
    var weight: Double
    var reps: Int
    var workoutEntry: WorkoutEntry?

    init(setNumber: Int, weight: Double, reps: Int, unit: WeightUnit = .kg, workoutEntry: WorkoutEntry? = nil) {
        self.setNumber = setNumber
        self.weight = unit.kilograms(from: weight)
        self.reps = reps
        self.workoutEntry = workoutEntry
    }

    func weight(in unit: WeightUnit) -> Double {
        unit.displayValue(fromKilograms: weight)
    }

    func setWeight(_ displayValue: Double, unit: WeightUnit) {
        guard displayValue.isFinite else { return }
        weight = max(0, unit.kilograms(from: displayValue))
    }
}
