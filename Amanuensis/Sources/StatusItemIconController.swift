import AppKit
import QuartzCore

/// Drives the menu-bar status item icon: idle quill, spinning during an
/// extraction, and transient success/failure feedback.
@MainActor
final class StatusItemIconController {
    /// Point size for the transient SF Symbol feedback icons.
    private static let symbolPointSize: Double = 16
    private static let spinAnimationKey = "com.amanuensis.status-item.spin"
    private static let spinDuration: CFTimeInterval = 1.0

    private let button: NSStatusBarButton
    private let idleImage: NSImage?
    private var resetTask: Task<Void, Never>?

    private(set) var state: StatusItemIconState = .idle

    init(button: NSStatusBarButton, idleImage: NSImage?) {
        self.button = button
        self.idleImage = idleImage
        button.wantsLayer = true
    }

    /// Move the icon into `newState`, cancelling any pending feedback reset.
    func apply(_ newState: StatusItemIconState) {
        resetTask?.cancel()
        resetTask = nil
        state = newState

        updateImage(for: newState)
        updateSpin(for: newState)
        scheduleResetIfNeeded(for: newState)
    }

    private func updateImage(for state: StatusItemIconState) {
        if let symbolName = state.symbolName {
            let image = NSImage.with(
                symbolName: symbolName,
                pointSize: Self.symbolPointSize,
                accessibilityLabel: state.accessibilityLabel
            )
            image.isTemplate = true
            button.image = image
        } else {
            button.image = idleImage
        }
        button.setAccessibilityLabel(state.accessibilityLabel)
    }

    private func updateSpin(for state: StatusItemIconState) {
        if state.isSpinning {
            startSpin()
        } else {
            stopSpin()
        }
    }

    private func startSpin() {
        guard button.layer?.animation(forKey: Self.spinAnimationKey) == nil else { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = Self.spinDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        button.layer?.add(spin, forKey: Self.spinAnimationKey)
    }

    private func stopSpin() {
        button.layer?.removeAnimation(forKey: Self.spinAnimationKey)
    }

    private func scheduleResetIfNeeded(for state: StatusItemIconState) {
        guard let duration = state.feedbackDuration else { return }

        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.apply(.idle)
        }
    }
}
