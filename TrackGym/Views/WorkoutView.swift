import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutPlan.name) private var plans: [WorkoutPlan]
    @State private var showingCreatePlan = false
    @State private var planToEdit: WorkoutPlan?
    @State private var selectedDetailPlan: WorkoutPlan?
    @State private var planToStart: WorkoutPlan?
    @State private var planToDelete: WorkoutPlan?

    var body: some View {
        NavigationStack {
            planListView
                .navigationTitle("Meine Trainings")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreatePlan = true
                        } label: {
                            Label("Plan erstellen", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingCreatePlan) {
                    EditWorkoutPlanView()
                }
                .sheet(item: $planToEdit) { plan in
                    EditWorkoutPlanView(plan: plan)
                }
                .navigationDestination(item: $selectedDetailPlan) { plan in
                    WorkoutDetailView(plan: plan)
                }
                .fullScreenCover(item: $planToStart) { plan in
                    ActiveWorkoutView(plan: plan)
                }
                .confirmationDialog(
                    "Plan löschen?",
                    isPresented: Binding(
                        get: { planToDelete != nil },
                        set: { if !$0 { planToDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: planToDelete
                ) { plan in
                    Button("Löschen", role: .destructive) {
                        deletePlan(plan)
                        planToDelete = nil
                    }
                    Button("Abbrechen", role: .cancel) {
                        planToDelete = nil
                    }
                } message: { plan in
                    Text("„\(plan.name)“ wird unwiderruflich gelöscht. Gespeicherte Trainings bleiben erhalten.")
                }
        }
    }

    // MARK: - Plan List

    private var planListView: some View {
        Group {
            if plans.isEmpty {
                ContentUnavailableView {
                    Label("Keine Trainingspläne", systemImage: "list.bullet.clipboard.fill")
                } description: {
                    Text("Erstelle einen Trainingsplan, um loszulegen.")
                } actions: {
                    Button("Plan erstellen") {
                        showingCreatePlan = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section("Trainingspläne") {
                        ForEach(plans) { plan in
                            HStack(spacing: 12) {
                                Button {
                                    selectedDetailPlan = plan
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(plan.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        if !plan.exercises.isEmpty {
                                            Text(plan.orderedExercises.map(\.name).joined(separator: ", "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text("Keine Übungen")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(plan.name)
                                .accessibilityHint("Trainingsplan und Historie anzeigen")

                                Text("\(plan.exercises.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    planToStart = plan
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(plan.name) starten")
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    planToDelete = plan
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    planToEdit = plan
                                } label: {
                                    Label("Bearbeiten", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func deletePlan(_ plan: WorkoutPlan) {
        modelContext.delete(plan)
    }
}
