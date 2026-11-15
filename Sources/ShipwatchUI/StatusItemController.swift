import AppKit
import ShipwatchCore
import SwiftUI

/// The menu bar icon and its popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let dot = NSView()
    private var frameObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
        super.init()
        configureButton()
        configurePopover()
        observeModel()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Sailboat.templateImage()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.borderWidth = 1
        dot.isHidden = true
        button.addSubview(dot)
        button.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: button, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutDot() }
        }
        statusItem.isVisible = true
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    /// Re-applies the icon state whenever anything it reads changes.
    private func observeModel() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let overall = model.overall
        let signedOut = model.authMethod == nil
        let offline: Bool = if case .offline = model.banner { true } else { false }
        button.appearsDisabled = signedOut || offline

        // Only a running or queued workflow gets the dot; failures show in the list and the optional count.
        dot.isHidden = overall.running + overall.queued == 0 || signedOut
        dot.layer?.backgroundColor = Theme.runningNS.cgColor
        dot.layer?.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor

        let count = switch model.prefs.menuBarCount {
        case .running: overall.running
        case .failing: overall.failing
        case .none: 0
        }
        button.title = count > 0 && !signedOut ? " \(count)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = tooltip(overall: overall, signedOut: signedOut)
        layoutDot()
    }

    private func tooltip(overall: OverallStatus, signedOut: Bool) -> String {
        if signedOut { return "Shipwatch · not signed in" }
        var parts: [String] = []
        if overall.running > 0 { parts.append("\(overall.running) running") }
        if overall.queued > 0 { parts.append("\(overall.queued) queued") }
        if overall.failing > 0 { parts.append("\(overall.failing) failing") }
        if overall.notStarted > 0 { parts.append("\(overall.notStarted) config/billing") }
        if overall.passing > 0 { parts.append("\(overall.passing) passing") }
        return parts.isEmpty ? "Shipwatch" : "Shipwatch · " + parts.joined(separator: ", ")
    }

    /// Pins the dot to the top-right corner of the sailboat.
    private func layoutDot() {
        guard let button = statusItem.button, let cell = button.cell else { return }
        let image = cell.imageRect(forBounds: button.bounds)
        let side: CGFloat = 7
        let y = button.isFlipped ? image.minY - 1 : image.maxY - side + 1
        dot.frame = NSRect(x: image.maxX - side + 2, y: y, width: side, height: side)
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shipwatch", action: #selector(quit), keyEquivalent: "q").target = self
        // Attach the menu only for this click so a left click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() { model.requestRefresh(force: true) }
    @objc private func openSettings() { model.actions.showSettings(.general) }
    @objc private func checkForUpdates() { model.checkForUpdates() }
    @objc private func quit() { model.actions.quit() }

    // MARK: NSPopoverDelegate

    nonisolated func popoverWillShow(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusItem.button?.highlight(true)
            model.popoverDidOpen()
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusItem.button?.highlight(false)
            model.popoverDidClose()
        }
    }
}
