import Foundation

/// Recording can be stopped before AVFoundation reports didStartRecording.
/// Keep that stop request until the delegate arrives instead of losing it.
struct RecordingLifecycle {
    enum Phase { case idle, authorizing, starting, recording, stopping, saving }
    private(set) var phase = Phase.idle

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .authorizing
        return true
    }

    mutating func authorized() -> Bool {
        guard phase == .authorizing else { return false }
        phase = .starting
        return true
    }

    /// Returns true only when stopRecording can be called immediately.
    mutating func stop() -> Bool {
        switch phase {
        case .authorizing: phase = .idle; return false
        case .starting: phase = .stopping; return false
        case .recording: phase = .stopping; return true
        default: return false
        }
    }

    /// Returns true if a previously requested stop must now be forwarded.
    mutating func didStart() -> Bool {
        if phase == .starting { phase = .recording; return false }
        return true
    }

    mutating func didFinish() { phase = .saving }
    mutating func reset() { phase = .idle }
}
