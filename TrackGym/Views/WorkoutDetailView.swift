import SwiftUI
import SwiftData

struct WorkoutDetailView: View {
    let plan: WorkoutPlan
    @Query(sort: \WorkoutEntry.date, order: .reverse) private var allEntries: [WorkoutEntry]
    @Query(sort: \Workout.date, order: .reverse) private var allWorkouts: [Workout]
    @State private var planToStart: WorkoutPlan?
    @State private var planToEdit: WorkoutPlan?
    @State private var showingHistory = false

    var sortedExercises: [Exercise] {
        plan.orderedExercises
    }

    var planWorkouts: [Workout] {
        let planID = plan.persistentModelID
        return allWorkouts.filter { $0.plan?.persistentModelID == planID }
    }

    var lastWorkout: Workout? {
        planWorkouts.first
    }

    func lastEntry(for exercise: Exercise) -> WorkoutEntry? {
        let exerciseID = exercise.persistentModelID
        return allEntries.first { $0.exercise?.persistentModelID == exerciseID && $0.workout != nil }
    }

    func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) Std. \(m) Min." }
        if m > 0 { return "\(m) Min." }
        return "< 1 Min."
    }

    var body: some View {
        Group {
            if plan.exercises.isEmpty {
                ContentUnavailableView {
                    Label("Keine Übungen", systemImage: "figure.strengthtraining.traditional")
                } description: {
                    Text("Bearbeite den Plan, um Übungen hinzuzufügen.")
                } actions: {
                    Button("Plan bearbeiten") {
                        planToEdit = plan
                    }
                    .buttonStyle(.borderedProminent)
                    if !planWorkouts.isEmpty {
                        Button("Trainingshistorie anzeigen") {
                            showingHistory = true
                        }
                    }
                }
            } else {
                List {
                    // Last workout – tappable, shows history
                    Section {
                        if let last = lastWorkout {
                            Button {
                                showingHistory = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(last.date.formatted(.dateTime.day().month().year()))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(formatDuration(last.duration))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 4) {
                                        Text("\(planWorkouts.count) Einheiten")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        } else {
                            Text("Noch kein Training absolviert")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Letztes Training")
                    }

                    // Exercises
                    Section("Übungen") {
                        ForEach(sortedExercises) { exercise in
                            ExerciseDetailRow(
                                exercise: exercise,
                                lastEntry: lastEntry(for: exercise)
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    planToStart = plan
                } label: {
                    Label("Training starten", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    planToEdit = plan
                } label: {
                    Label("Plan bearbeiten", systemImage: "pencil")
                }
            }
        }
        .fullScreenCover(item: $planToStart) { p in
            ActiveWorkoutView(plan: p)
        }
        .sheet(item: $planToEdit) { p in
            EditWorkoutPlanView(plan: p)
        }
        .sheet(isPresented: $showingHistory) {
            WorkoutHistorySheet(workouts: planWorkouts, planName: plan.name)
        }
    }
}

// MARK: - Workout History Sheet

private struct WorkoutHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let workouts: [Workout]
    let planName: String

    func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) Std. \(m) Min." }
        if m > 0 { return "\(m) Min." }
        return "< 1 Min."
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(workouts) { workout in
                    WorkoutHistoryRow(workout: workout, formatDuration: formatDuration)
                }
            }
            .navigationTitle("Trainingshistorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .overlay {
                if workouts.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Einträge", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Noch kein Training für diesen Plan absolviert.")
                    }
                }
            }
        }
    }
}

private struct WorkoutHistoryRow: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let workout: Workout
    let formatDuration: (Int) -> String

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    var sortedEntries: [WorkoutEntry] {
        workout.entries.sorted { ($0.exercise?.name ?? "") < ($1.exercise?.name ?? "") }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(sortedEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.exercise?.name ?? "Unbekannte Übung")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(entry.sortedSets) { set in
                        Text("Satz \(set.setNumber): \(set.weight(in: selectedUnit), specifier: "%.1f") \(selectedUnit.rawValue) × \(set.reps) Wdh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.date.formatted(.dateTime.day().month().year()))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    HStack(spacing: 8) {
                        Label(formatDuration(workout.duration), systemImage: "timer")
                        Label("\(workout.entries.count) Übungen", systemImage: "figure.strengthtraining.traditional")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Exercise Detail Row

private struct ExerciseDetailRow: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let exercise: Exercise
    let lastEntry: WorkoutEntry?

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    var body: some View {
        HStack(spacing: 12) {
            ExerciseImageView(exercise: exercise, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.name)
                    .font(.headline)

                Text(exercise.muscleGroup.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let last = lastEntry {
                    Divider()
                        .padding(.vertical, 2)

                    Text(last.date.formatted(.dateTime.day().month().year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let sets = last.sortedSets
                    if !sets.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(sets) { set in
                                    Text("S\(set.setNumber): \(set.weight(in: selectedUnit), specifier: "%.1f") \(selectedUnit.rawValue) × \(set.reps)")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.blue.opacity(0.1), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } else {
                    Text("Noch kein Training aufgezeichnet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
