import Foundation

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        fatalError(message)
    }
}

@main
struct ScreenCapturePermissionManagerTests {
    @MainActor
    static func main() async {
        var allowed = false
        var requests = 0
        let manager = ScreenCapturePermissionManager(
            preflight: { allowed },
            requestAccess: {
                requests += 1
                return false
            }
        )

        await manager.startMonitoringWithoutPrompt()
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        expect(requests == 0, "Startup and polling must not request screen access")
        expect(!manager.hasPermission, "Missing permission must remain denied")

        let denied = await manager.requestPermissionInteractively()
        expect(!denied, "A denied request must report failure")
        expect(requests == 1, "A denial must not cause automatic retries")

        allowed = true
        expect(manager.checkPermission(), "Settings grants must be detected")
        let alreadyGranted = await manager.requestPermissionInteractively()
        expect(alreadyGranted && requests == 1, "Existing permission must not trigger a request")

        allowed = false
        expect(!manager.checkPermission(), "Revoked permission must clear cached granted state")
        expect(!manager.hasPermission, "Published state must reflect revocation")
        manager.stopPolling()

        let successful = ScreenCapturePermissionManager(
            preflight: { false },
            requestAccess: { true }
        )
        let granted = await successful.requestPermissionInteractively()
        expect(granted && successful.hasPermission, "A successful system permission request must allow capture")
        successful.stopPolling()

        var finishRequest: CheckedContinuation<Void, Never>?
        var concurrentRequests = 0
        let concurrent = ScreenCapturePermissionManager(
            preflight: { false },
            requestAccess: {
                concurrentRequests += 1
                await withCheckedContinuation { finishRequest = $0 }
                return true
            }
        )
        let first = Task { await concurrent.requestPermissionInteractively() }
        while finishRequest == nil { await Task.yield() }
        let duplicate = await concurrent.requestPermissionInteractively()
        expect(!duplicate && concurrentRequests == 1, "Overlapping requests must not trigger another prompt")
        finishRequest?.resume()
        let firstGranted = await first.value
        expect(firstGranted, "Original request must complete normally")
        concurrent.stopPolling()

        print("ScreenCapturePermissionManagerTests passed")
    }
}
