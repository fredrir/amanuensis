import Foundation

/// Visual states for the menu-bar status item icon.
///
/// The state is deliberately free of AppKit so the mapping from behaviour to
/// icon can be unit-tested without a running menu bar.
enum StatusItemIconState: Equatable {
    /// Resting state: the bundled quill glyph.
    case idle
    /// An extraction is running: the quill glyph spins in place.
    case extracting
    /// A transient confirmation after content was copied.
    case success
    /// A transient warning after an extraction failed.
    case failure

    /// SF Symbol shown for transient states. The quill asset is used when nil.
    var symbolName: String? {
        switch self {
        case .idle, .extracting:
            return nil
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Whether the icon should rotate continuously.
    var isSpinning: Bool {
        self == .extracting
    }

    /// How long transient feedback stays on screen before returning to idle.
    var feedbackDuration: TimeInterval? {
        switch self {
        case .idle, .extracting:
            return nil
        case .success:
            return 1.5
        case .failure:
            return 3.0
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:
            return "Amanuensis"
        case .extracting:
            return "Extracting text"
        case .success:
            return "Extraction complete"
        case .failure:
            return "Extraction failed"
        }
    }
}
