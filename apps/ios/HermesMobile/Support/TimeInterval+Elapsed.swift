import Foundation

extension TimeInterval {
    /// This duration as `m:ss` (minutes, zero-padded seconds), clamped at zero.
    ///
    /// The shared elapsed-time format for the recording strips and the turn
    /// activity bar — e.g. `0` → `"0:00"`, `5` → `"0:05"`, `75` → `"1:15"`.
    /// Minutes are not zero-padded (matching the existing `%d:%02d` callers).
    var mmss: String {
        let seconds = max(0, Int(self))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
