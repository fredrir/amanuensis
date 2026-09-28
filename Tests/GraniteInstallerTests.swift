import CryptoKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func makeArchive(id: String, manifestID: String, in directory: URL) throws -> URL {
    let files = FileManager.default
    let source = directory.appendingPathComponent("source-\(UUID().uuidString)/\(id)", isDirectory: true)
    try files.createDirectory(at: source.appendingPathComponent("models"), withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: source.appendingPathComponent("models/model.safetensors"))
    try Data(#"{"id": "\#(manifestID)", "python": "3.12"}"#.utf8).write(to: source.appendingPathComponent("granite.json"))
    let archive = directory.appendingPathComponent("\(UUID().uuidString).zip")
    let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", source.path, archive.path])
    ditto.waitUntilExit()
    expect(ditto.terminationStatus == 0, "ditto should create the test archive")
    return archive
}

private func pack(id: String, archive: URL) throws -> GranitePack {
    let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    return GranitePack(id: id, url: archive, sha256: digest, size: 1, installedSize: 1)
}

private func installFails(archive: URL, pack: GranitePack, root: URL) async -> Bool {
    do {
        try await GraniteInstaller.install(archive: archive, pack: pack, root: root)
        return false
    } catch {
        return true
    }
}

@main
struct GraniteInstallerTests {
    @MainActor
    static func main() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("granite-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root", isDirectory: true)
        let previous = root.appendingPathComponent("previous-pack", isDirectory: true)
        try files.createDirectory(at: previous, withIntermediateDirectories: true)

        let corrupted = try makeArchive(id: "abc", manifestID: "abc", in: directory)
        let wrongDigest = GranitePack(id: "abc", url: corrupted, sha256: String(repeating: "0", count: 64), size: 1, installedSize: 1)
        let rejectedCorrupted = await installFails(archive: corrupted, pack: wrongDigest, root: root)
        expect(rejectedCorrupted, "A checksum mismatch must be rejected")
        expect(!exists(corrupted), "A rejected download should be deleted")
        expect(exists(previous), "A rejected download must not touch the installed pack")

        let mismatched = try makeArchive(id: "abc", manifestID: "other", in: directory)
        let rejectedMismatch = await installFails(archive: mismatched, pack: try pack(id: "abc", archive: mismatched), root: root)
        expect(rejectedMismatch, "A pack built for another version must be rejected")
        expect(exists(previous), "A mismatched pack must not touch the installed pack")

        let archive = try makeArchive(id: "abc", manifestID: "abc", in: directory)
        let valid = try pack(id: "abc", archive: archive)
        try await GraniteInstaller.install(archive: archive, pack: valid, root: root)
        let installed = try files.contentsOfDirectory(atPath: root.path)
        expect(installed == ["abc"], "Only the new pack should remain installed, found \(installed)")
        expect(exists(root.appendingPathComponent("abc/models/model.safetensors")), "The pack contents should be unpacked")
        expect(!exists(archive), "The downloaded archive should be deleted after installing")

        expect(GraniteInstaller(pack: valid, root: root).state == .installed, "An unpacked pack should be detected")
        expect(GraniteInstaller(pack: valid, root: directory).state == .notInstalled, "A missing pack should be offered")
        expect(GraniteInstaller(pack: nil, root: root).state == .unavailable, "Builds without a pack cannot download one")
        print("GraniteInstallerTests passed")
    }
}
