import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct StatusItemIconStateTests {
    static func main() {
        expect(StatusItemIconState.idle.symbolName == nil, "idle should use the quill asset")
        expect(!StatusItemIconState.idle.isSpinning, "idle should not spin")
        expect(
            StatusItemIconState.idle.feedbackDuration == nil,
            "idle should not auto-reset")

        expect(
            StatusItemIconState.extracting.symbolName == nil,
            "extracting should keep spinning the quill instead of swapping symbols")
        expect(StatusItemIconState.extracting.isSpinning, "extracting should spin")
        expect(
            StatusItemIconState.extracting.feedbackDuration == nil,
            "extracting should stay until explicitly replaced")

        expect(
            StatusItemIconState.success.symbolName == "checkmark.circle.fill",
            "success should show a checkmark")
        expect(!StatusItemIconState.success.isSpinning, "success should not spin")
        expect(
            StatusItemIconState.success.feedbackDuration == 1.5,
            "success should reset after 1.5 seconds")

        expect(
            StatusItemIconState.failure.symbolName == "exclamationmark.triangle.fill",
            "failure should show a warning triangle")
        expect(!StatusItemIconState.failure.isSpinning, "failure should not spin")
        expect(
            StatusItemIconState.failure.feedbackDuration == 3.0,
            "failure should stay visible long enough to notice")

        let labels = [
            StatusItemIconState.idle,
            .extracting,
            .success,
            .failure,
        ].map(\.accessibilityLabel)
        expect(Set(labels).count == labels.count, "accessibility labels should be distinct")
        expect(labels.allSatisfy { !$0.isEmpty }, "accessibility labels should not be empty")

        print("StatusItemIconStateTests passed")
    }
}
