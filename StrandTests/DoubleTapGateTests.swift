import XCTest
@testable import Strand

/// The strap firmware decides what a double-tap is and its threshold cannot be tuned, so knocks against
/// a desk or a bag register as gestures. Reported as "WAY too sensitive" with the Find iPhone siren on
/// double-tap: one false gesture blared the siren. `DoubleTapGate` is the software confirmation on top,
/// and these pin what each sensitivity asks for.
final class DoubleTapGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_910_464)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testStandardFiresOnEveryDoubleTap() {
        var g = DoubleTapGate(sensitivity: .standard)
        XCTAssertEqual(g.register(at: at(0)), .fire)
        XCTAssertEqual(g.register(at: at(2)), .fire)
        XCTAssertEqual(g.pendingCount, 0)
    }

    func testLowNeedsTwoWithinFourSeconds() {
        var g = DoubleTapGate(sensitivity: .low)
        XCTAssertEqual(g.register(at: at(0)), .armed(count: 1, required: 2, window: 4))
        XCTAssertEqual(g.register(at: at(3.5)), .fire)
        // A fire resets: the next tap starts a fresh sequence.
        XCTAssertEqual(g.register(at: at(5)), .armed(count: 1, required: 2, window: 4))
    }

    func testLowDoesNotFireWhenTheSecondTapIsTooLate() {
        var g = DoubleTapGate(sensitivity: .low)
        XCTAssertEqual(g.register(at: at(0)), .armed(count: 1, required: 2, window: 4))
        // 4.5 s later: the first tap has expired, so this one only arms again...
        XCTAssertEqual(g.register(at: at(4.5)), .armed(count: 1, required: 2, window: 4))
        // ...and a prompt follow-up confirms on the new pair.
        XCTAssertEqual(g.register(at: at(6)), .fire)
    }

    func testLowFiresAtExactlyTheWindowEdge() {
        var g = DoubleTapGate(sensitivity: .low)
        _ = g.register(at: at(0))
        XCTAssertEqual(g.register(at: at(4)), .fire)
    }

    func testLowestNeedsThreeWithinSixSeconds() {
        var g = DoubleTapGate(sensitivity: .lowest)
        XCTAssertEqual(g.register(at: at(0)), .armed(count: 1, required: 3, window: 6))
        XCTAssertEqual(g.register(at: at(2)), .armed(count: 2, required: 3, window: 6))
        XCTAssertEqual(g.register(at: at(5)), .fire)
        XCTAssertEqual(g.pendingCount, 0)
    }

    func testLowestSlidesPastAStrayKnock() {
        var g = DoubleTapGate(sensitivity: .lowest)
        _ = g.register(at: at(0))                    // stray knock
        _ = g.register(at: at(5))                    // deliberate 1
        // 7 s: the knock is older than 6 s and drops out, leaving two, not three.
        XCTAssertEqual(g.register(at: at(7)), .armed(count: 2, required: 3, window: 6))
        XCTAssertEqual(g.register(at: at(9)), .fire)
    }

    func testChangingSensitivityDropsAHalfFinishedSequence() {
        var g = DoubleTapGate(sensitivity: .lowest)
        _ = g.register(at: at(0))
        _ = g.register(at: at(1.5))
        g.sensitivity = .low
        XCTAssertEqual(g.pendingCount, 0)
        XCTAssertEqual(g.register(at: at(3)), .armed(count: 1, required: 2, window: 4))
    }

    func testSettingTheSameSensitivityKeepsTheSequence() {
        var g = DoubleTapGate(sensitivity: .low)
        _ = g.register(at: at(0))
        g.sensitivity = .low
        XCTAssertEqual(g.register(at: at(2)), .fire)
    }

    func testResetForgetsPendingTaps() {
        var g = DoubleTapGate(sensitivity: .low)
        _ = g.register(at: at(0))
        g.reset()
        XCTAssertEqual(g.register(at: at(1.5)), .armed(count: 1, required: 2, window: 4))
    }

    func testDefaultIsLow() {
        XCTAssertEqual(DoubleTapGate().sensitivity, .low)
    }

    /// The raw values are persisted in UserDefaults; renaming a case would silently reset users.
    func testPersistedRawValuesAreStable() {
        XCTAssertEqual(DoubleTapSensitivity.allCases.map(\.rawValue), ["standard", "low", "lowest"])
        XCTAssertEqual(DoubleTapSensitivity.allCases.map(\.requiredTaps), [1, 2, 3])
        XCTAssertEqual(DoubleTapSensitivity.allCases.map(\.window), [0, 4, 6])
    }
}
