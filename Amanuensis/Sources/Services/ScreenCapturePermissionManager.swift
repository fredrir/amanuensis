import Foundation
import CoreGraphics
import AppKit
import Combine

@MainActor
final class ScreenCapturePermissionManager: ObservableObject {
    static let shared = ScreenCapturePermissionManager()

    @Published private(set) var hasPermission: Bool = false

    private let preflight: () -> Bool
    private let requestAccess: () async -> Bool
    private var permissionCheckTimer: Timer?
    private var isRequesting = false

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestAccess: @escaping () async -> Bool = { CGRequestScreenCaptureAccess() }
    ) {
        self.preflight = preflight
        self.requestAccess = requestAccess
        hasPermission = preflight()
    }

    /// Only preflight is safe to call without a user-initiated access request.
    func startMonitoringWithoutPrompt() async {
        if !checkPermission() {
            startPolling()
        }
    }

    /// Explicitly request access from the app process. Never call this from polling.
    @discardableResult
    func requestPermissionInteractively() async -> Bool {
        guard !isRequesting else { return false }
        if checkPermission() { return true }

        isRequesting = true
        defer { isRequesting = false }
        let granted = await requestAccess()
        Logger.log(.info, "CGRequestScreenCaptureAccess returned \(granted)")
        if granted || checkPermission() {
            hasPermission = true
            stopPolling()
            return true
        }

        startPolling()
        return false
    }

    /// Read the current system status, including permission revoked in Settings.
    func checkPermission() -> Bool {
        hasPermission = preflight()
        if hasPermission {
            stopPolling()
        }
        return hasPermission
    }

    private func startPolling() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.checkPermission()
            }
        }
    }

    func stopPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
