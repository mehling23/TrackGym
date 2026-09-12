import SwiftUI
import SwiftData
import OSLog

@main
struct TrackGymApp: App {
    private static let log = Logger(subsystem: "de.ehling.TrackGym", category: "AppLaunch")

    private let modelContainerResult: Result<ModelContainer, Error> = {
        let schema = Schema([
            Exercise.self,
            WorkoutEntry.self,
            WorkoutSet.self,
            WorkoutPlan.self,
            Workout.self,
            SeedVersion.self,
        ])
        #if DEBUG
        let inMemory = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        #else
        let inMemory = false
        #endif
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            prepareStore(container.mainContext)
            return .success(container)
        } catch {
            log.error("ModelContainer load failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }()

    init() {
        // Activate before the first view appears: the watch may wake the
        // phone app in the background to deliver a queued set, and a session
        // activated only in onAppear would miss that delivery.
        PhoneConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    // Run once per container, before any view can insert active workout drafts.
    // Root-view appearances can repeat when covers or windows are presented.
    private static func prepareStore(_ context: ModelContext) {
        DefaultExercises.seedDefaultExercises(context: context)
        do {
            try Exercise.backfillStableIDs(context: context)
        } catch {
            Self.log.error("Exercise stable ID backfill failed: \(error.localizedDescription, privacy: .public)")
        }
        #if DEBUG
        // Screenshot/demo aid: `-demoDataPath <file>` replaces the
        // store with a backup JSON at launch (see docs/screenshots).
        if let path = UserDefaults.standard.string(forKey: "demoDataPath") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                try DataExporter.importData(from: data, context: context)
                Self.log.notice("Imported demo data from \(path, privacy: .public)")
            } catch {
                Self.log.error("Demo data import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        do {
            let removed = try WorkoutHistory.deleteOrphanedEntries(in: context)
            if removed > 0 {
                Self.log.notice("Removed \(removed) orphaned workout entries left by an interrupted workout")
            }
        } catch {
            Self.log.error("Orphaned entry cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch modelContainerResult {
        case .success(let modelContainer):
            ContentView()
                .modelContainer(modelContainer)
        case .failure(let error):
            StoreUnavailableView(error: error)
        }
    }
}

private struct StoreUnavailableView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Daten konnten nicht geladen werden", systemImage: "exclamationmark.triangle.fill")
        } description: {
            VStack(spacing: 8) {
                Text("TrackGym kann die lokale Datenbank gerade nicht öffnen.")
                Text("Beende die App vollständig und starte sie erneut. Wenn das Problem bestehen bleibt, aktualisiere die App oder kontaktiere den Support, bevor du App-Daten löschst.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
