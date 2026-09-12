import WatchConnectivity
import Foundation
import Observation
import WatchKit
import CoreFoundation

struct WatchSet: Identifiable, Hashable {
    let setNumber: Int
    let weight: Double
    let reps: Int

    var id: Int { setNumber }
}

/// Outcome of logging a set from the watch, surfaced as haptic feedback.
enum SetDeliveryOutcome {
    /// The phone accepted the set into the running workout.
    case delivered
    /// The phone was unreachable — queued via transferUserInfo for guaranteed
    /// later delivery.
    case queued
    /// The phone refused the set (stale exercise state or no active workout).
    case rejected
}

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()
    private static let clearedContextStampKey = "clearedContextStamp"
    private let defaults: UserDefaults

    /// Stored application context older than this is not replayed on launch.
    /// If the phone app died mid-workout it never sent `workoutEnded`, and
    /// resurrecting that state days later would show a phantom workout and
    /// start a HealthKit session for it. Longer than any real session.
    nonisolated static let maxReplayAge: TimeInterval = 4 * 60 * 60

    var exerciseName: String = ""
    var muscleGroup: String = ""
    var unit: String = "kg"
    var sets: [WatchSet] = []
    var workoutActive: Bool = false
    var isReachable: Bool = false
    var hasActivated: Bool = false

    /// Endzeitpunkt der laufenden Satzpause; nil wenn kein Timer aktiv.
    var restEndDate: Date?

    @ObservationIgnored
    private var restHapticTask: Task<Void, Never>?

    /// Stamp (`sentAt`) of the state currently applied. Persisted on
    /// clearLocalState so activation replay cannot resurrect a workout the
    /// user dismissed on the watch.
    private var lastContextStamp: Double = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func activate() {
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendSet(weight: Double, reps: Int, completion: @escaping (SetDeliveryOutcome) -> Void) {
        let message: [String: Any] = [
            "type": "addSet",
            "weight": weight,
            "reps": reps,
            "exerciseName": exerciseName,
            "unit": unit,
            "id": UUID().uuidString,
            "sentAt": Date().timeIntervalSince1970
        ]
        let finish: (SetDeliveryOutcome) -> Void = { outcome in
            Task { @MainActor in completion(outcome) }
        }
        guard WCSession.default.isReachable else {
            WCSession.default.transferUserInfo(message)
            finish(.queued)
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            finish((reply["status"] as? String) == "ok" ? .delivered : .rejected)
        }, errorHandler: { error in
            NSLog("addSet sendMessage failed, queuing: %@", error.localizedDescription)
            WCSession.default.transferUserInfo(message)
            finish(.queued)
        })
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        applyState(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyState(applicationContext)
    }

    /// Entry point for incoming WCSession payloads. WCSessionDelegate callbacks
    /// arrive on a background queue, so this wrapper hops to the main actor and
    /// invokes the synchronous mutation core. Production call sites are unchanged.
    nonisolated func applyState(_ message: [String: Any]) {
        // WCSession hands over a freshly decoded plist dictionary that nothing
        // else references, so moving it to the main actor is safe.
        nonisolated(unsafe) let payload = message
        Task { @MainActor in
            self.applyStateSynchronously(payload)
        }
    }

    /// Synchronous, MainActor-isolated mutation core. Exposed at internal
    /// visibility so unit tests can drive state transitions deterministically
    /// without relying on `Task.sleep` to bridge the async hop.
    @MainActor
    func applyStateSynchronously(_ message: [String: Any]) {
        guard let type = message["type"] as? String,
              type == "activeExercise" || type == "workoutEnded" else { return }
        if message["sentAt"] != nil {
            guard let stamp = Self.doubleValue(message["sentAt"]),
                  stamp.isFinite, stamp > 0,
                  stamp > lastContextStamp else { return }
            // Immediate messages and application contexts can arrive in either
            // order. Neither an older state nor a dismissed duplicate may
            // reactivate a workout that has already ended on the watch.
            if type == "activeExercise",
               stamp <= defaults.double(forKey: Self.clearedContextStampKey) { return }
            lastContextStamp = stamp
        }
        switch type {
        case "activeExercise":
            self.exerciseName = message["exerciseName"] as? String ?? ""
            self.muscleGroup = message["muscleGroup"] as? String ?? ""
            self.unit = message["unit"] as? String ?? "kg"
            let raw = message["sets"] as? [[String: Any]] ?? []
            // Tolerant number parsing: values boxed as Swift Int or Double do
            // not cross-cast through Any, and payloads produced in-process
            // (tests) or via plist decoding may carry either representation.
            var seenSetNumbers = Set<Int>()
            self.sets = raw.compactMap { dict in
                guard let n = Self.intValue(dict["setNumber"]),
                      let w = Self.doubleValue(dict["weight"]),
                      let r = Self.intValue(dict["reps"]),
                      n > 0, w.isFinite, w >= 0, r >= 0,
                      seenSetNumbers.insert(n).inserted else { return nil }
                return WatchSet(setNumber: n, weight: w, reps: r)
            }
            self.workoutActive = true
            let now = Date().timeIntervalSince1970
            if let ends = Self.doubleValue(message["restEndsAt"]),
               ends.isFinite, ends > now, ends - now <= Self.maxReplayAge {
                self.restEndDate = Date(timeIntervalSince1970: ends)
            } else {
                self.restEndDate = nil
            }
            scheduleRestHaptic()
        case "workoutEnded":
            self.workoutActive = false
            self.exerciseName = ""
            self.muscleGroup = ""
            self.unit = "kg"
            self.sets = []
            self.restEndDate = nil
            restHapticTask?.cancel()
        default:
            break
        }
    }

    /// Terminiert die Handgelenk-Haptik lokal auf der Watch — kein Timing
    /// über die Funkverbindung. Jedes neue Payload ersetzt den Termin.
    @MainActor
    private func scheduleRestHaptic() {
        restHapticTask?.cancel()
        guard let end = restEndDate else { return }
        let interval = end.timeIntervalSinceNow
        guard interval > 0 else { return }
        restHapticTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, self.workoutActive else { return }
            WKInterfaceDevice.current().play(.notification)
        }
    }

    /// Clears workout state locally without requiring the phone to be reachable.
    /// Use this as an escape hatch when the phone process was killed mid-workout
    /// and the watch is stuck with workoutActive = true.
    @MainActor
    func clearLocalState() {
        // Remember which pushed state was dismissed so the activation replay
        // below does not immediately resurrect it on the next app launch.
        defaults.set(lastContextStamp, forKey: Self.clearedContextStampKey)
        workoutActive = false
        exerciseName = ""
        muscleGroup = ""
        unit = "kg"
        sets = []
        restEndDate = nil
        restHapticTask?.cancel()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        // didReceiveApplicationContext only fires for content that has not
        // been delivered yet; a context received before the watch app was
        // terminated is never replayed by the system. Restore it manually so
        // a relaunched watch app rejoins the still-running workout.
        nonisolated(unsafe) let stored = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            let clearedStamp = self.defaults.double(forKey: Self.clearedContextStampKey)
            if Self.shouldReplay(context: stored, clearedStamp: clearedStamp, now: Date()) {
                self.applyStateSynchronously(stored)
            }
            // Recover only after the phone state is known. At launch the
            // default workoutActive=false does not mean the workout ended.
            WorkoutSessionController.shared.recoverIfNeeded { self.workoutActive }
            self.hasActivated = true
        }
    }

    /// Whether a stored application context should be re-applied on launch.
    /// Rejects empty contexts, the exact state the user dismissed via
    /// `clearLocalState`, and anything older than `maxReplayAge`.
    nonisolated static func shouldReplay(context: [String: Any], clearedStamp: Double, now: Date) -> Bool {
        guard !context.isEmpty else { return false }
        guard context["sentAt"] != nil else { return true }
        guard let stamp = doubleValue(context["sentAt"]), stamp.isFinite, stamp > 0 else { return false }
        if stamp <= clearedStamp { return false }
        let age = now.timeIntervalSince1970 - stamp
        return age >= -120 && age <= maxReplayAge
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        guard let number = doubleValue(value) else { return nil }
        return Int(exactly: number)
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
