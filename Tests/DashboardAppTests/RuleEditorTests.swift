import XCTest
import SwiftUI
import DashboardCore
@testable import DWSDashboard

@MainActor
final class RuleEditorTests: XCTestCase {
    func testDelayedTextCallbacksAfterDeletionDoNotCrashOrEditAnotherRule() {
        let first = AgentRule(name: "第一条", content: "第一条内容")
        let second = AgentRule(name: "第二条", content: "第二条内容")
        var values = [first, second]
        let collection = Binding(get: { values }, set: { values = $0 })
        let firstEditor = AgentRulesEditor.ruleBinding(for: first, in: collection)
        let secondEditor = AgentRulesEditor.ruleBinding(for: second, in: collection)
        values.removeFirst()
        XCTAssertEqual(firstEditor.wrappedValue, first)
        firstEditor.name.wrappedValue = "已删除输入框的延迟回调"
        XCTAssertEqual(values, [second])
        secondEditor.content.wrappedValue = "位置改变后继续编辑"
        XCTAssertEqual(values[0].id, second.id)
        XCTAssertEqual(values[0].content, "位置改变后继续编辑")
        values.removeAll()
        XCTAssertEqual(secondEditor.wrappedValue.id, second.id)
        secondEditor.content.wrappedValue = "删除最后一项后的延迟回调"
        XCTAssertTrue(values.isEmpty)
    }
}
