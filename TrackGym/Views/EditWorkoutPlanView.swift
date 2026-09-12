import SwiftUI
import SwiftData

struct EditWorkoutPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var planName: String
    @State private var selectedExercises: [Exercise]
    @State private var showingExercisePicker = false

    private let existingPlan: WorkoutPlan?

    init(plan: WorkoutPlan? = nil) {
        self.existingPlan = plan
        _planName = State(initialValue: plan?.name ?? "")
        _selectedExercises = State(initialValue: plan?.orderedExercises ?? [])
    }

    private var isValid: Bool {
        !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan-Name") {
                    TextField("z.B. Push, Pull, Legs", text: $planName)
                }

                Section {
                    if selectedExercises.isEmpty {
                        Text("Noch keine Übungen zugeordnet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedExercises) { exercise in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name)
                                    Text(exercise.muscleGroup.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    removeExercise(exercise)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(exercise.name) entfernen")
                            }
                        }
                        .onMove { offsets, destination in
                            selectedExercises.move(fromOffsets: offsets, toOffset: destination)
                        }
                    }

                    Button {
                        showingExercisePicker = true
                    } label: {
                        Label("Übung hinzufügen", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Übungen (\(selectedExercises.count))")
                } footer: {
                    if selectedExercises.count > 1 {
                        Text("Halten und ziehen, um die Reihenfolge zu ändern. So werden die Übungen im Training angezeigt.")
                    }
                }
            }
            .navigationTitle(existingPlan == nil ? "Neuer Plan" : "Plan bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        savePlan()
                    }
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingExercisePicker) {
                ExercisePickerView { exercises in
                    for exercise in exercises {
                        if !selectedExercises.contains(where: { $0.persistentModelID == exercise.persistentModelID }) {
                            selectedExercises.append(exercise)
                        }
                    }
                }
            }
        }
    }

    private func removeExercise(_ exercise: Exercise) {
        selectedExercises.removeAll { $0.persistentModelID == exercise.persistentModelID }
    }

    private func savePlan() {
        let trimmedName = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if let plan = existingPlan {
            plan.name = trimmedName
            plan.setExercises(selectedExercises)
        } else {
            let plan = WorkoutPlan(name: trimmedName)
            modelContext.insert(plan)
            plan.setExercises(selectedExercises)
        }
        dismiss()
    }
}
