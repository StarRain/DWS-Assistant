import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans", english = "en"
    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Migrate the earlier automatic choice to the explicit default.
        if value == "system" { self = .simplifiedChinese }
        else if let language = Self(rawValue: value) { self = language }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported interface language") }
    }

    public var locale: Locale { Locale(identifier: rawValue) }
}
