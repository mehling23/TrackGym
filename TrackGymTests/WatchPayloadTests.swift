import XCTest
@testable import TrackGym

/// Covers the phone-side parsing of watch messages. The delegate callbacks
/// themselves need a live WCSession, but everything they do with a payload
/// goes through `parseAddSet`.
final class WatchPayloadTests: XCTestCase {

    func test_parseAddSet_readsAllFields() throws {
        let request = try XCTUnwrap(PhoneConnectivityManager.parseAddSet([
            "type": "addSet",
            "weight": 82.5,
            "reps": 8,
            "exerciseName": "Bankdrücken",
            "unit": "lbs",
            "id": "ABC-123",
            "sentAt": 1_700_000_000.0,
        ]))

        XCTAssertEqual(request.weight, 82.5)
        XCTAssertEqual(request.reps, 8)
        XCTAssertEqual(request.exerciseName, "Bankdrücken")
        XCTAssertEqual(request.unit, "lbs")
        XCTAssertEqual(request.id, "ABC-123")
        XCTAssertEqual(request.sentAt, 1_700_000_000.0)
    }

    func test_parseAddSet_treatsEmptyExerciseNameAsMissing() throws {
        let request = try XCTUnwrap(PhoneConnectivityManager.parseAddSet([
            "type": "addSet", "weight": 10.0, "reps": 5, "exerciseName": "",
        ]))
        XCTAssertNil(request.exerciseName)
        XCTAssertNil(request.id)
        XCTAssertNil(request.unit)
    }

    func test_parseAddSet_rejectsOtherMessageTypes() {
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "activeExercise", "weight": 10.0, "reps": 5]))
        XCTAssertNil(PhoneConnectivityManager.parseAddSet([:]))
    }

    func test_parseAddSet_rejectsMalformedNumbers() {
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": "80", "reps": 5]))
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": 80.0]))
    }

    func test_parseAddSet_rejectsImplausibleValues() {
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": -1.0, "reps": 5]))
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": 80.0, "reps": 0]))
        XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": Double.infinity, "reps": 5]))
    }

    func test_parseAddSet_acceptsNumericPropertyListRepresentations() throws {
        let request = try XCTUnwrap(PhoneConnectivityManager.parseAddSet([
            "type": "addSet", "weight": 80, "reps": 5.0,
        ]))
        XCTAssertEqual(request.weight, 80)
        XCTAssertEqual(request.reps, 5)
    }

    func test_parseAddSet_rejectsBooleansAndNonIntegralReps() {
        for weight in [true, NSNumber(value: false)] as [Any] {
            XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": weight, "reps": 5]))
        }
        for reps in [true, 5.5, Double.nan, Double.infinity, Double(Int.max)] as [Any] {
            XCTAssertNil(PhoneConnectivityManager.parseAddSet(["type": "addSet", "weight": 80.0, "reps": reps]))
        }
    }

    func test_parseAddSet_rejectsInvalidTimestampsAndUnits() {
        for stamp in [Double.nan, Double.infinity, -1.0, 0.0, true, "yesterday"] as [Any] {
            XCTAssertNil(PhoneConnectivityManager.parseAddSet([
                "type": "addSet", "weight": 80.0, "reps": 5, "sentAt": stamp,
            ]))
        }
        XCTAssertNil(PhoneConnectivityManager.parseAddSet([
            "type": "addSet", "weight": 80.0, "reps": 5, "unit": "stone",
        ]))
    }

    @MainActor
    func test_deliver_retriesARejectedSetAndOnlyDeduplicatesAfterAcceptance() throws {
        let suite = "WatchPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PhoneConnectivityManager(defaults: defaults)
        let request = try XCTUnwrap(PhoneConnectivityManager.parseAddSet([
            "type": "addSet", "weight": 80.0, "reps": 5, "id": "retry-id",
        ]))
        var handlerCalls = 0
        manager.addSetHandler = { _ in
            handlerCalls += 1
            return handlerCalls > 1
        }

        XCTAssertFalse(manager.deliver(request))
        XCTAssertTrue(manager.deliver(request))
        XCTAssertTrue(manager.deliver(request))
        XCTAssertEqual(handlerCalls, 2)

        let relaunchedManager = PhoneConnectivityManager(defaults: defaults)
        relaunchedManager.addSetHandler = { _ in
            XCTFail("An accepted set must stay deduplicated after relaunch")
            return false
        }
        XCTAssertTrue(relaunchedManager.deliver(request))
    }
}
