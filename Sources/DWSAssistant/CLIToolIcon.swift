import SwiftUI
import AppKit
import AssistantCore

struct CLIToolIcon: View {
    let tool: CLITool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = Self.images[assetName] {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(tool.id == "pi" ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(AssistantTheme.text)
            } else {
                Text(String(tool.title.prefix(1)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AssistantTheme.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .frame(width: 30)
        .accessibilityHidden(true)
    }

    private var assetName: String {
        tool.id == "opencode" && colorScheme == .dark ? "opencode-dark" : tool.id
    }

    // Keep the original SVG representations. The bounded cache avoids reading
    // files again on every version/status update and scales without PNG assets.
    private static let images: [String: NSImage] = {
        let names = CLITool.all.map(\.id) + ["opencode-dark"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let url = Bundle.module.url(forResource: "cli-icon-" + name, withExtension: "svg"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (name, image)
        })
    }()
}
