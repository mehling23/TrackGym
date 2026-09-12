import SwiftUI
import SwiftData

struct ActiveWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    @AppStorage("restTimerDuration") private var restTimerDuration: Int = 90
    let plan: WorkoutPlan

    @State private var workoutEntries: [WorkoutEntry] = []
    @State private var workoutDate = Date()
    @State private var activeWorkout: Workout?
    @State private var showingCancelAlert = false
    @State private var showingFinishAlert = false
    @State private var showingAddExercise = false
    @State private var persistenceErrorMessage = ""
    @State private var showingPersistenceError = false
    @State private var previousEntries: [PersistentIdentifier: WorkoutEntry] = [:]
    @State private var restEndDate: Date?

    /// Entries the user actually worked on: a set added, edited, deleted, or
    /// logged from the watch. "Beenden & speichern" persists only these;
    /// untouched pre-filled placeholders are discarded instead of being
    /// written to history as if they had been performed.
    // SwiftData replaces temporary persistent IDs on the first save. Keep
    // tracking the same draft objects across autosaves and partial saves.
    @State private var touchedEntryIDs: Set<ObjectIdentifier> = []
    @State private var watchPushTask: Task<Void, Never>?
    @State private var didSetUpWorkout = false

    @State private var startTime = Date()

    private func elapsedSeconds(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startTime)))
    }

    private func elapsedTimeString(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func restTimeString(until end: Date, now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func startRestTimer() {
        guard restTimerDuration > 0 else { return }
        restEndDate = Date().addingTimeInterval(Double(restTimerDuration))
    }

    private func skipRestTimer() {
        restEndDate = nil
        sendCurrentExerciseToWatch()
    }

    private func activeRestEndsAt() -> Double? {
        guard let restEndDate, restEndDate > Date() else { return nil }
        return restEndDate.timeIntervalSince1970
    }

    var body: some View {
        NavigationStack {
            Group {
                if workoutEntries.isEmpty && activeWorkout == nil {
                    ContentUnavailableView {
                        Label("Keine Übungen", systemImage: "figure.strengthtraining.traditional")
                    } description: {
                        Text("Der Plan enthält keine Übungen.")
                    } actions: {
                        Button("Übung hinzufügen") {
                            showingAddExercise = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            TimelineView(.periodic(from: startTime, by: 1)) { context in
                                HStack {
                                    Label("Trainingszeit", systemImage: "timer")
                                    Spacer()
                                    Text(elapsedTimeString(elapsedSeconds(now: context.date)))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                            }
                            if let restEnd = restEndDate {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    if restEnd > context.date {
                                        HStack {
                                            Label("Pause", systemImage: "hourglass")
                                            Spacer()
                                            Text(restTimeString(until: restEnd, now: context.date))
                                                .font(.headline.monospacedDigit())
                                                .foregroundStyle(.orange)
                                            Button {
                                                skipRestTimer()
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Pause überspringen")
                                        }
                                    }
                                }
                            }
                            DatePicker("Datum", selection: $workoutDate, displayedComponents: .date)
                        }

                        // Exercise sections
                        ForEach(workoutEntries, id: \.editingIdentity) { entry in
                            ActiveEntrySection(
                                entry: entry,
                                previousEntry: cachedPreviousEntry(for: entry.exercise),
                                onSave: { saveEntry(entry) },
                                onSetsChanged: {
                                    markTouched(entry)
                                    sendCurrentExerciseToWatch()
                                },
                                onSetLogged: {
                                    markTouched(entry)
                                    startRestTimer()
                                    sendCurrentExerciseToWatch()
                                },
                                onSetEdited: {
                                    markTouched(entry)
                                    scheduleWatchPush()
                                }
                            )
                        }

                        // Add exercise button below all exercises
                        Section {
                            Button {
                                showingAddExercise = true
                            } label: {
                                Label("Übung hinzufügen", systemImage: "plus.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        showingCancelAlert = true
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Beenden") {
                        showingFinishAlert = true
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // onAppear can fire again after a sheet is dismissed; the
                // timer must only start once per workout.
                if !didSetUpWorkout {
                    startTime = Date()
                }
                setupExercises()
                sendCurrentExerciseToWatch()
                registerWatchAddSetHandler()
            }
            .onDisappear {
                watchPushTask?.cancel()
                PhoneConnectivityManager.shared.addSetHandler = nil
            }
            .onChange(of: workoutDate) { _, newDate in
                for entry in workoutEntries {
                    entry.date = newDate
                }
                // Entries already saved via the checkmark left `workoutEntries`
                // but must follow a retroactive date change too, or they stay
                // permanently dated on the original day.
                for entry in activeWorkout?.entries ?? [] {
                    entry.date = newDate
                }
                activeWorkout?.date = newDate
            }
            .alert("Training abbrechen?", isPresented: $showingCancelAlert) {
                Button("Training abbrechen", role: .destructive) { cancelWorkout() }
                Button("Weiter trainieren", role: .cancel) {}
            } message: {
                Text("Nicht gespeicherte Übungen gehen verloren. Bereits mit ✓ gespeicherte Übungen bleiben erhalten.")
            }
            .alert("Training beenden?", isPresented: $showingFinishAlert) {
                Button("Beenden & speichern") { finishAllAndEnd() }
                Button("Weiter trainieren", role: .cancel) {}
            } message: {
                Text(finishAlertMessage)
            }
            .alert("Training konnte nicht gespeichert werden", isPresented: $showingPersistenceError) {
                Button("OK") {}
            } message: {
                Text(persistenceErrorMessage)
            }
            .sheet(isPresented: $showingAddExercise) {
                ExercisePickerView { exercises in
                    for exercise in exercises {
                        addExercise(exercise)
                    }
                    sendCurrentExerciseToWatch()
                }
            }
        }
    }

    // MARK: - Setup

    private func setupExercises() {
        // Guard against re-runs (e.g. when the view re-appears after a sheet
        // is dismissed or the app returns from background). Without this, the
        // plan's exercises get appended again, creating duplicate entries.
        guard !didSetUpWorkout else { return }
        didSetUpWorkout = true
        for exercise in plan.orderedExercises {
            addExercise(exercise)
        }
    }

    private func markTouched(_ entry: WorkoutEntry) {
        touchedEntryIDs.insert(ObjectIdentifier(entry))
    }

    private var entriesToSave: [WorkoutEntry] {
        workoutEntries.filter { touchedEntryIDs.contains(ObjectIdentifier($0)) && !$0.sets.isEmpty }
    }

    private var entriesToDiscard: [WorkoutEntry] {
        workoutEntries.filter { !touchedEntryIDs.contains(ObjectIdentifier($0)) || $0.sets.isEmpty }
    }

    private var finishAlertMessage: String {
        let untouched = entriesToDiscard.count
        let touched = workoutEntries.count - untouched
        switch (touched, untouched) {
        case (0, 0):
            return "Das Training wird beendet."
        case (_, 0):
            return "Alle verbleibenden Übungen werden gespeichert."
        case (0, _):
            return "Keine verbleibende Übung enthält bearbeitete Sätze. Bereits gespeicherte Übungen bleiben erhalten."
        default:
            return "\(touched) bearbeitete \(touched == 1 ? "Übung wird" : "Übungen werden") gespeichert. \(untouched) leere oder nicht bearbeitete \(untouched == 1 ? "Übung wird" : "Übungen werden") verworfen."
        }
    }

    // MARK: - Logic

    private func addExercise(_ exercise: Exercise) {
        let previousEntry = findPreviousEntry(for: exercise)
        if let previousEntry {
            previousEntries[exercise.persistentModelID] = previousEntry
        }
        let previousFirstSet = previousEntry?.sortedSets.first

        let entry = WorkoutEntry(date: workoutDate, exercise: exercise)
        modelContext.insert(entry)

        let firstSet = WorkoutSet(
            setNumber: 1,
            weight: previousFirstSet?.weight ?? 0,
            reps: previousFirstSet?.reps ?? 0,
            workoutEntry: entry
        )
        modelContext.insert(firstSet)
        entry.sets.append(firstSet)
        workoutEntries.append(entry)
    }

    private func cachedPreviousEntry(for exercise: Exercise?) -> WorkoutEntry? {
        guard let exercise else { return nil }
        return previousEntries[exercise.persistentModelID]
    }

    private func findPreviousEntry(for exercise: Exercise?) -> WorkoutEntry? {
        WorkoutHistory.previousEntry(
            for: exercise,
            in: modelContext,
            excluding: workoutEntries,
            activeWorkout: activeWorkout
        )
    }

    private func saveEntry(_ entry: WorkoutEntry) {
        guard validateEntries([entry]) else { return }
        let seconds = elapsedSeconds(now: Date())
        if activeWorkout == nil {
            let workout = Workout(name: plan.name, date: workoutDate, duration: seconds)
            workout.plan = plan
            modelContext.insert(workout)
            activeWorkout = workout
        } else {
            activeWorkout?.duration = seconds
        }

        entry.date = workoutDate
        entry.workout = activeWorkout

        guard persistWorkoutChanges() else { return }

        withAnimation {
            workoutEntries.removeAll { $0.persistentModelID == entry.persistentModelID }
        }

        if workoutEntries.isEmpty {
            // Saving the last remaining entry also ends the workout, so the
            // watch must be told to clear its active-exercise UI.
            endWatchWorkout()
            dismiss()
        } else {
            sendCurrentExerciseToWatch()
        }
    }

    private func finishAllAndEnd() {
        let touched = entriesToSave
        guard validateEntries(touched) else { return }
        let seconds = elapsedSeconds(now: Date())
        // Placeholders the user never touched are not a performed workout —
        // they would land in history, volume stats and the PR badge with
        // last time's numbers (or 0 kg × 0). Drop them.
        for entry in entriesToDiscard {
            modelContext.delete(entry)
        }

        if activeWorkout == nil && !touched.isEmpty {
            let workout = Workout(name: plan.name, date: workoutDate, duration: seconds)
            workout.plan = plan
            modelContext.insert(workout)
            activeWorkout = workout
        } else {
            activeWorkout?.duration = seconds
        }
        for entry in touched {
            entry.date = workoutDate
            entry.workout = activeWorkout
        }
        // Nothing was ever saved or touched: an empty workout must not persist.
        if let workout = activeWorkout, workout.entries.isEmpty {
            modelContext.delete(workout)
            activeWorkout = nil
        }

        guard persistWorkoutChanges() else { return }

        workoutEntries.removeAll()
        endWatchWorkout()
        dismiss()
    }

    private func cancelWorkout() {
        // Delete only the pending in-memory entries that were never attached
        // to a workout. Entries the user explicitly saved with the checkmark
        // are already committed to disk — the cancel alert promises they stay.
        for entry in workoutEntries where entry.workout == nil {
            modelContext.delete(entry)
        }

        // Keep the partial Workout if it holds saved entries; delete it only
        // when nothing was ever saved (an empty workout must not persist).
        if let workout = activeWorkout {
            if workout.entries.isEmpty {
                modelContext.delete(workout)
            } else {
                workout.duration = elapsedSeconds(now: Date())
            }
        }

        guard persistWorkoutChanges(
            failureMessage: "Das abgebrochene Training konnte nicht vollständig verworfen werden. Bitte versuche es erneut."
        ) else { return }

        workoutEntries.removeAll()
        activeWorkout = nil
        endWatchWorkout()
        dismiss()
    }

    private func validateEntries(_ entries: [WorkoutEntry]) -> Bool {
        guard let invalid = entries.first(where: { !$0.hasValidSets }) else { return true }
        persistenceErrorMessage = "Bitte trage für „\(invalid.exercise?.name ?? "Übung")“ mindestens einen Satz mit gültigem Gewicht und mehr als 0 Wiederholungen ein."
        showingPersistenceError = true
        return false
    }

    // MARK: - Watch Connectivity

    private func endWatchWorkout() {
        // An edit can still have a debounced push pending when the workout
        // ends. Cancel it before sending the terminal state to the watch.
        watchPushTask?.cancel()
        watchPushTask = nil
        PhoneConnectivityManager.shared.addSetHandler = nil
        PhoneConnectivityManager.shared.sendWorkoutEnded()
    }

    private func sendCurrentExerciseToWatch() {
        guard let entry = workoutEntries.first,
              let exercise = entry.exercise else { return }
        let selectedUnit = WeightUnit.resolved(from: weightUnit)
        let payload = entry.sortedSets.map {
            WatchSetPayload(setNumber: $0.setNumber, weight: $0.weight(in: selectedUnit), reps: $0.reps)
        }
        PhoneConnectivityManager.shared.sendActiveExercise(
            name: exercise.name,
            muscleGroup: exercise.muscleGroup.rawValue,
            unit: selectedUnit.rawValue,
            sets: payload,
            restEndsAt: activeRestEndsAt()
        )
    }

    /// Weight/rep edits arrive per keystroke; coalesce them so the watch gets
    /// one push per pause in typing instead of one per digit.
    private func scheduleWatchPush() {
        watchPushTask?.cancel()
        watchPushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            sendCurrentExerciseToWatch()
        }
    }

    private func addSetFromWatch(to entry: WorkoutEntry, request: WatchAddSetRequest) {
        let selectedUnit = request.unit.flatMap(WeightUnit.init(rawValue:)) ?? WeightUnit.resolved(from: weightUnit)
        if !touchedEntryIDs.contains(ObjectIdentifier(entry)), entry.sets.count == 1,
           let placeholder = entry.sets.first {
            // The initial row is a suggestion, not an already performed set.
            placeholder.setWeight(request.weight, unit: selectedUnit)
            placeholder.reps = request.reps
        } else {
            WorkoutHistory.appendSet(weight: selectedUnit.kilograms(from: request.weight), reps: request.reps, to: entry, in: modelContext)
        }
        markTouched(entry)
        startRestTimer()
        sendCurrentExerciseToWatch()
    }

    private func registerWatchAddSetHandler() {
        PhoneConnectivityManager.shared.addSetHandler = { request in
            guard let entry = workoutEntries.first,
                  let currentName = entry.exercise?.name else { return false }
            // A set queued while unreachable during an *earlier* workout must
            // not land in this one. 120s grace absorbs clock drift between
            // the paired devices.
            if let sentAt = request.sentAt,
               sentAt < startTime.timeIntervalSince1970 - 120 {
                return false
            }
            if let expected = request.exerciseName, expected != currentName {
                // The watch shows a stale exercise — resync it instead of
                // silently dropping the set with no visible reason.
                sendCurrentExerciseToWatch()
                return false
            }
            addSetFromWatch(to: entry, request: request)
            return true
        }
    }

    private func persistWorkoutChanges(
        failureMessage: String = "Deine Änderungen wurden nicht dauerhaft gespeichert. Bitte versuche es erneut."
    ) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            persistenceErrorMessage = failureMessage
            showingPersistenceError = true
            return false
        }
    }
}

// MARK: - Active Entry Section

private struct ActiveEntrySection: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: WorkoutEntry
    let previousEntry: WorkoutEntry?
    let onSave: () -> Void
    /// Notifies the parent when the set structure changes so the current
    /// exercise state can be re-pushed to the watch.
    let onSetsChanged: () -> Void
    /// Feuert, wenn ein neuer Satz angelegt wurde (startet die Pause).
    let onSetLogged: () -> Void
    /// Feuert bei jeder Gewichts-/Wiederholungs-Eingabe in einem Satz.
    let onSetEdited: () -> Void

    var body: some View {
        Section {
            if let exercise = entry.exercise {
                ExerciseNoteRow(exercise: exercise)
            }

            if let prev = previousEntry {
                ActivePreviousReference(entry: prev)
            }

            ForEach(entry.sortedSets, id: \.editingIdentity) { set in
                ActiveSetRow(set: set, onEdit: onSetEdited)
            }
            .onDelete { offsets in
                deleteSets(at: offsets)
            }

            Button {
                addSet()
            } label: {
                Label("Satz hinzufügen", systemImage: "plus.circle")
                    .font(.subheadline)
            }
        } header: {
            HStack {
                Text(entry.exercise?.name ?? "Übung")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    onSave()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.exercise?.name ?? "Übung") speichern")
            }
            .textCase(nil)
        }
    }

    private func addSet() {
        let nextNumber = entry.prepareNextSetNumber()
        let previousSet = previousEntry?.sortedSets.first { $0.setNumber == nextNumber }
            ?? previousEntry?.sortedSets.last

        let newSet = WorkoutSet(
            setNumber: nextNumber,
            weight: previousSet?.weight ?? 0,
            reps: previousSet?.reps ?? 0,
            workoutEntry: entry
        )
        modelContext.insert(newSet)
        entry.sets.append(newSet)
        onSetLogged()
    }

    private func deleteSets(at offsets: IndexSet) {
        let sorted = entry.sortedSets
        for index in offsets {
            let set = sorted[index]
            entry.sets.removeAll { $0.persistentModelID == set.persistentModelID }
            modelContext.delete(set)
        }
        onSetsChanged()
    }
}

// MARK: - Set Row

private extension PersistentModel {
    // Autosave can promote temporary SwiftData IDs while a field is focused.
    // Keep the editing row alive throughout that promotion.
    var editingIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct ActiveSetRow: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    @Bindable var set: WorkoutSet
    let onEdit: () -> Void

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    private var displayWeight: Binding<Double> {
        Binding(
            get: { set.weight(in: selectedUnit) },
            set: {
                set.setWeight($0, unit: selectedUnit)
                onEdit()
            }
        )
    }

    private var displayReps: Binding<Int> {
        Binding(get: { set.reps }, set: {
            set.reps = $0
            onEdit()
        })
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Satz \(set.setNumber)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            HStack(spacing: 4) {
                TextField("0", value: displayWeight, format: .number)
                    .accessibilityLabel("Gewicht in \(selectedUnit.rawValue), Satz \(set.setNumber)")
                    .accessibilityIdentifier("weight-\(set.workoutEntry?.exercise?.name ?? "exercise")-\(set.setNumber)")
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text(selectedUnit.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                TextField("0", value: displayReps, format: .number)
                    .accessibilityLabel("Wiederholungen, Satz \(set.setNumber)")
                    .accessibilityIdentifier("reps-\(set.workoutEntry?.exercise?.name ?? "exercise")-\(set.setNumber)")
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("Wdh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Exercise Note

private struct ExerciseNoteRow: View {
    @Bindable var exercise: Exercise

    private var noteBinding: Binding<String> {
        Binding(
            get: { exercise.notes ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                exercise.notes = trimmed.isEmpty ? nil : $0
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Notiz", text: noteBinding, axis: .vertical)
                .font(.caption)
                .lineLimit(1...3)
        }
    }
}

// MARK: - Previous Workout Reference

private struct ActivePreviousReference: View {
    @AppStorage("weightUnit") private var weightUnit: String = WeightUnit.kg.rawValue
    let entry: WorkoutEntry

    private var selectedUnit: WeightUnit {
        WeightUnit.resolved(from: weightUnit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Letztes Training: \(entry.date, format: .dateTime.day().month())")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(entry.sortedSets) { set in
                Text("\(set.weight(in: selectedUnit), specifier: "%.1f") \(selectedUnit.rawValue) × \(set.reps) Wdh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
