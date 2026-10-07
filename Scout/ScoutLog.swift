import Foundation

/// Lightweight logging for Scout.
/// Decision / one-shot logs always print. Per-frame verbose detect dumps are gated.
enum ScoutLog {
    /// Per-frame verbose [ScoutDetect] dumps (resize, raw idx, per-det). Off in Release.
    #if DEBUG
    static var verbose = true
    #else
    static var verbose = false
    #endif

    static func decision(_ message: String) {
        print(message)
    }

    static func verbose(_ message: String) {
        guard verbose else { return }
        print(message)
    }
}
