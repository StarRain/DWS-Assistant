import SwiftUI
import AppKit
import AssistantCore
import Darwin

@main
enum AssistantEntry {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        AssistantApp.main()
    }
}

@MainActor
struct AssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AssistantModel
    init() {
        let args = CommandLine.arguments
        let preview = args.contains("--preview") || args.contains("--screenshot")
        let directory: URL?
        if let i = args.firstIndex(of: "--data-dir"), args.count > i + 1 { directory = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
        else if preview { directory = FileManager.default.temporaryDirectory.appendingPathComponent("DWS-Assistant-Preview-\(ProcessInfo.processInfo.processIdentifier)") }
        else { directory = nil }
        _model = StateObject(wrappedValue: AssistantModel(preview: preview, directory: directory))
    }
    var body: some Scene {
        Window(UILocalizer(locale: model.config.language.locale).label("DWS助手"), id: "dashboard") {
            Group {
                if model.needsSetup { SetupView() }
                else { AssistantView() }
            }
                .environmentObject(model).environment(\.locale, model.config.language.locale)
                .frame(minWidth: 1080, minHeight: 700)
                .background(MainWindowObserver(lifecycle: delegate.windowLifecycle))
                .onAppear {
                    prepareModel()
                    if CommandLine.arguments.contains("--screenshot") { renderScreenshot() }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button(UILocalizer(locale: model.config.language.locale).label("关闭助手并退出")) { delegate.requestQuit() }.keyboardShortcut("q")
            }
            CommandGroup(after: .windowArrangement) { QuickPanelCommand().environment(\.locale, model.config.language.locale) }
        }
        Window(UILocalizer(locale: model.config.language.locale).label("快捷面板"), id: "quick-panel") {
            QuickPanelView(prepareToOpenMainWindow: delegate.windowLifecycle.prepareToOpenMainWindow)
                .environmentObject(model).environment(\.locale, model.config.language.locale).onAppear(perform: prepareModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        MenuBarExtra {
            QuickPanelView(prepareToOpenMainWindow: delegate.windowLifecycle.prepareToOpenMainWindow)
                .environmentObject(model).environment(\.locale, model.config.language.locale).onAppear(perform: prepareModel)
        } label: {
            Image(nsImage: AssistantBrand.menuBarIcon).accessibilityLabel(UILocalizer(locale: model.config.language.locale).label("DWS助手"))
                .onAppear(perform: prepareModel)
        }
        .menuBarExtraStyle(.window)
    }
    private func prepareModel() {
        delegate.model = model
        model.applyAppearance()
        model.begin()
    }
    private func renderScreenshot() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let path: String
            if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > i + 1 { path = CommandLine.arguments[i + 1] }
            else { return }
            let view = AssistantView().environmentObject(model).environment(\.locale, model.config.language.locale).frame(width: 1200, height: 800)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AssistantModel?
    let windowLifecycle = AssistantWindowLifecycle()
    private let termination = AssistantTermination()
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.applicationIconImage = AssistantBrand.appIcon }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model?.refreshAccounts() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(hasActiveWork: model?.hasActiveWork == true,
                            stop: { [model] in await model?.stopAll() ?? true },
                            terminate: { sender.terminate(nil) })
    }
    func requestQuit() { NSApplication.shared.terminate(nil) }
}
