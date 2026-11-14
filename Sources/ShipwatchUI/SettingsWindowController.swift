import AppKit
import SwiftUI

/// Hosts `SettingsView` in a dark, fixed-width window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(_ tab: SettingsTab) {
        model.settingsTab = tab
        if window == nil {
            window = makeWindow()
            observeTab()
        }
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.17, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// Keeps the window title in sync with the selected tab, like System Settings panes.
    private func observeTab() {
        withObservationTracking {
            window?.title = model.settingsTab.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTab() }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.isAddingRepositories = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
