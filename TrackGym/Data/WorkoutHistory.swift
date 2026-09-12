import Foundation
import OSLog
import SwiftData

enum WorkoutHistory {
    private static let log = Logger(subsystem: "com.trackgym.app", category: "WorkoutHistory")

    static func previousEntry(
        for exercise: Exercise?,
        in context: ModelContext,
        excluding currentEntries: [WorkoutEntry] = [],
        activeWorkout: Workout? = nil
    ) -> WorkoutEntry? {
        guard let exercise else { return nil }
        // Fetch all entries for this exercise sorted by date desc, then exclude
        // entries belonging to the active workout client-side. The previous
        // implementation used `fetchLimit = 5`, which could return `nil` when
        // the active workout itself contained 5+ entries for the same exercise
        // (MHE-8). SwiftData's `#Predicate` macro does not support filtering
        // by a Swift `Set<PersistentIdentifier>`, so identity filtering and
        // exclusion remain client-side, but the limit is dropped so we never
        // miss a true previous entry.
        let descriptor = FetchDescriptor<WorkoutEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let entries: [WorkoutEntry]
        do {
            entries = try context.fetch(descriptor)
        } catch {
            // Surface the failure: in DEBUG this is almost certainly a bug
            // (corrupt store, schema mismatch) we want to catch in development.
            // In release we log a non-fatal warning so it is visible in Console
            // without crashing the user's active workout. (MHE-25)
            assertionFailure("WorkoutHistory.previousEntry fetch failed: \(error)")
            log.error("previousEntry fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let exerciseID = exercise.persistentModelID
        let currentIDs = Set(currentEntries.map(\.persistentModelID))
        let activeID = activeWorkout?.persistentModelID
        return entries.first { entry in
            entry.exercise?.persistentModelID == exerciseID &&
            // Entries without a workout are unsaved placeholders (see
            // deleteOrphanedEntries) — never a real "last training".
            entry.workout != nil &&
            !currentIDs.contains(entry.persistentModelID) &&
            (activeID == nil || entry.workout?.persistentModelID != activeID)
        }
    }

    /// The active workout inserts entries into the context before a Workout
    /// exists and attaches them on save. If the app is killed mid-workout,
    /// autosave has already written those placeholders and no code path
    /// removes them again. Called once at launch; returns the number removed.
    @discardableResult
    static func deleteOrphanedEntries(in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<WorkoutEntry>(predicate: #Predicate { $0.workout == nil })
        let orphans = try context.fetch(descriptor)
        guard !orphans.isEmpty else { return 0 }
        for entry in orphans {
            context.delete(entry)
        }
        try context.save()
        return orphans.count
    }

    @discardableResult
    static func appendSet(
        weight: Double,
        reps: Int,
        to entry: WorkoutEntry,
        in context: ModelContext
    ) -> WorkoutSet {
        let nextNumber = entry.prepareNextSetNumber()
        let newSet = WorkoutSet(setNumber: nextNumber, weight: weight, reps: reps, workoutEntry: entry)
        context.insert(newSet)
        entry.sets.append(newSet)
        return newSet
    }
}
