import SwiftUI
import AssistantCore

/// Keep interpolation values separate from translation keys. User names,
/// identifiers and rule contents are never used as localization keys.
struct UIMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(key: String, arguments: [String] = []) { self.key = key; self.arguments = arguments }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

struct UILocalizer {
    let locale: Locale
    static let english: [String: String] = {
        guard let url = Bundle.module.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            assertionFailure("Missing UI translations")
            return [:]
        }
        return values
    }()
    var isChinese: Bool { locale.identifier.lowercased().hasPrefix("zh") }

    func text(_ message: UIMessage) -> String {
        let template = isChinese ? message.key : Self.english[message.key] ?? message.key
        // Replace from the end so braces inside user content remain verbatim.
        var result = template
        let expression = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let token = Range(match.range(at: 1), in: template), let index = Int(template[token]),
                  message.arguments.indices.contains(index), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: message.arguments[index])
        }
        return result
    }
    func label(_ key: String) -> String { text(UIMessage(key: key)) }

    // Older activity records contain rendered Chinese text. Match only the
    // allowlisted app diagnostics, anchored to the whole message. Captured
    // names, paths and external CLI output stay verbatim; logs on disk stay
    // unchanged. Never use this for user-provided content.
    private static let diagnosticPatterns: [(String, NSRegularExpression)] = {
        guard let url = Bundle.module.url(forResource: "DiagnosticKeys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let tokens = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        return keys.sorted { $0.count > $1.count }.compactMap { key in
            var pattern = "", offset = key.startIndex
            for token in tokens.matches(in: key, range: NSRange(key.startIndex..., in: key)) {
                guard let range = Range(token.range, in: key) else { continue }
                pattern += NSRegularExpression.escapedPattern(for: String(key[offset..<range.lowerBound])) + "(.*?)"
                offset = range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(key[offset...]))
            guard let expression = try? NSRegularExpression(pattern: "\\A" + pattern + "\\z", options: .dotMatchesLineSeparators) else { return nil }
            return (key, expression)
        }
    }()

    func diagnostic(_ source: String) -> String {
        guard !isChinese else { return source }
        if let exact = Self.english[source] { return exact }
        for (key, pattern) in Self.diagnosticPatterns {
            guard let match = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            let values = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: source).map { String(source[$0]) } ?? ""
            }
            return text(UIMessage(key: key, arguments: values))
        }
        return source
    }
}

protocol AssistantLocalizedView: View { var locale: Locale { get } }
extension AssistantLocalizedView {
    func l(_ message: UIMessage) -> String { UILocalizer(locale: locale).text(message) }
    func tr(_ key: String) -> String { UILocalizer(locale: locale).label(key) }
    func diagnostic(_ source: String) -> String { UILocalizer(locale: locale).diagnostic(source) }
}

/// For shared presentation helpers that receive app-owned labels.
struct TranslatedText: View {
    @Environment(\.locale) private var locale
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View { Text(UILocalizer(locale: locale).diagnostic(value)) }
}

struct LanguagePicker: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Picker(l("语言"), selection: Binding(get: { model.config.language }, set: model.setLanguage)) {
            Text("简体中文").tag(AppLanguage.simplifiedChinese)
            Text("English").tag(AppLanguage.english)
        }.labelsHidden().frame(width: 190).accessibilityLabel(l("语言"))
    }
}
