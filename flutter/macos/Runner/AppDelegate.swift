import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
    private var statusItem: NSStatusItem?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      dummy_method_to_enforce_bundling()
    // https://github.com/leanflutter/window_manager/issues/214
    return false
  }
    
    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if (launched) {
            handle_applicationShouldOpenUntitledFile();
        }
        return true
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true;
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NSApplication.shared.activate(ignoringOtherApps: true);
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard notification.object is MainFlutterWindow else {
            return
        }
        NSApplication.shared.deactivate()
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSApplication.shared.applicationIconImage.copy() as? NSImage
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "LinkDesk"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "前往主界面", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        guard let window = NSApplication.shared.windows.first(where: { $0 is MainFlutterWindow }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
