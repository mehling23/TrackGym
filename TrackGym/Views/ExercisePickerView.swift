import SwiftUI
import SwiftData

struct ExercisePickerView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedMuscleGroup: MuscleGroup?
    @State private var selectedEquipmentType: EquipmentType?
    @State private var selectedExercises: [Exercise] = []

    let onSelect: ([Exercise]) -> Void

    private var filteredExercises: [Exercise] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let muscle = selectedMuscleGroup
        let equipment = selectedEquipmentType
        return exercises.filter { exercise in
            if let muscle, exercise.muscleGroup != muscle { return false }
            if let equipment, exercise.equipmentType != equipment { return false }
            if !trimmedSearch.isEmpty,
               !exercise.name.localizedCaseInsensitiveContains(trimmedSearch) { return false }
            return true
        }
    }

    private var groupedByMuscle: [MuscleGroup: [Exercise]] {
        Dictionary(grouping: filteredExercises, by: \.muscleGroup)
    }

    private var sortedMuscleGroups: [MuscleGroup] {
        let groups = groupedByMuscle
        return MuscleGroup.allCases
            .filter { groups[$0] != nil }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "Alle", isSelected: selectedMuscleGroup == nil) {
                                selectedMuscleGroup = nil
                            }
                            ForEach(MuscleGroup.allCases.sorted { $0.displayName < $1.displayName }) { group in
                                FilterChip(title: group.displayName, isSelected: selectedMuscleGroup == group) {
                                    selectedMuscleGroup = selectedMuscleGroup == group ? nil : group
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .listRowInsets(EdgeInsets())

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "Alle", isSelected: selectedEquipmentType == nil) {
                                selectedEquipmentType = nil
                            }
                            ForEach(EquipmentType.allCases.sorted { $0.displayName < $1.displayName }) { type in
                                FilterChip(title: type.displayName, isSelected: selectedEquipmentType == type) {
                                    selectedEquipmentType = selectedEquipmentType == type ? nil : type
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .listRowInsets(EdgeInsets())
                }

                ForEach(sortedMuscleGroups) { muscleGroup in
                    muscleSection(for: muscleGroup)
                }

                if filteredExercises.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Keine Übungen gefunden",
                            systemImage: "magnifyingglass",
                            description: Text("Passe den Suchbegriff oder die Filter an.")
                        )
                        if !searchText.isEmpty || selectedMuscleGroup != nil || selectedEquipmentType != nil {
                            Button("Filter zurücksetzen") {
                                searchText = ""
                                selectedMuscleGroup = nil
                                selectedEquipmentType = nil
                            }
                        }
                    }
                }
            }
            .navigationTitle("Übungen wählen")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Übung suchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig\(selectedExercises.isEmpty ? "" : " (\(selectedExercises.count))")") {
                        onSelect(selectedExercises)
                        dismiss()
                    }
                    .disabled(selectedExercises.isEmpty)
                }
            }
        }
    }

    private func toggleSelection(_ exercise: Exercise) {
        if let index = selectedExercises.firstIndex(where: { $0.persistentModelID == exercise.persistentModelID }) {
            selectedExercises.remove(at: index)
        } else {
            selectedExercises.append(exercise)
        }
    }

    private func isSelected(_ exercise: Exercise) -> Bool {
        selectedExercises.contains { $0.persistentModelID == exercise.persistentModelID }
    }

    @ViewBuilder
    private func muscleSection(for muscleGroup: MuscleGroup) -> some View {
        let exercisesInGroup = (groupedByMuscle[muscleGroup] ?? []).sorted { $0.name < $1.name }
        Section {
            ForEach(exercisesInGroup) { exercise in
                Button {
                    toggleSelection(exercise)
                } label: {
                    HStack(spacing: 12) {
                        ExerciseImageView(exercise: exercise, size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .foregroundStyle(.primary)
                            Text(exercise.equipmentType.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isSelected(exercise) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                        }
                    }
                }
                .accessibilityAddTraits(isSelected(exercise) ? .isSelected : [])
            }
        } header: {
            Label(muscleGroup.displayName, systemImage: muscleGroup.icon)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
