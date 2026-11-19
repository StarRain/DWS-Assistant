import SwiftUI

enum ConfigurationLayout {
    static let panelWidth: CGFloat = 670
    static let pickerWidth = panelWidth / 3
}

extension View {
    func configurationPicker() -> some View {
        pickerStyle(.menu).labelsHidden()
            .frame(width: ConfigurationLayout.pickerWidth, alignment: .trailing)
    }
}

/// One setting and its explanation share a cell. Separators are drawn here so
/// they stay subtle in both appearances instead of inheriting Form's contrast.
struct ConfigurationRow<Content: View>: View {
    var divided = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .overlay(alignment: .top) {
                if divided { AssistantTheme.separator.frame(height: 0.5).allowsHitTesting(false) }
            }
    }
}

struct ConfigurationGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 14)
            .labeledContentStyle(ConfigurationLabelStyle())
            .background(AssistantTheme.form, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct ConfigurationLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

struct ConfigurationToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        HStack {
            TranslatedText(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct ConfigurationSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranslatedText(title).font(.headline).padding(.horizontal, 10)
            ConfigurationGroup { content }
        }
    }
}

struct AssistantDivider: View {
    var body: some View {
        AssistantTheme.separator.frame(height: 0.5).accessibilityHidden(true)
    }
}
