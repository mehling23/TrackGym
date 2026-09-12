import SwiftUI

struct ContentView: View {
    @State private var connectivity = WatchConnectivityManager.shared
    @State private var sessionController = WorkoutSessionController.shared

    var body: some View {
        Group {
            if connectivity.workoutActive {
                WorkoutSessionView()
                    .environment(connectivity)
                    .environment(sessionController)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.largeTitle)
                    Text("Starte ein Workout auf dem iPhone")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        // initial: a cold start straight into a running workout (context
        // replay) must start the HealthKit session too, not only a change.
        .onChange(of: connectivity.workoutActive && connectivity.hasActivated, initial: true) { _, isActive in
            if isActive {
                sessionController.startIfNeeded()
            } else {
                sessionController.end()
            }
        }
    }
}
