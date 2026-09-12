import SwiftUI
import SwiftData

struct ExerciseListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var showingAddExercise = false
    @State private var selectedMuscleGroup: MuscleGroup?
    @State private var selectedEquipmentType: EquipmentType?
    @State private var exerciseToDelete: Exercise?

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
            .navigationTitle("Übungen")
            .searchable(text: $searchText, prompt: "Übung suchen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddExercise = true
                    } label: {
                        Label("Übung hinzufügen", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExerciseView()
            }
            .confirmationDialog(
                "Übung löschen?",
                isPresented: Binding(
                    get: { exerciseToDelete != nil },
                    set: { if !$0 { exerciseToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: exerciseToDelete
            ) { exercise in
                Button("Übung löschen", role: .destructive) {
                    deleteExercise(exercise)
                    exerciseToDelete = nil
                }
                Button("Abbrechen", role: .cancel) {
                    exerciseToDelete = nil
                }
            } message: { exercise in
                Text("„\(exercise.name)“ wird gelöscht. Frühere Trainingseinträge bleiben erhalten und zeigen dann keine verknüpfte Übung mehr an.")
            }
        }
    }

    private func deleteExercise(_ exercise: Exercise) {
        withAnimation {
            modelContext.delete(exercise)
        }
    }

    @ViewBuilder
    private func muscleSection(for muscleGroup: MuscleGroup) -> some View {
        let exercisesInGroup = (groupedByMuscle[muscleGroup] ?? []).sorted { $0.name < $1.name }
        Section {
            ForEach(exercisesInGroup) { exercise in
                ExerciseRow(exercise: exercise)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if exercise.isCustom {
                            Button(role: .destructive) {
                                exerciseToDelete = exercise
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
            }
        } header: {
            Label(muscleGroup.displayName, systemImage: muscleGroup.icon)
                .font(.headline)
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

private struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            ExerciseImageView(exercise: exercise)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.body)
                Text(exercise.equipmentType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if exercise.isCustom {
                Text("Eigene")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
    }
}
