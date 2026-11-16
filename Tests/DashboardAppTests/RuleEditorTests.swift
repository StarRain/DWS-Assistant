import XCTest
import SwiftUI
import AppKit
import DashboardCore
@testable import DWSDashboard

@MainActor
final class RuleEditorTests: XCTestCase {
    func testRuleTextUsesAvailableWidthAndReflowsWithoutChangingContent() throws {
        let text = "包含打包、打个包时，调用项目里的scripts/publish.sh 构建，并列出脚本里的打包选项供选择"
        let editor = RuleContentEditor.makeTextView()
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        editor.string = text
        var lineLengths: [Int] = []
        for width: CGFloat in [540, 360] {
            editor.setFrameSize(NSSize(width: width, height: 220))
            layout.ensureLayout(for: container)
            var range = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &range)
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertLessThan(range.length, layout.numberOfGlyphs)
            let available = container.containerSize.width - 2 * container.lineFragmentPadding
            XCTAssertLessThan(available - used.width, 20, "Text should fill the line instead of moving a Chinese phrase as a block")
            lineLengths.append(range.length)
            XCTAssertEqual(editor.string, text)
        }
        XCTAssertGreaterThan(lineLengths[0], lineLengths[1])
    }

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
