import WatchConnectivity
import Foundation
import CoreFoundation

nonisolated struct WatchSetPayload: Hashable {
    let setNumber: Int
    let weight: Double
    let reps: Int
}

/// A set logged on the watch, validated and ready for the active workout.
nonisolated struct WatchAddSetRequest: Sendable {
    let weight: Double
    let reps: Int
    let exerciseName: String?
    /// Display unit used on the watch when the set was entered.
    let unit: String?
    /// Watch-side timestamp (timeIntervalSince1970). Used to drop stale sets
    /// that were queued during an earlier workout.
    let sentAt: Double?
    /// Per-send id the watch attaches so duplicate deliveries can be dropped.
    let id: String?
}

@MainActor
final class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityManager()
    nonisolated static let maximumAcceptedWeight = 2_000.0
    nonisolated static let maximumAcceptedReps = 1_000
    private static let processedSetIDsKey = "processedWatchSetIDs"

    /// Registered by ActiveWorkoutView while a workout is running. Returns
    /// true when the set was accepted and appended to the current exercise.
    var addSetHandler: ((WatchAddSetRequest) -> Bool)?

    /// Ids of recently processed sets, persisted so a relaunch between the
    /// original delivery and the watch's transferUserInfo retry still drops
    /// the duplicate.
    private var recentSetIDs: RecentIDBuffer
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSetIDs = RecentIDBuffer.load(from: defaults, key: Self.processedSetIDsKey)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendActiveExercise(name: String, muscleGroup: String, unit: String, sets: [WatchSetPayload], restEndsAt: Double? = nil) {
        let setsDicts: [[String: Any]] = sets.map {
            ["setNumber": $0.setNumber, "weight": $0.weight, "reps": $0.reps]
        }
        var payload: [String: Any] = [
            "type": "activeExercise",
            "exerciseName": name,
            "muscleGroup": muscleGroup,
            "unit": unit,
            "sets": setsDicts
        ]
        if let restEndsAt {
            payload["restEndsAt"] = restEndsAt
        }
        pushState(payload)
    }

    func sendWorkoutEnded() {
        pushState(["type": "workoutEnded"])
    }

    private func pushState(_ payload: [String: Any]) {
        var payload = payload
        // Fresh stamp per push: makes every applicationContext update distinct
        // (identical dictionaries are not redelivered) and lets the watch
        // remember which state the user dismissed locally.
        payload["sentAt"] = Date().timeIntervalSince1970
        // Application context survives unreachability and is replayed on watch wake.
        do {
            try WCSession.default.updateApplicationContext(payload)
        } catch {
            NSLog("updateApplicationContext failed: %@", error.localizedDescription)
        }
        // Best-effort immediate delivery when the watch is awake and reachable.
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(payload, replyHandler: nil) { error in
            NSLog("sendMessage state failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Incoming sets
    //
    // WCSession invokes its delegate on a private background queue, so the
    // delegate methods are `nonisolated`. They parse the plist dictionary
    // into a Sendable request right there and hop to the main actor with
    // that instead of with the dictionary.

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let parsed = Self.parseAddSet(message)
        Task { @MainActor in
            _ = self.deliver(parsed)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let parsed = Self.parseAddSet(message)
        // WCSession's reply block may be invoked from any queue; it is only
        // not annotated Sendable in the ObjC header.
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            let accepted = self.deliver(parsed)
            reply(["status": accepted ? "ok" : "rejected"])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let parsed = Self.parseAddSet(userInfo)
        Task { @MainActor in
            _ = self.deliver(parsed)
        }
    }

    /// Returns nil for anything that is not a well-formed, plausible addSet.
    nonisolated static func parseAddSet(_ message: [String: Any]) -> WatchAddSetRequest? {
        guard let type = message["type"] as? String, type == "addSet",
              let weight = numberValue(message["weight"]),
              let rawReps = numberValue(message["reps"]),
              let reps = Int(exactly: rawReps) else { return nil }
        guard isValidAddSetPayload(weight: weight, reps: reps) else {
            NSLog("Ignoring invalid watch addSet payload")
            return nil
        }
        let sentAt = numberValue(message["sentAt"])
        if message["sentAt"] != nil {
            guard let sentAt, sentAt.isFinite, sentAt > 0 else { return nil }
        }
        let unit = message["unit"] as? String
        if message["unit"] != nil {
            guard unit == "kg" || unit == "lbs" else { return nil }
        }
        return WatchAddSetRequest(
            weight: weight,
            reps: reps,
            exerciseName: (message["exerciseName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            unit: unit,
            sentAt: sentAt,
            id: (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The result is also the acknowledgement sent back to the watch.
    func deliver(_ request: WatchAddSetRequest?) -> Bool {
        guard let request else { return false }
        if let id = request.id, recentSetIDs.contains(id) {
            // Duplicate delivery of a set that was already accepted.
            return true
        }
        guard let handler = addSetHandler else {
            // No workout is running on the phone — clear the watch so it does
            // not keep showing a stale session and swallowing sets.
            sendWorkoutEnded()
            return false
        }
        guard handler(request) else { return false }
        if let id = request.id { _ = markSetIDProcessed(id) }
        return true
    }

    /// Returns false when the id was already processed.
    private func markSetIDProcessed(_ id: String) -> Bool {
        guard recentSetIDs.insert(id) else { return false }
        recentSetIDs.save(to: defaults, key: Self.processedSetIDsKey)
        return true
    }

    nonisolated static func isValidAddSetPayload(weight: Double, reps: Int) -> Bool {
        weight.isFinite &&
        weight >= 0 &&
        weight <= maximumAcceptedWeight &&
        reps > 0 &&
        reps <= maximumAcceptedReps
    }

    nonisolated private static func numberValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
