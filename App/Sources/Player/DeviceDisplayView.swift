import AppKit
import SwiftUI

/// Shows the device screen and turns mouse, trackpad and keyboard input into device input.
struct DeviceDisplay: NSViewRepresentable {
    let session: PlayerSession
    var onDropAPK: (URL) -> Void

    func makeNSView(context _: Context) -> DeviceDisplayNSView {
        let view = DeviceDisplayNSView()
        view.session = session
        view.onDropAPK = onDropAPK
        return view
    }

    func updateNSView(_ view: DeviceDisplayNSView, context _: Context) {
        view.session = session
        view.onDropAPK = onDropAPK
        view.show(session.image)
    }
}

final class DeviceDisplayNSView: NSView {
    weak var session: PlayerSession?
    var onDropAPK: ((URL) -> Void)?
    private var frameSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Android device screen")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func show(_ image: CGImage?) {
        guard let image else { return }
        frameSize = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no cross-fade between frames
        layer?.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            guard let self else { return }
            session?.viewPixelSizeChanged(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }

    // MARK: Coordinate mapping

    /// Where the aspect-fitted frame is drawn inside the view.
    var contentRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        return Self.aspectFit(frameSize, in: bounds)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// View point (AppKit, origin bottom-left) → device pixels (origin top-left), or nil outside the screen.
    func devicePoint(for event: NSEvent) -> CGPoint? {
        guard let session else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return Self.devicePoint(p, content: contentRect, deviceSize: displayedDeviceSize(session.deviceSize))
    }

    /// The device size in the orientation currently displayed (frames rotate with the device).
    private func displayedDeviceSize(_ portrait: CGSize) -> CGSize {
        let landscapeFrame = frameSize.width > frameSize.height
        let landscapeDevice = portrait.width > portrait.height
        return landscapeFrame == landscapeDevice ? portrait : CGSize(width: portrait.height, height: portrait.width)
    }

    static func devicePoint(_ p: CGPoint, content: CGRect, deviceSize: CGSize) -> CGPoint? {
        guard content.contains(p), content.width > 0, content.height > 0 else { return nil }
        let x = (p.x - content.minX) / content.width * deviceSize.width
        let y = (content.maxY - p.y) / content.height * deviceSize.height
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    // MARK: Mouse → touch

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let p = devicePoint(for: event) {
            session?.mouse(at: p, pressed: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let p = devicePoint(for: event) {
            session?.mouse(at: p, pressed: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = devicePoint(for: event) ?? .zero
        session?.mouse(at: p, pressed: false)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Int((event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10).rounded())
        let dx = Int((event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10).rounded())
        if dx != 0 || dy != 0 {
            session?.scroll(dx: dx, dy: dy)
        }
    }

    // MARK: Keyboard

    /// macOS key codes → W3C `KeyboardEvent.key` names the emulator understands.
    static let specialKeys: [UInt16: String] = [
        36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "GoBack",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]

    override func keyDown(with event: NSEvent) {
        // Leave ⌘-shortcuts to the menu bar.
        if event.modifierFlags.contains(.command) {
            return super.keyDown(with: event)
        }
        if let name = Self.specialKeys[event.keyCode] {
            session?.key(name)
        } else if let text = event.characters, !text.isEmpty {
            session?.type(text)
        }
    }

    // MARK: Drag and drop APKs

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        apkURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = apkURL(from: sender) else { return false }
        onDropAPK?(url)
        return true
    }

    private func apkURL(from info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "apk" }
    }
}
