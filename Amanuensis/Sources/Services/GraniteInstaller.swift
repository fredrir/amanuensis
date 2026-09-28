import CryptoKit
import Foundation

/// The Granite pack published for this build, read from `Backend/granite-pack.json`.
struct GranitePack: Decodable, Equatable {
    let id: String
    let url: URL
    let sha256: String
    let size: Int64
    let installedSize: Int64

    static let bundled: GranitePack? = Bundle.main.resourceURL
        .flatMap { try? Data(contentsOf: $0.appendingPathComponent("Backend/granite-pack.json")) }
        .flatMap { try? JSONDecoder().decode(GranitePack.self, from: $0) }

    static let installRoot: URL? = try? FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("Amanuensis/granite", isDirectory: true)
}

@MainActor
final class GraniteInstaller: ObservableObject {
    enum State: Equatable {
        case unavailable
        case notInstalled
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    static let shared = GraniteInstaller(pack: .bundled, root: GranitePack.installRoot)

    @Published private(set) var state: State
    let pack: GranitePack?
    private let root: URL?
    private var task: Task<Void, Never>?
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    init(pack: GranitePack?, root: URL?) {
        self.pack = pack
        self.root = root
        if let pack, let root {
            let manifest = root.appendingPathComponent(pack.id).appendingPathComponent("granite.json")
            state = FileManager.default.fileExists(atPath: manifest.path) ? .installed : .notInstalled
        } else {
            state = .unavailable
        }
    }

    var location: URL? {
        guard let pack, let root else { return nil }
        return root.appendingPathComponent(pack.id, isDirectory: true)
    }

    var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: pack?.size ?? 0, countStyle: .file)
    }

    func install() {
        guard let pack, let root, task == nil else { return }
        switch state {
        case .notInstalled, .failed: break
        default: return
        }
        state = .downloading(0)
        task = Task {
            defer {
                task = nil
                download = nil
                progressObservation = nil
            }
            do {
                try Self.prepare(root, for: pack)
                let archive = try await fetch(pack, into: root)
                state = .installing
                try await Self.install(archive: archive, pack: pack, root: root)
                state = .installed
                BackendProcess.shared.restart()
            } catch {
                state = Task.isCancelled || (error as? URLError)?.code == .cancelled
                    ? .notInstalled : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        download?.cancel()
        task?.cancel()
    }

    func remove() {
        guard state == .installed, let location else { return }
        do {
            try FileManager.default.removeItem(at: location)
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
        BackendProcess.shared.restart()
    }

    private func fetch(_ pack: GranitePack, into root: URL) async throws -> URL {
        let destination = root.appendingPathComponent(".download-\(pack.id).zip")
        return try await withCheckedThrowingContinuation { continuation in
            let download = URLSession.shared.downloadTask(with: pack.url) { location, response, error in
                do {
                    if let error { throw error }
                    guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw BackendFailure(message: "The Granite download is unavailable. Try again later.")
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard case .downloading = self?.state else { return }
                    self?.state = .downloading(fraction)
                }
            }
            self.download = download
            download.resume()
        }
    }

    nonisolated private static func prepare(_ root: URL, for pack: GranitePack) throws {
        var root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? .max
        let required = pack.size + pack.installedSize
        guard available >= required else {
            let size = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            throw BackendFailure(message: "Docling Granite needs \(size) of free disk space.")
        }
    }

    /// Verifies and unpacks a downloaded archive, replacing any other installed pack.
    nonisolated static func install(archive: URL, pack: GranitePack, root: URL) async throws {
        let files = FileManager.default
        defer { try? files.removeItem(at: archive) }
        guard try sha256(of: archive) == pack.sha256.lowercased() else {
            throw BackendFailure(message: "The Granite download is corrupted. Try again.")
        }
        try Task.checkCancellation()
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try await unzip(archive, to: staging)
        let extracted = staging.appendingPathComponent(pack.id, isDirectory: true)
        let manifest = try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: extracted.appendingPathComponent("granite.json")))
        guard manifest?["id"] == pack.id else {
            throw BackendFailure(message: "The Granite download does not match this version of Amanuensis.")
        }
        try Task.checkCancellation()
        for existing in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where existing.lastPathComponent != staging.lastPathComponent
            && existing.lastPathComponent != archive.lastPathComponent
        {
            try files.removeItem(at: existing)
        }
        try files.moveItem(at: extracted, to: root.appendingPathComponent(pack.id, isDirectory: true))
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func unzip(_ archive: URL, to destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BackendFailure(message: "The Granite download could not be unpacked."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
