import SwiftUI
import AppKit
import DashboardCore

extension AppAppearance {
    var symbol: String {
        switch self { case .system: return "desktopcomputer"; case .light: return "sun.max"; case .dark: return "moon" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var nativeAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum DashboardTheme {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255,
                           green: CGFloat(value >> 8 & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive(light: 0xf5f7ff, dark: 0x080d22)
    static let sidebar = adaptive(light: 0xecf0fc, dark: 0x060a1b)
    static let card = adaptive(light: 0xffffff, dark: 0x111a34)
    static let subtle = adaptive(light: 0xeaf0ff, dark: 0x0d1530)
    static let selected = adaptive(light: 0xe2e9ff, dark: 0x1b2a56)
    static let border = adaptive(light: 0xe0e7f8, dark: 0x243459)
    static let form = adaptive(light: 0xedf1fa, dark: 0x0f172f)
    static let separator = adaptive(light: 0xdfe5f1, dark: 0x1b2741)
    static let text = adaptive(light: 0x172345, dark: 0xeaf0ff)
    static let secondary = adaptive(light: 0x5b6988, dark: 0xa8b9db)
    static let muted = adaptive(light: 0x6c7b99, dark: 0x8f9fc3)
    static let accent = adaptive(light: 0x3659df, dark: 0x8caeff)
    static let action = adaptive(light: 0x385cf0, dark: 0x466cf4)
    static let violet = adaptive(light: 0x7748eb, dark: 0xa17bff)
    static let cyan = adaptive(light: 0x087bad, dark: 0x47c5f5)
    static let brandGradient = LinearGradient(colors: [violet, accent, cyan], startPoint: .leading, endPoint: .trailing)
}

struct AppearancePicker: View {
    @EnvironmentObject var model: DashboardModel
    var body: some View {
        HStack(spacing: 3) {
            ForEach(AppAppearance.allCases) { appearance in
                Button { model.setAppearance(appearance) } label: {
                    Label(appearance.title, systemImage: appearance.symbol)
                        .font(.system(size: 12, weight: model.config.appearance == appearance ? .semibold : .regular))
                        .padding(.horizontal, 13).frame(height: 34)
                        .contentShape(Rectangle())
                        .background(model.config.appearance == appearance ? DashboardTheme.card : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.config.appearance == appearance ? DashboardTheme.border : .clear).allowsHitTesting(false))
                }.buttonStyle(.plain)
                    .foregroundStyle(model.config.appearance == appearance ? DashboardTheme.accent : DashboardTheme.secondary)
                    .accessibilityAddTraits(model.config.appearance == appearance ? .isSelected : [])
            }
        }.padding(4).background(DashboardTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
}
