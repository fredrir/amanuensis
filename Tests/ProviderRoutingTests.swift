import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@MainActor
private final class RecordingBackend: ExtractionBackend {
    var calls: [(String, [String: Any])] = []
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        return method == "extract" ? ["text": "  backend output  "] : ["models": ["vision-model"]]
    }
}

@main
struct ProviderRoutingTests {
    @MainActor
    static func main() async throws {
        let backend = RecordingBackend()
        let client = AIProviderClient(backend: backend)
        for preset in AIProviderPreset.all {
            var provider = preset.makeProvider()
            provider.model = "vision-model"
            provider.apiKey = "test-key"
            let result = try await client.extractContent(from: "image", format: "latex", provider: provider)
            expect(result == "  backend output  ", "Swift must preserve the backend's formatted output")
            let call = backend.calls.last!
            expect(call.0 == "extract", "Every provider should use backend extraction")
            expect(call.1["format"] as? String == "latex", "The backend should receive the requested format")
            expect(call.1["prompt"] == nil, "Swift should not own extraction prompts")
            let config = call.1["provider"] as! [String: Any]
            expect(config["kind"] as? String == provider.kind.rawValue, "The backend should receive the chosen provider")
            let models = try await client.availableModels(for: provider)
            expect(models == ["vision-model"], "Model discovery should use the backend")
        }
        let granite = AIProviderPreset.granite.makeProvider()
        expect(!granite.requiresAPIKey && !granite.model.isEmpty, "Granite should work without setup")
        for kind in [AIProviderKind.codex, .geminiSubscription] {
            let provider = AIProviderConfiguration(name: "Subscription", kind: kind, baseURL: "")
            expect(provider.isSubscription && !provider.requiresAPIKey, "Subscription providers should use sign-in")
        }
        print("ProviderRoutingTests passed")
    }

}
