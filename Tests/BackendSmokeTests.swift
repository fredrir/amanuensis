import Foundation

@main
struct BackendSmokeTests {
    @MainActor
    static func main() async {
        do {
            guard let pack = GranitePack.bundled, let root = GranitePack.installRoot else {
                throw BackendFailure(message: "The smoke app has no Granite pack manifest")
            }
            try? FileManager.default.removeItem(at: root)
            let missing = try await BackendProcess.shared.request("health")
            guard missing["graniteReady"] as? Bool == false else {
                throw BackendFailure(message: "Granite should not ship inside the app bundle")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await GraniteInstaller.install(archive: pack.url, pack: pack, root: root)
            BackendProcess.shared.restart()
            let health = try await BackendProcess.shared.request("health")
            guard health["graniteReady"] as? Bool == true else {
                throw BackendFailure(message: "The installed Granite pack was not detected")
            }
            let image = try Data(contentsOf: Bundle.main.url(forResource: "capture", withExtension: "png")!)
            let text = try await AIProviderClient().extractContent(
                from: image.base64EncodedString(), format: "text", provider: AIProviderPreset.granite.makeProvider())
            guard text.contains("42") else { throw BackendFailure(message: "Offline extraction failed: \(text)") }
            print("Installed Granite offline extraction passed: \(text)")
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
