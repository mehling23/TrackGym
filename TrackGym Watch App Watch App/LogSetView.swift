import SwiftUI
import WatchKit

struct LogSetView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) private var dismiss

    private enum FocusField: Hashable {
        case weight
        case reps
    }

    @FocusState private var focusedField: FocusField?
    @State private var weight: Double = 0
    @State private var reps: Int = 1

    /// Crown range in the *display* unit: 300 kg and its lbs equivalent,
    /// so heavy lifts stay loggable regardless of the selected unit.
    private var maxWeight: Double {
        connectivity.unit == "lbs" ? 660 : 300
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gewicht (\(connectivity.unit))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(weight, specifier: "%.1f") \(connectivity.unit)")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(focusedField == .weight ? Color.blue.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focusedField == .weight ? Color.blue : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .weight }
                .focusable()
                .focused($focusedField, equals: .weight)
                .digitalCrownRotation(
                    $weight,
                    from: 0,
                    through: maxWeight,
                    by: 0.5,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wiederholungen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(reps) Wdh")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(focusedField == .reps ? Color.blue.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focusedField == .reps ? Color.blue : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .reps }
                .focusable()
                .focused($focusedField, equals: .reps)
                .digitalCrownRotation(
                    Binding(
                        get: { Double(reps) },
                        set: { reps = max(1, Int($0.rounded())) }
                    ),
                    from: 1,
                    through: 50,
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

                Button {
                    saveSet()
                } label: {
                    Label("Speichern", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding()
        }
        .navigationTitle("Satz loggen")
        .onAppear {
            if focusedField == nil {
                focusedField = .weight
            }
            // Prefill from the most recent set so the user only fine-tunes.
            if weight == 0, let last = connectivity.sets.last {
                weight = last.weight
                reps = max(1, last.reps)
            }
        }
    }

    private func saveSet() {
        // Haptic reflects the real outcome instead of unconditional success:
        // .success = phone accepted, .click = queued for later delivery,
        // .failure = phone refused (stale exercise / no active workout).
        connectivity.sendSet(weight: weight, reps: reps) { outcome in
            switch outcome {
            case .delivered:
                WKInterfaceDevice.current().play(.success)
            case .queued:
                WKInterfaceDevice.current().play(.click)
            case .rejected:
                WKInterfaceDevice.current().play(.failure)
            }
        }
        dismiss()
    }
}
