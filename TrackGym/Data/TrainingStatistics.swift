import Foundation

enum TrainingStatistics {
    /// Gesamtvolumen (kg) je Muskelgruppe über abgeschlossene Einträge,
    /// absteigend nach Volumen sortiert. `since` nil = gesamter Zeitraum.
    /// Einträge ohne Workout (noch nicht gespeichert) oder ohne Übung
    /// (Übung gelöscht) fließen nicht ein.
    static func volumeByMuscleGroup(entries: [WorkoutEntry], since: Date?) -> [(group: MuscleGroup, volumeKg: Double)] {
        var totals: [MuscleGroup: Double] = [:]
        for entry in entries {
            guard entry.workout != nil, let exercise = entry.exercise else { continue }
            if let since, entry.date < since { continue }
            let volume = entry.totalVolume
            guard volume > 0 else { continue }
            totals[exercise.muscleGroup, default: 0] += volume
        }
        return totals
            .map { (group: $0.key, volumeKg: $0.value) }
            .sorted {
                if $0.volumeKg != $1.volumeKg { return $0.volumeKg > $1.volumeKg }
                return $0.group.rawValue < $1.group.rawValue
            }
    }
}
