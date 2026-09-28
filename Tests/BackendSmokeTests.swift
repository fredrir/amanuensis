import Foundation

@main
struct BackendSmokeTests {
    @MainActor
    static func main() async {
        do {
            let health = try await BackendProcess.shared.request("health")
            guard health["graniteReady"] as? Bool == true else {
                throw BackendFailure(message: "Bundled Granite is missing")
            }
            let image = try Data(contentsOf: Bundle.main.url(forResource: "capture", withExtension: "png")!)
            let text = try await AIProviderClient().extractContent(
                from: image.base64EncodedString(), format: "text", provider: AIProviderPreset.granite.makeProvider())
            guard text.contains("42") else { throw BackendFailure(message: "Offline extraction failed: \(text)") }
            print("Bundled offline extraction passed: \(text)")
            for kind in [AIProviderKind.codex, .geminiSubscription] {
                let provider = AIProviderConfiguration(name: kind.displayName, kind: kind, baseURL: "")
                _ = try await AIProviderClient().account("status", for: provider)
                print("\(kind.displayName) client started")
            }
            BackendProcess.shared.stop()
            print("BackendSmokeTests passed")
            exit(0)
        } catch {
            BackendProcess.shared.stop()
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
