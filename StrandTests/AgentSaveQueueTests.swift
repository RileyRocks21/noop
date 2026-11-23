import XCTest

/// Pins the Agent Settings save queue: a burst of edits while a save is in flight must end with the
/// LAST value on the server (the old store dropped every save that arrived mid-flight, so fast
/// stepper taps reverted), and nothing may be sent twice.
final class AgentSaveQueueTests: XCTestCase {

    /// Drive the queue the way the store does: one save at a time, and when it finishes, pump the
    /// newest pending draft. `serverWrites` records every value that went over the wire.
    func testTenRapidTapsEndOnTheFinalValue() {
        var queue = AgentSaveQueue<Double>()
        var serverWrites: [Double] = []

        queue.enqueue(3.5)
        guard let first = queue.begin() else { return XCTFail("first save should start") }
        // Nine more taps land while the first save is on the wire.
        for step in 2...10 {
            queue.enqueue(3.0 + Double(step) * 0.5)
            XCTAssertNil(queue.begin(), "a second save must not start while one is in flight")
        }
        serverWrites.append(first)
        XCTAssertTrue(queue.finish(), "the newest tap is waiting")
        guard let second = queue.begin() else { return XCTFail("the newest draft should be sent next") }
        serverWrites.append(second)
        XCTAssertFalse(queue.finish())

        XCTAssertEqual(serverWrites, [3.5, 8.0])
        XCTAssertEqual(serverWrites.last, 8.0)
        XCTAssertFalse(queue.isDirty)
        XCTAssertNil(queue.latest)
    }

    func testDirtyAndLatestTrackTheUnansweredEdit() {
        var queue = AgentSaveQueue<String>()
        XCTAssertFalse(queue.isDirty)
        queue.enqueue("a")
        XCTAssertTrue(queue.isDirty)
        XCTAssertEqual(queue.begin(), "a")
        XCTAssertTrue(queue.isDirty, "in flight is still dirty")
        queue.enqueue("b")
        XCTAssertEqual(queue.latest, "b", "a view reopening mid-save starts from the newest edit")
        XCTAssertTrue(queue.finish())
        XCTAssertEqual(queue.latest, "b")
        XCTAssertEqual(queue.begin(), "b")
        XCTAssertFalse(queue.finish())
        XCTAssertFalse(queue.isDirty)
        XCTAssertNil(queue.begin(), "nothing is sent twice")
    }

    func testICalValidation() {
        XCTAssertEqual(AgentICalURL.validate("   "), .empty)
        XCTAssertEqual(AgentICalURL.validate(" https://school.example/feed.ics \n"),
                       .valid("https://school.example/feed.ics"))
        XCTAssertEqual(AgentICalURL.validate("HTTP://school.example/f.ics"),
                       .valid("HTTP://school.example/f.ics"))
        XCTAssertEqual(AgentICalURL.validate("school.example/feed.ics"), .invalid)
        XCTAssertEqual(AgentICalURL.validate("webcal://school.example/feed.ics"), .invalid)
        XCTAssertEqual(AgentICalURL.validate("https://"), .invalid)
    }
}
