import Foundation
import Darwin

struct BackendFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol ExtractionBackend {
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
}

@MainActor
final class BackendProcess: ExtractionBackend {
    static let shared = BackendProcess()
    static let accountChanged = Notification.Name("AmanuensisBackendAccountChanged")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let writer = DispatchQueue(label: "Amanuensis.backend.stdin", qos: .userInitiated)
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    func start() throws {
        if process?.isRunning == true { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Backend", isDirectory: true)
        let root: URL
        let python: URL
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("python/bin/python3").path) {
            root = bundled
            python = bundled.appendingPathComponent("python/bin/python3")
        } else {
            #if DEBUG
            root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("backend", isDirectory: true)
            python = root.appendingPathComponent(".venv/bin/python3")
            #else
            throw BackendFailure(message: "The bundled backend is missing. Reinstall Amanuensis.")
            #endif
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw BackendFailure(message: "The Python backend is missing. Run the backend setup before building.")
        }
        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = python
        task.arguments = ["-s", "-u", "-m", "amanuensis_backend"]
        task.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        let stateRoot = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Amanuensis/backend", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        environment["AMANUENSIS_STATE_ROOT"] = stateRoot.path
        environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        environment["AMANUENSIS_BACKEND_ROOT"] = root.path
        if root == bundled, let granite = GraniteInstaller.shared.location {
            environment["AMANUENSIS_GRANITE_ROOT"] = granite.path
        }
        environment["PYTHONPATH"] = root.appendingPathComponent("src").path + ":" + root.appendingPathComponent("site-packages").path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        task.environment = environment
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.standardError
        let generation = UUID()
        self.generation = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard self?.generation == generation else { return }
                if !data.isEmpty { self?.receive(data) }
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.failPending("The extraction backend stopped. Try again.")
                self?.output?.readabilityHandler = nil
                self?.process = nil
                self?.input = nil
                self?.output = nil
                self?.buffer.removeAll()
            }
        }
        do {
            try task.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw BackendFailure(message: "The extraction backend could not start.")
        }
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private var generation = UUID()

    func stop() {
        generation = UUID()
        failPending("The extraction backend stopped.")
        output?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
            // A native inference call may not respond to cancellation immediately.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    /// Restarts so the backend picks up an installed or removed Granite pack.
    func restart() {
        stop()
        try? start()
    }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        try start()
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(0x0A)
        let response: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.failPending("The extraction backend timed out. Try again.")
                    self.stop()
                }
                guard let handle = input else {
                    complete(id, result: .failure(BackendFailure(message: "Cannot reach the extraction backend.")))
                    return
                }
                let requestData = data
                writer.async { [weak self] in
                    do { try handle.write(contentsOf: requestData) }
                    catch {
                        Task { @MainActor in
                            self?.complete(id, result: .failure(BackendFailure(message: "Cannot reach the extraction backend.")))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(id, result: .failure(CancellationError()))
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw BackendFailure(message: "Invalid backend response.")
        }
        return result
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else {
            stop()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if message["event"] as? String == "accountChanged" {
                NotificationCenter.default.post(name: Self.accountChanged, object: nil, userInfo: message["params"] as? [String: Any])
            }
            guard let id = message["id"] as? String else { continue }
            if let error = message["error"] as? [String: String] {
                complete(id, result: .failure(BackendFailure(message: error["message"] ?? "Extraction failed.")))
            } else if let result = message["result"] as? [String: Any] {
                complete(id, result: .success((try? JSONSerialization.data(withJSONObject: result)) ?? Data()))
            } else {
                complete(id, result: .failure(BackendFailure(message: "Invalid backend response.")))
            }
        }
    }

    private func complete(_ id: String, result: Result<Data, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(_ message: String) {
        for id in Array(pending.keys) {
            complete(id, result: .failure(BackendFailure(message: message)))
        }
    }
}

@MainActor
struct AIProviderClient {
    let backend: any ExtractionBackend
    init(backend: (any ExtractionBackend)? = nil) { self.backend = backend ?? BackendProcess.shared }

    private func configuration(_ provider: AIProviderConfiguration) -> [String: Any] {
        ["kind": provider.kind.rawValue, "baseURL": provider.resolvedBaseURL,
         "apiKey": provider.effectiveAPIKey, "model": provider.resolvedModel]
    }

    func extractContent(from base64Image: String, format: String, provider: AIProviderConfiguration) async throws -> String {
        let result = try await backend.request("extract", params: [
            "image": base64Image, "format": format, "provider": configuration(provider),
        ])
        guard let text = result["text"] as? String else { throw BackendFailure(message: "Invalid extraction response.") }
        return text
    }

    func availableModels(for provider: AIProviderConfiguration) async throws -> [String] {
        let result = try await backend.request("models", params: ["provider": configuration(provider)])
        guard let models = result["models"] as? [String] else { throw BackendFailure(message: "Invalid model list.") }
        return models
    }

    func account(_ action: String, for provider: AIProviderConfiguration) async throws -> [String: Any] {
        try await backend.request("account/\(action)", params: ["kind": provider.kind.rawValue])
    }
}
