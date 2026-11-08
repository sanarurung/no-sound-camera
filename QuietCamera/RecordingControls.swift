import SwiftUI

struct RecordingControls: View {
    @ObservedObject var camera: CameraService
    @Binding var recordAudio: Bool
    @Binding var blackoutOnRecord: Bool
    @Binding var blackout: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let start = camera.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
                    Label(String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60), systemImage: "record.circle.fill")
                        .foregroundStyle(.red).font(.callout.monospacedDigit())
                        .accessibilityLabel("녹화 시간")
                }
                if camera.recordingPhase == .recording {
                    Button { blackout = true } label: {
                        Label("화면 암전", systemImage: "moon.fill")
                    }.buttonStyle(.bordered).font(.caption)
                }
            } else {
                HStack(spacing: 18) {
                    Toggle(isOn: $recordAudio) { Image(systemName: recordAudio ? "mic.fill" : "mic.slash.fill") }
                        .accessibilityLabel("동영상 소리 녹음")
                    Toggle("자동 암전", isOn: $blackoutOnRecord).font(.caption)
                }.tint(.green).disabled(camera.capturing)
                Text("암전 화면을 탭하면 돌아와요").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
