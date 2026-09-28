import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum ScreenCaptureBackend: String, Equatable, CustomStringConvertible {
    case legacyScreencaptureCLI
    case nativeRegionSelection

    var description: String {
        rawValue
    }
}

struct ScreenCaptureCLIArguments {
    static func selectionArguments(outputURL: URL) -> [String] {
        ["-i", "-s", "-x", "-t", "png", outputURL.path]
    }
}

struct ScreenCaptureStrategy {
    static func preferred(
        for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> ScreenCaptureBackend {
        _ = version
        return .legacyScreencaptureCLI
    }
}

#if canImport(AppKit) && canImport(ScreenCaptureKit)
@MainActor
final class ScreenCaptureService {
    private let selector = ScreenRegionSelector()

    static func activeBackend(
        for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> ScreenCaptureBackend {
        ScreenCaptureStrategy.preferred(for: version)
    }

    func captureSelectionImage() async -> NSImage? {
        switch Self.activeBackend() {
        case .legacyScreencaptureCLI:
            return await captureWithLegacyCLI()
        case .nativeRegionSelection:
            if #available(macOS 15.2, *) {
                return await captureWithNativeRegionSelection()
            }

            return await captureWithLegacyCLI()
        }
    }

    @available(macOS 15.2, *)
    private func captureWithNativeRegionSelection() async -> NSImage? {
        guard let rect = await selector.selectRegion() else {
            return nil
        }

        // Let the overlay disappear before ScreenCaptureKit samples the screen.
        try? await Task.sleep(nanoseconds: 75_000_000)

        do {
            let image = try await captureImage(in: rect)
            return NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        } catch {
            Logger.log(.error, "Native region capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func captureWithLegacyCLI() async -> NSImage? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenscribe-\(UUID().uuidString)")
            .appendingPathExtension("png")

        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ScreenCaptureCLIArguments.selectionArguments(outputURL: outputURL)
            task.terminationHandler = { process in
                DispatchQueue.main.async {
                    defer {
                        try? FileManager.default.removeItem(at: outputURL)
                    }

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let data = try? Data(contentsOf: outputURL) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: NSImage(data: data))
                }
            }

            do {
                try task.run()
            } catch {
                Logger.log(.error, "Legacy screencapture launch failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(returning: nil)
            }
        }
    }

    @available(macOS 15.2, *)
    private func captureImage(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(throwing: ScreenCaptureServiceError.missingImage)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

}

private enum ScreenCaptureServiceError: LocalizedError {
    case missingImage

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "ScreenCaptureKit completed without returning an image."
        }
    }
}

@MainActor
protocol RegionSelectionOverlayWindow: AnyObject {
    func orderOut(_ sender: Any?)
    func prepareForReuse()
    func setFrame(_ frame: CGRect, display: Bool)
}

@MainActor
struct RegionSelectionOverlayTeardown {
    init() {}

    func dismiss(_ window: RegionSelectionOverlayWindow?) {
        window?.orderOut(nil)
        window?.prepareForReuse()
    }
}

@MainActor
struct RegionSelectionOverlayPresenter {
    init() {}

    func prepareWindow<Window: RegionSelectionOverlayWindow>(
        existingWindow: Window?,
        frame: CGRect,
        makeWindow: (CGRect) -> Window
    ) -> Window {
        if let existingWindow {
            existingWindow.setFrame(frame, display: false)
            return existingWindow
        }

        return makeWindow(frame)
    }
}

@MainActor
private final class ScreenRegionSelector {
    private let overlayTeardown = RegionSelectionOverlayTeardown()
    private let overlayPresenter = RegionSelectionOverlayPresenter()
    private var overlayWindow: ScreenRegionSelectionWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func selectRegion() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {
        let desktopFrame = NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { partialResult, frame in
                partialResult = partialResult.union(frame)
            }

        guard !desktopFrame.isNull else {
            finish(with: nil)
            return
        }

        let window = overlayPresenter.prepareWindow(
            existingWindow: overlayWindow,
            frame: desktopFrame,
            makeWindow: ScreenRegionSelectionWindow.init(frame:)
        )
        overlayWindow = window

        let selectionView = ScreenRegionSelectionView(
            frame: CGRect(origin: .zero, size: desktopFrame.size),
            onComplete: { [weak self] rect in
                self?.finish(with: rect)
            },
            onCancel: { [weak self] in
                self?.finish(with: nil)
            }
        )

        window.contentView = selectionView

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(selectionView)
    }

    private func finish(with rect: CGRect?) {
        guard let continuation else {
            return
        }

        self.continuation = nil

        overlayTeardown.dismiss(overlayWindow)
        continuation.resume(returning: rect)
    }
}

private final class ScreenRegionSelectionWindow: NSWindow, RegionSelectionOverlayWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    func prepareForReuse() {
        makeFirstResponder(nil)
    }
}

private final class ScreenRegionSelectionView: NSView {
    private let minimumSelectionSize: CGFloat = 4
    private let onComplete: (CGRect) -> Void
    private let onCancel: () -> Void

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(
        frame: CGRect,
        onComplete: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(event.locationInWindow)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clamped(event.locationInWindow)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint, let window else {
            onCancel()
            return
        }

        currentPoint = clamped(event.locationInWindow)
        let selectionRect = normalizedRect(from: startPoint, to: currentPoint ?? startPoint)

        guard selectionRect.width >= minimumSelectionSize,
              selectionRect.height >= minimumSelectionSize else {
            onCancel()
            return
        }

        onComplete(window.convertToScreen(selectionRect))
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let maskPath = NSBezierPath(rect: bounds)
        if let selectionRect = selectionRect {
            maskPath.appendRect(selectionRect)
            maskPath.windingRule = .evenOdd
        }

        NSColor.black.withAlphaComponent(0.28).setFill()
        maskPath.fill()

        guard let selectionRect else {
            return
        }

        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        selectionRect.fill()

        let borderPath = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        borderPath.stroke()
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else {
            return nil
        }

        return normalizedRect(from: startPoint, to: currentPoint)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func normalizedRect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(startPoint.x - endPoint.x),
            height: abs(startPoint.y - endPoint.y)
        )
    }
}
#endif
