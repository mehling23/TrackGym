import SwiftUI
import SwiftData

struct AddExerciseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]

    @State private var name = ""
    @State private var notes = ""
    @State private var selectedMuscleGroup: MuscleGroup = .chest
    @State private var selectedEquipmentType: EquipmentType = .freeWeight
    @State private var duplicateNameAlert = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateExercise: Exercise? {
        let normalized = Exercise.normalizedName(trimmedName)
        guard !normalized.isEmpty else { return nil }
        return exercises.first { Exercise.normalizedName($0.name) == normalized }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Übungsdetails") {
                    TextField("Name der Übung", text: $name)

                    Picker("Muskelgruppe", selection: $selectedMuscleGroup) {
                        ForEach(MuscleGroup.selectableCases) { group in
                            Text(group.displayName).tag(group)
                        }
                    }

                    Picker("Gerätetyp", selection: $selectedEquipmentType) {
                        ForEach(EquipmentType.selectableCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    TextField("Notiz (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .navigationTitle("Neue Übung")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Übung existiert bereits", isPresented: $duplicateNameAlert) {
                Button("OK") {}
            } message: {
                if let duplicateExercise {
                    Text("„\(duplicateExercise.name)“ ist bereits vorhanden. Verwende einen eindeutigen Namen.")
                } else {
                    Text("Verwende einen eindeutigen Namen.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        saveExercise()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func saveExercise() {
        guard duplicateExercise == nil else {
            duplicateNameAlert = true
            return
        }

        let exercise = Exercise(
            name: trimmedName,
            muscleGroup: selectedMuscleGroup,
            equipmentType: selectedEquipmentType,
            isCustom: true
        )
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        exercise.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        modelContext.insert(exercise)
        try? modelContext.save()
        dismiss()
    }
}
