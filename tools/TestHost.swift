import Cocoa
import ScreenSaver

/// Standalone window that loads FractalSaver.saver — no System Settings needed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var saverView: ScreenSaverView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saverPath = CommandLine.arguments.dropFirst().first
            ?? (NSHomeDirectory() + "/Library/Screen Savers/FractalSaver.saver")

        guard let bundle = Bundle(path: saverPath), bundle.load() else {
            presentAlert("FractalSaver.saver nicht gefunden:\n\(saverPath)")
            NSApp.terminate(nil)
            return
        }
        guard let cls = bundle.principalClass as? ScreenSaverView.Type else {
            presentAlert("NSPrincipalClass ist keine ScreenSaverView.")
            NSApp.terminate(nil)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        guard let view = cls.init(frame: frame, isPreview: false) else {
            presentAlert("FractalSaverView konnte nicht erzeugt werden.")
            NSApp.terminate(nil)
            return
        }
        view.autoresizingMask = [.width, .height]
        saverView = view

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fractal (Test)"
        window.contentView = NSView(frame: frame)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView?.addSubview(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window

        installMenu()
        NotificationCenter.default.addObserver(
            forName: Notification.Name("de.r8lle.screensaver.fractal.stats"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let fps = note.userInfo?["fps"] as? Double else { return }
            let gpuMs = note.userInfo?["gpuMs"] as? Double ?? 0
            let dropped = note.userInfo?["dropped"] as? Double ?? 0
            var title = String(format: "Fractal (Test) — %.1f fps", fps)
            if gpuMs >= 0.5 {
                title += String(format: " · GPU %.0f ms", gpuMs)
            }
            if dropped >= 0.5 {
                title += String(format: " · −%.0f dropped/s", dropped)
            }
            self?.window.title = title
        }
        view.startAnimation()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Optionen…",
            action: #selector(openOptions),
            keyEquivalent: ","
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Fractal Test beenden",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func openOptions() {
        guard saverView.hasConfigureSheet, let sheet = saverView.configureSheet else { return }
        window.beginSheet(sheet)
    }

    private func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Fractal Test"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
