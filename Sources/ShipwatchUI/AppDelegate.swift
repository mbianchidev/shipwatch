import AppKit
import ShipwatchCore
import ShipwatchUpdate

/// Wires the model, the menu bar item and the Settings window together.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var settings: SettingsWindowController?

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The copy the update helper relaunches must start even if the old process is still listed as running.
        if !AppBundleStartupRequest.isRequested(in: ProcessInfo.processInfo.environment),
           let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            uiLog.notice("Shipwatch is already running, quitting this copy")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        let model = AppModel(prefs: Preferences())
        let statusItem = StatusItemController(model: model)
        let settings = SettingsWindowController(model: model)

        var actions = AppActions()
        actions.openURL = { [weak statusItem] url in
            statusItem?.closePopover()
            NSWorkspace.shared.open(url)
        }
        actions.showSettings = { [weak statusItem, weak settings] tab in
            statusItem?.closePopover()
            settings?.show(tab)
        }
        actions.showPopover = { [weak statusItem] in statusItem?.showPopover() }
        model.actions = actions

        self.model = model
        self.statusItem = statusItem
        self.settings = settings

        model.updater.confirmUpdateStartup()
        model.configureLoginItemDefault()
        model.start()
        model.updater.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        model?.actions.showSettings(model?.settingsTab ?? .repositories)
    }

    @objc func refreshNow(_ sender: Any?) {
        model?.requestRefresh(force: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        model?.checkForUpdates()
    }

    /// A minimal main menu so standard shortcuts (copy, paste, close) work while Settings is open.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Shipwatch")
        appMenu.addItem(withTitle: "About Shipwatch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Refresh", action: #selector(refreshNow(_:)), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shipwatch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Shipwatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
