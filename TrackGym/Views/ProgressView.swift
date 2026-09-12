import SwiftUI
import SwiftData
import Charts

struct ProgressTabView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \Workout.date) private var workouts: [Workout]
    @State private var selectedExercise: Exercise?

    private var exercisesWithData: [Exercise] {
        exercises
            .filter { !$0.completedWorkoutEntries.isEmpty }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workouts.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Daten vorhanden", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Speichere ein Training, um deinen Fortschritt zu sehen.")
                    }
                } else {
                    ExerciseSelectionPicker(
                        exercises: exercisesWithData,
                        selection: $selectedExercise
                    )

                    if let exercise = selectedExercise {
                        ExerciseProgressView(exercise: exercise)
                    } else {
                        OverallProgressView(exercises: exercisesWithData, workouts: workouts)
                    }
                }
            }
            .navigationTitle("Fortschritt")
            .onChange(of: exercisesWithData) { _, newValue in
                if let selected = selectedExercise,
                   !newValue.contains(where: { $0.persistentModelID == selected.persistentModelID }) {
                    selectedExercise = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

// MARK: - Picker

private struct ExerciseSelectionPicker: View {
    let exercises: [Exercise]
    @Binding var selection: Exercise?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selection = nil
                } label: {
                    Text("Gesamt")
                        .font(.subheadline)
                        .fontWeight(selection == nil ? .semibold : .regular)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selection == nil ? Color.blue : Color(.systemGray5))
                        .foregroundStyle(selection == nil ? .white : .primary)
                        .clipShape(Capsule())
                }
                .accessibilityAddTraits(selection == nil ? .isSelected : [])

                ForEach(exercises) { exercise in
                    Button {
                        selection = exercise
                    } label: {
                        Text(exercise.name)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selection?.persistentModelID == exercise.persistentModelID ? Color.blue : Color(.systemGray5))
                            .foregroundStyle(selection?.persistentModelID == exercise.persistentModelID ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .accessibilityAddTraits(selection?.persistentModelID == exercise.persistentModelID ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Overall Progress

private struct OverallProgressView: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let exercises: [Exercise]
    let workouts: [Workout]

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    private var volumeByWorkout: [(id: PersistentIdentifier, date: Date, volume: Double)] {
        workouts.map { workout in
            (
                id: workout.persistentModelID,
                date: workout.date,
                volume: selectedUnit.displayValue(fromKilograms: workout.entries.reduce(0) { $0 + $1.totalVolume })
            )
        }
    }

    private var totalWorkouts: Int {
        workouts.count
    }

    private var totalVolume: Double {
        volumeByWorkout.reduce(0) { $0 + $1.volume }
    }

    private var averageVolume: Double {
        totalWorkouts > 0 ? totalVolume / Double(totalWorkouts) : 0
    }

    @State private var volumePeriod: VolumePeriod = .week

    private var muscleVolumeData: [(group: MuscleGroup, volume: Double)] {
        let entries = workouts.flatMap(\.entries)
        return TrainingStatistics.volumeByMuscleGroup(entries: entries, since: volumePeriod.since)
            .map { (group: $0.group, volume: selectedUnit.displayValue(fromKilograms: $0.volumeKg)) }
    }

    var body: some View {
        List {
            if !volumeByWorkout.isEmpty {
                Section("Gesamtvolumen pro Training") {
                    Chart {
                        ForEach(volumeByWorkout, id: \.id) { point in
                            LineMark(
                                x: .value("Datum", point.date),
                                y: .value("Volumen (\(selectedUnit.rawValue))", point.volume)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.blue)

                            PointMark(
                                x: .value("Datum", point.date),
                                y: .value("Volumen (\(selectedUnit.rawValue))", point.volume)
                            )
                            .foregroundStyle(.blue)
                        }
                    }
                    .chartYAxisLabel(selectedUnit.rawValue)
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day().month())
                        }
                    }
                    .frame(height: 200)
                    .padding(.horizontal)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("Zusammenfassung") {
                    StatRow(icon: "calendar", label: "Trainings", value: "\(totalWorkouts)")
                    StatRow(icon: "scalemass.fill", label: "Gesamtvolumen", value: formatWeight(totalVolume))
                    StatRow(icon: "chart.bar.fill", label: "Ø Volumen pro Training", value: formatWeight(averageVolume))
                    StatRow(icon: "dumbbell.fill", label: "Übungen trainiert", value: "\(exercises.count)")
                }

                Section("Volumen pro Muskelgruppe") {
                    Picker("Zeitraum", selection: $volumePeriod) {
                        ForEach(VolumePeriod.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)

                    if muscleVolumeData.isEmpty {
                        Text("Keine Trainings im gewählten Zeitraum.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Chart {
                            ForEach(muscleVolumeData, id: \.group) { item in
                                BarMark(
                                    x: .value("Volumen (\(selectedUnit.rawValue))", item.volume),
                                    y: .value("Muskelgruppe", item.group.displayName)
                                )
                                .foregroundStyle(.blue)
                            }
                        }
                        .chartXAxisLabel(selectedUnit.rawValue)
                        .frame(height: CGFloat(muscleVolumeData.count) * 36 + 24)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func formatWeight(_ weight: Double) -> String {
        if selectedUnit == .kg && weight >= 1000 {
            return String(format: "%.1f t", weight / 1000)
        }
        return String(format: "%.0f \(selectedUnit.rawValue)", weight)
    }
}

private struct StatRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Exercise Progress

private struct ExerciseProgressView: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let exercise: Exercise

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    private var sortedEntries: [WorkoutEntry] {
        exercise.completedWorkoutEntries.sorted { $0.date < $1.date }
    }

    private var personalRecord: Double {
        exercise.completedWorkoutEntries.flatMap(\.sets).map(\.weight).max() ?? 0
    }

    var body: some View {
        List {
            if sortedEntries.isEmpty {
                Section {
                    Text("Noch keine Einträge für diese Übung.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Gewichtsentwicklung") {
                    Chart {
                        ForEach(sortedEntries) { entry in
                            LineMark(
                                x: .value("Datum", entry.date),
                                y: .value("Gewicht (\(selectedUnit.rawValue))", selectedUnit.displayValue(fromKilograms: entry.maxWeight))
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.blue)

                            PointMark(
                                x: .value("Datum", entry.date),
                                y: .value("Gewicht (\(selectedUnit.rawValue))", selectedUnit.displayValue(fromKilograms: entry.maxWeight))
                            )
                            .foregroundStyle(.blue)
                        }
                    }
                    .chartYAxisLabel(selectedUnit.rawValue)
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day().month())
                        }
                    }
                    .frame(height: 200)
                    .padding(.horizontal)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                if personalRecord > 0 {
                    Section {
                        HStack {
                            Image(systemName: "trophy.fill")
                                .foregroundStyle(.yellow)
                            Text("Persönlicher Rekord")
                                .font(.headline)
                            Spacer()
                            Text("\(selectedUnit.displayValue(fromKilograms: personalRecord), specifier: "%.1f") \(selectedUnit.rawValue)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Section("Trainingshistorie") {
                    ForEach(sortedEntries.reversed()) { entry in
                        HistoryEntryRow(entry: entry, personalRecord: personalRecord)
                    }
                }
            }
        }
    }
}

private extension Exercise {
    var completedWorkoutEntries: [WorkoutEntry] {
        workoutEntries.filter { $0.workout != nil }
    }
}

private enum VolumePeriod: String, CaseIterable, Identifiable {
    case week = "Woche"
    case month = "Monat"
    case all = "Gesamt"

    var id: String { rawValue }

    /// Rollierendes Fenster (7/30 Tage), kein Kalenderbezug.
    var since: Date? {
        switch self {
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all: nil
        }
    }
}

private struct HistoryEntryRow: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let entry: WorkoutEntry
    let personalRecord: Double

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    private var isPR: Bool {
        entry.maxWeight == personalRecord && personalRecord > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date, format: .dateTime.day().month().year())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if isPR {
                    Text("PR")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                Text("Max: \(selectedUnit.displayValue(fromKilograms: entry.maxWeight), specifier: "%.1f") \(selectedUnit.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            ForEach(entry.sortedSets) { set in
                HStack {
                    Text("Satz \(set.setNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(set.weight(in: selectedUnit), specifier: "%.1f") \(selectedUnit.rawValue) × \(set.reps) Wdh")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
