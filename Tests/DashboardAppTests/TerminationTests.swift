import AppKit
import XCTest
@testable import DWSAssistant

@MainActor
final class TerminationTests: XCTestCase {
    func testIdleApplicationCanQuitImmediately() {
        let termination = DashboardTermination()
        let reply = termination.request(hasActiveWork: false, stop: {
            XCTFail("No service needs cleanup")
            return true
        }, terminate: { XCTFail("No second quit request is needed") })
        XCTAssertEqual(reply, .terminateNow)
    }

    func testActiveApplicationKeepsEventLoopRunningUntilCleanupFinishes() async {
        let termination = DashboardTermination()
        let started = expectation(description: "Cleanup started on the main actor")
        let finished = expectation(description: "Quit requested after cleanup")
        var cleanup: CheckedContinuation<Bool, Never>?
        let reply = termination.request(hasActiveWork: true, stop: {
            await withCheckedContinuation {
                cleanup = $0
                started.fulfill()
            }
        }, terminate: {
            XCTAssertEqual(termination.request(hasActiveWork: false, stop: {
                XCTFail("Cleanup must not restart")
                return false
            }, terminate: { XCTFail("Quit must not recurse") }), .terminateNow)
            finished.fulfill()
        })
        XCTAssertEqual(reply, .terminateCancel, "terminateLater prevents main-actor cleanup from running")
        await fulfillment(of: [started], timeout: 2)
        for hasActiveWork in [true, false] {
            XCTAssertEqual(termination.request(hasActiveWork: hasActiveWork, stop: {
                XCTFail("Repeated Command-Q must not start another cleanup")
                return true
            }, terminate: { XCTFail("Repeated Command-Q must wait for cleanup") }), .terminateCancel)
        }
        cleanup?.resume(returning: true)
        await fulfillment(of: [finished], timeout: 2)
    }

    func testFailedCleanupAllowsRetryWithoutQuitting() async {
        let termination = DashboardTermination()
        let stopped = expectation(description: "First cleanup failed")
        XCTAssertEqual(termination.request(hasActiveWork: true, stop: {
            stopped.fulfill()
            return false
        }, terminate: { XCTFail("Incomplete cleanup must keep the app running") }), .terminateCancel)
        await fulfillment(of: [stopped], timeout: 2)
        let retried = expectation(description: "Cleanup retried and quit requested")
        XCTAssertEqual(termination.request(hasActiveWork: true, stop: { true }, terminate: {
            retried.fulfill()
        }), .terminateCancel)
        await fulfillment(of: [retried], timeout: 2)
    }
}
