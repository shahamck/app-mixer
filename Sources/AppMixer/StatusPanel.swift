import AppKit
import SwiftUI

/// Menu bar icon + a borderless, transparent panel that drops down under it.
/// We draw the background ourselves (Liquid Glass), so the window itself must be fully clear.
@MainActor
final class StatusPanelController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: GlassPanel
    private let hosting: NSHostingView<AnyView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// Clear space around the glass for its shadow. The window itself has no shadow: macOS would draw
    /// it around the square window instead of the rounded glass.
    static let shadowMargin: CGFloat = 22
    private let pinned: Bool
    /// Where the panel hangs from: centre x and top edge, set each time it opens.
    private var anchorMidX: CGFloat = 0
    private var anchorTop: CGFloat = 0

    /// - Parameter preview: show the panel immediately in the middle of the screen and keep it open.
    private let model: MixerModel

    init(model: MixerModel, preview: Bool) {
        self.model = model
        pinned = preview
        panel = GlassPanel()
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()

        hosting.rootView = AnyView(
            MixerView()
                .environmentObject(model)
                .fixedSize()
                // Transparent margin so the rounded shadow drawn by MixerView isn't clipped by the window.
                .padding(Self.shadowMargin)
                .background(GeometryReader { Color.clear.preference(key: PanelSizeKey.self, value: $0.size) })
                .onPreferenceChange(PanelSizeKey.self) { [weak self] size in
                    MainActor.assumeIsolated { self?.resize(to: size) }
                }
        )
        hosting.sizingOptions = [] // we size the panel ourselves, keeping it centred under the icon
        panel.contentView = hosting

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dial.medium.fill", accessibilityDescription: "AppMixer")
            button.target = self
            button.action = #selector(toggle)
        }

        if preview {
            showPreviewBackdrop()
            show()
        }
    }

    /// `-previewBackdrop white|black`: a plain window behind the preview panel, for comparing glass styles.
    private var previewBackdrop: NSWindow?
    private func showPreviewBackdrop() {
        guard let name = UserDefaults.standard.string(forKey: "previewBackdrop"),
              let visible = NSScreen.main?.visibleFrame else { return }
        let size = CGSize(width: 520, height: 460)
        let window = NSWindow(contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                                  width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = name == "black" ? NSColor(white: 0.08, alpha: 1) : .white
        window.title = "Backdrop"
        window.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
        window.orderFrontRegardless()
        previewBackdrop = window
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        position(size: panel.frame.size == .zero ? hosting.fittingSize : panel.frame.size)
        panel.makeKeyAndOrderFront(nil)
        if model.showBatteries { model.batteries.refreshSoon() }
        guard !pinned else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { self?.hide() }
                return nil
            }
            return event
        }
    }

    private func hide() {
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// Grow and shrink downwards from the menu bar, like a menu.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if panel.isVisible {
            // Always from the anchor set when the panel opened, so repeated resizes can't drift.
            let top = anchorTop
            let x = anchorMidX - size.width / 2
            panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                           display: true)
        } else {
            panel.setContentSize(size)
        }
    }

    /// A physical distance on this display, in points (falls back to ~110 pt per inch).
    static func points(forMillimetres mm: CGFloat, on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return mm * 110 / 25.4
        }
        let physical = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value)) // millimetres
        guard physical.width > 0 else { return mm * 110 / 25.4 }
        return mm * screen.frame.width / physical.width
    }

    private func position(size: CGSize) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var x = visible.midX - size.width / 2
        // visibleFrame stops at the bottom of the menu bar (taller than the icon on notched Macs).
        var top = visible.maxY - Self.points(forMillimetres: 2, on: screen) + Self.shadowMargin
        // `-previewAtMenuBar YES`: keep the preview open but in its real spot under the icon.
        let atMenuBar = !pinned || UserDefaults.standard.bool(forKey: "previewAtMenuBar")
        if atMenuBar, let button = statusItem.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            x = anchor.midX - size.width / 2
        } else if !atMenuBar {
            top = visible.midY + size.height / 2
        }
        let inset = 8 - Self.shadowMargin
        x = min(max(x, visible.minX + inset), visible.maxX - size.width - inset)
        anchorMidX = x + size.width / 2
        anchorTop = top
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Clear, borderless, non-activating panel: the SwiftUI content paints the glass.
final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // MixerView draws a shadow that follows the rounded glass
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "AppMixer"
    }

    override var canBecomeKey: Bool { true }

    /// macOS pushes windows down so they don't overlap the menu bar. Our window's top edge is invisible
    /// shadow margin, so keep the frame exactly where we put it (the glass itself stays below the bar).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
