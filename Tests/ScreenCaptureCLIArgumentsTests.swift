import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ScreenCaptureCLIArgumentsTests {
    static func main() {
        let outputURL = URL(fileURLWithPath: "/tmp/amanuensis-capture.png")
        let arguments = ScreenCaptureCLIArguments.selectionArguments(outputURL: outputURL)

        expect(arguments.contains("-i"), "interactive capture should stay enabled")
        expect(arguments.contains("-s"), "legacy capture should force rectangle selection mode")
        expect(arguments.contains("-x"), "legacy capture should stay silent")
        expect(arguments.contains("-t"), "legacy capture should force a stable file format")
        expect(arguments.contains("png"), "legacy capture should save PNG output")
        expect(!arguments.contains("-c"), "legacy capture should not route through the global clipboard")
        expect(arguments.last == outputURL.path, "legacy capture should write to the requested output file")

        print("ScreenCaptureCLIArgumentsTests passed")
    }
}
