// The app a user opens once after installing. Opening it registers the extensions,
// since Homebrew casks can no longer do that during install, and it shows what Quick
// Look will use on this Mac, which is otherwise hard to find out.
import AppKit
import UniformTypeIdentifiers

private func pluginkit(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// macOS runs a quarantined app that hasn't been moved from a temporary read-only
// path, and extensions registered from there stop working when that path goes away.
private var isTranslocated: Bool {
    Bundle.main.bundlePath.contains("/AppTranslocation/")
}

private func registerExtensions() {
    guard !isTranslocated, let plugIns = Bundle.main.builtInPlugInsURL,
          let found = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
    else { return }
    for appex in found where appex.pathExtension == "appex" {
        _ = pluginkit(["-a", appex.path])
    }
}

private func statusText() -> String {
    if isTranslocated {
        return "⚠ Drag this app into your Applications folder in Finder, then open it again. Its Quick Look extensions can't be set up from where macOS is running it now."
    }
    let registered = pluginkit(["-mAv"])
    let ours = registered.contains("com.faeton.insta360quicklook")
    let studio = registered.contains("com.insta360.studio.QuickLookHost")
    let dji = registered.contains("DJIStudioQuickLookHost")

    var lines: [String] = []
    lines.append(ours ? "✓ Quick Look extensions are registered." : "✗ Quick Look extensions aren't registered yet.")
    lines.append("")
    if studio {
        lines.append("Insta360 Studio's plugin is also installed. It keeps the Space preview for Insta360 files, and thumbnails may come from either plugin.")
    } else {
        lines.append("Insta360 Studio's plugin isn't installed, so this app handles Insta360 files.")
    }
    if dji { lines.append("DJI Studio's plugin is also installed, so DJI previews may come from either plugin.") }
    lines.append("")

    let custom = ["insv", "insp", "lrv"].filter { UTType(filenameExtension: $0)?.isDynamic == false }
    if custom.isEmpty {
        lines.append("✓ No other app has claimed the Insta360 file types.")
    } else {
        let names = custom.map { ".\($0)" }.joined(separator: ", ")
        lines.append("⚠ Another app has claimed \(names). That can stop plugins from working. Older versions of this app did this, so remove any old copies.")
    }
    return lines.joined(separator: "\n")
}

@main
final class HostApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var label: NSTextField?

    static func main() {
        let app = NSApplication.shared
        let delegate = HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Insta360 QuickLook"
        window.center()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSTextField(labelWithString: "Insta360 QuickLook \(version)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let label = NSTextField(wrappingLabelWithString: "Checking…")
        label.preferredMaxLayoutWidth = 420
        self.label = label

        let settings = NSButton(title: "Open Extension Settings…", target: self, action: #selector(openSettings))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshStatus))
        let quit = NSButton(title: "Done", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.keyEquivalent = "\r"
        let buttons = NSStackView(views: [settings, refresh, quit])

        let stack = NSStackView(views: [title, label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        DispatchQueue.global().async {
            registerExtensions()
            let text = statusText()
            DispatchQueue.main.async { label.stringValue = text }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }

    @objc private func refreshStatus() {
        guard let label else { return }
        DispatchQueue.global().async {
            let text = statusText()
            DispatchQueue.main.async { label.stringValue = text }
        }
    }
}
