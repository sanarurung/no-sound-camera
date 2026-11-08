import Foundation

@main
enum RecordingLifecycleTests {
    static func main() {
        var normal = RecordingLifecycle()
        precondition(normal.begin())
        precondition(!normal.begin(), "A second tap must not create a second recording")
        precondition(normal.authorized())
        precondition(!normal.didStart())
        precondition(normal.phase == .recording)
        precondition(normal.stop())
        precondition(!normal.stop(), "Stopping twice must be harmless")
        normal.didFinish()
        precondition(!normal.begin(), "Saving must finish before another recording")
        normal.reset()
        precondition(normal.begin())

        var interruptedStart = RecordingLifecycle()
        precondition(interruptedStart.begin())
        precondition(interruptedStart.authorized())
        precondition(!interruptedStart.stop(), "Wait for didStart before forwarding stop")
        precondition(interruptedStart.phase == .stopping)
        precondition(interruptedStart.didStart(), "Background stop must survive delayed didStart")
        interruptedStart.didFinish()
        interruptedStart.reset()
        precondition(interruptedStart.phase == .idle)

        var deniedOrCancelled = RecordingLifecycle()
        precondition(deniedOrCancelled.begin())
        precondition(!deniedOrCancelled.stop())
        precondition(!deniedOrCancelled.authorized(), "Late permission callback cannot start cancelled recording")
        precondition(deniedOrCancelled.phase == .idle)
        print("Recording lifecycle: normal, duplicate taps, pending stop, permission cancellation passed")
    }
}
