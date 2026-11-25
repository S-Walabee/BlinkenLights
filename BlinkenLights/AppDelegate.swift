import AppKit
import SwiftUI

/// Borderless, movable panel with no title bar.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Present on every Space (including full-screen apps) and stay put during Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI's hosting view swallows right-clicks instead of showing `menu`,
/// so pop the context menu up explicitly.
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override func rightMouseDown(with event: NSEvent) {
        showMenu(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(event)
        } else {
            // SwiftUI consumes mouse-downs, so isMovableByWindowBackground never
            // kicks in; drag the window ourselves (nothing in the panel is clickable).
            window?.performDrag(with: event)
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    private func showMenu(_ event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }

    private let settings = AppSettings.shared
    private let monitor = VolumeMonitor()
    private var panel: FloatingPanel!
    private let menu = NSMenu()

    private static let originKey = "panelTopLeft"

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyFirstRunDefaults()

        panel = FloatingPanel()
        panel.delegate = self
        let root = ContentView(monitor: monitor, settings: settings) { [weak self] size in
            self?.fitPanel(to: size)
        }
        let hosting = MenuHostingView(rootView: root)
        hosting.sizingOptions = []
        menu.delegate = self
        hosting.menu = menu
        panel.contentView = hosting

        applyAlwaysVisible()
        restorePosition()
        panel.orderFrontRegardless()

        monitor.start(interval: settings.updateInterval)
    }

    // MARK: Window sizing & position

    /// Resizes the panel to fit its content, keeping the top-left corner fixed.
    private func fitPanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        var newFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        // Keep the whole panel on its screen when it grows (e.g. switching to horizontal).
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if newFrame.maxX > visible.maxX { newFrame.origin.x = max(visible.minX, visible.maxX - newFrame.width) }
            if newFrame.minY < visible.minY { newFrame.origin.y = min(visible.maxY - newFrame.height, visible.minY) }
        }
        if newFrame != frame { panel.setFrame(newFrame, display: true) }
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        var topLeft: NSPoint
        if let saved = defaults.string(forKey: Self.originKey) {
            topLeft = NSPointFromString(saved)
        } else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            topLeft = NSPoint(x: visible.maxX - 200, y: visible.maxY - 20)
        }
        // Make sure the panel lands on a connected screen.
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(topLeft) }),
           let visible = NSScreen.main?.visibleFrame {
            topLeft = NSPoint(x: visible.maxX - 200, y: visible.maxY - 20)
        }
        panel.setFrameTopLeftPoint(topLeft)
    }

    func windowDidMove(_ notification: Notification) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.originKey)
    }

    private func applyAlwaysVisible() {
        panel.level = settings.alwaysVisible ? .floating : .normal
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let vertical = item("Vertical", #selector(setVertical))
        vertical.state = settings.isVertical ? .on : .off
        menu.addItem(vertical)
        let horizontal = item("Horizontal", #selector(setHorizontal))
        horizontal.state = settings.isVertical ? .off : .on
        menu.addItem(horizontal)

        menu.addItem(.separator())

        let always = item("Always Visible", #selector(toggleAlwaysVisible))
        always.state = settings.alwaysVisible ? .on : .off
        menu.addItem(always)

        let freeSpace = item("Show Free Space", #selector(toggleShowFreeSpace))
        freeSpace.state = settings.showFreeSpace ? .on : .off
        menu.addItem(freeSpace)

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Background Opacity", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sliderItem = NSMenuItem()
        sliderItem.view = makeOpacitySlider()
        menu.addItem(sliderItem)

        let speed = NSMenuItem(title: "Update Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for interval in AppSettings.intervals {
            let title = interval < 1 ? "\(Int((interval * 1000).rounded())) ms" : String(format: "%g s", interval)
            let option = item(title, #selector(setInterval(_:)))
            option.representedObject = interval
            option.state = abs(settings.updateInterval - interval) < 0.001 ? .on : .off
            speedMenu.addItem(option)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit BlinkenLights", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeOpacitySlider() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        let slider = NSSlider(value: settings.backgroundOpacity, minValue: 0, maxValue: 1,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 20, y: 3, width: 165, height: 20)
        container.addSubview(slider)
        return container
    }

    @objc private func setVertical() { settings.isVertical = true }
    @objc private func setHorizontal() { settings.isVertical = false }

    @objc private func toggleAlwaysVisible() {
        settings.alwaysVisible.toggle()
        applyAlwaysVisible()
    }

    @objc private func toggleShowFreeSpace() { settings.showFreeSpace.toggle() }

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.backgroundOpacity = sender.doubleValue
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        settings.updateInterval = interval
        monitor.setInterval(interval)
    }

    @objc private func toggleLaunchAtLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
