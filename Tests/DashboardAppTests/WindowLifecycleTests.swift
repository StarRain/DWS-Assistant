import AppKit
import XCTest
@testable import DWSAssistant

@MainActor
final class WindowLifecycleTests: XCTestCase {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    }

    func testOnlyClosingMainWindowHidesDockAndReopeningRestoresIt() async {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let lifecycle = DashboardWindowLifecycle(notifications: notifications) { policies.append($0) }
        let main = window(), quick = window()
        lifecycle.attach(to: main)
        notifications.post(name: NSWindow.willCloseNotification, object: quick)
        notifications.post(name: NSWindow.didMiniaturizeNotification, object: main)
        notifications.post(name: NSWindow.didResignKeyNotification, object: main)
        await Task.yield()
        XCTAssertEqual(policies, [.regular], "Quick panels, minimization and focus changes keep Dock state unchanged")
        notifications.post(name: NSWindow.willCloseNotification, object: main)
        for _ in 0..<10 where policies.last != .accessory { await Task.yield() }
        XCTAssertEqual(policies.last, .accessory)
        lifecycle.prepareToOpenMainWindow()
        XCTAssertEqual(policies.last, .regular)
    }

    func testReopeningBeforeCloseFinishesDoesNotHideDockAgain() async {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let lifecycle = DashboardWindowLifecycle(notifications: notifications) { policies.append($0) }
        let main = window()
        lifecycle.attach(to: main)
        notifications.post(name: NSWindow.willCloseNotification, object: main)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: main)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(policies.contains(.accessory))
        XCTAssertEqual(policies.last, .regular)
    }

    func testRecreatedMainWindowReplacesOldObservers() async {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let lifecycle = DashboardWindowLifecycle(notifications: notifications) { policies.append($0) }
        let old = window(), current = window()
        lifecycle.attach(to: old)
        notifications.post(name: NSWindow.willCloseNotification, object: old)
        lifecycle.attach(to: current)
        notifications.post(name: NSWindow.willCloseNotification, object: old)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(policies.contains(.accessory))
        notifications.post(name: NSWindow.willCloseNotification, object: current)
        for _ in 0..<10 where policies.last != .accessory { await Task.yield() }
        XCTAssertEqual(policies.last, .accessory)
    }
}
