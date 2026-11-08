import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    @StateObject private var camera = CameraService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode = CameraService.Mode.automatic
    @State private var showGrid = true
    @State private var showLibrary = false
    @State private var blackout = false
    @State private var previousBrightness: CGFloat?
    @AppStorage("recordAudio") private var recordAudio = true
    @AppStorage("blackoutOnRecord") private var blackoutOnRecord = false
    private let accent = Color(red: 0.79, green: 0.95, blue: 0.49)

    private var usesPhoto: Bool { mode == .automatic && camera.nativeQuietSupported }
    private var recording: Bool { camera.recordingPhase == .recording }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("quiet.").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("소리 없이, 순간 그대로").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("AVFoundation", systemImage: "camera.aperture")
                    .font(.caption2).foregroundStyle(accent)
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 20)

            GeometryReader { geometry in
                ZStack {
                    CameraPreview(session: camera.session)
                    if showGrid {
                        Path { path in
                            for part in [CGFloat(1) / 3, CGFloat(2) / 3] {
                                path.move(to: CGPoint(x: geometry.size.width * part, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width * part, y: geometry.size.height))
                                path.move(to: CGPoint(x: 0, y: geometry.size.height * part))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * part))
                            }
                        }.stroke(.white.opacity(0.25), lineWidth: 0.5).allowsHitTesting(false)
                    }
                    if !camera.ready {
                        VStack(spacing: 16) {
                            Image(systemName: "camera.aperture").font(.largeTitle)
                            Text(camera.message).multilineTextAlignment(.center).font(.callout)
                            if camera.cameraDenied {
                                Button("설정 열기") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                            } else {
                                Button("다시 연결") { camera.resume() }.buttonStyle(.bordered)
                            }
                        }.padding(30).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
                    }
                    VStack {
                        HStack {
                            Label(camera.videoMode ? "동영상" : (usesPhoto ? "무음 사진" : "무음 프레임"),
                                  systemImage: camera.videoMode ? "video.fill" : "speaker.slash.fill")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer()
                            Button { showGrid.toggle() } label: {
                                Image(systemName: "grid").padding(10)
                                    .background(.black.opacity(0.55), in: Circle())
                            }.accessibilityLabel(showGrid ? "격자 끄기" : "격자 켜기")
                        }
                        Spacer()
                        HStack(spacing: 10) {
                            ForEach(camera.lenses) { lens in
                                Button { camera.selectLens(lens.id) } label: {
                                    Text(lens.label).font(.caption.weight(.semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .foregroundStyle(camera.selectedLensID == lens.id ? .black : .white)
                                        .background(camera.selectedLensID == lens.id ? accent : Color.black.opacity(0.6), in: Capsule())
                                }.accessibilityLabel("\(lens.label) 렌즈 선택")
                            }
                        }.disabled(camera.capturing || !camera.ready)
                        if camera.maxZoom > 1 {
                            HStack(spacing: 16) {
                                Text(String(format: "%.1f×", Double(camera.zoom)))
                                    .font(.caption.monospacedDigit()).frame(width: 38)
                                Slider(value: Binding(get: { camera.zoom }, set: { camera.setZoom($0) }),
                                       in: 1...camera.maxZoom)
                                    .accessibilityLabel("카메라 줌")
                            }.tint(accent).padding(12)
                                .background(.black.opacity(0.55), in: Capsule())
                                .disabled(camera.capturing || !camera.ready)
                        }
                    }.padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            .padding(.horizontal, 12)

            VStack(spacing: 14) {
                Picker("사진 또는 동영상", selection: Binding(get: { camera.videoMode }, set: { camera.setVideoMode($0) })) {
                    Text("사진").tag(false)
                    Text("동영상").tag(true)
                }.pickerStyle(.segmented).frame(width: 220).disabled(camera.capturing || !camera.ready)
                if camera.videoMode {
                    RecordingControls(camera: camera, recordAudio: $recordAudio,
                                      blackoutOnRecord: $blackoutOnRecord, blackout: $blackout)
                } else {
                    Picker("촬영 방식", selection: $mode) {
                        ForEach(CameraService.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 220).disabled(camera.capturing)
                }

                HStack {
                    Button { showLibrary = true } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
                            if let image = camera.thumbnail {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else { Image(systemName: "photo.on.rectangle").font(.title3) }
                        }.frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 14))
                    }.disabled(camera.capturing).accessibilityLabel("저장된 사진 및 동영상 열기")
                    Spacer()
                    Button {
                        if camera.videoMode {
                            if recording { camera.stopRecording() } else { camera.startRecording(includeAudio: recordAudio) }
                        } else { camera.capture(mode: mode) }
                    } label: {
                        ZStack {
                            Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 78, height: 78)
                            if recording {
                                RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(camera.capturing ? .gray : (camera.videoMode ? .red : accent)).frame(width: 64, height: 64)
                                if camera.capturing { ProgressView().tint(.black) }
                            }
                        }
                    }.disabled(!recording && (!camera.ready || camera.capturing))
                        .accessibilityLabel(camera.videoMode ? (recording ? "녹화 중지" : "녹화 시작") : "사진 촬영")
                    Spacer()
                    Button { camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2).frame(width: 54, height: 54)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }.disabled(!camera.ready || camera.capturing).accessibilityLabel("전면 후면 카메라 전환")
                }.padding(.horizontal, 18)

                VStack(spacing: 5) {
                    Text(camera.message).font(.caption).foregroundStyle(.white.opacity(0.85))
                    Text(camera.videoMode ? "MOV 동영상 · 렌즈는 녹화 시작 전에 선택하세요" :
                         (usesPhoto ? "공식 촬영음 억제 API · JPEG 사진" : "영상 원본 프레임 저장 · 일반 사진과 화질이 달라요"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).frame(minHeight: 36)
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
        }
        .background(Color(red: 0.035, green: 0.045, blue: 0.04))
        .foregroundStyle(.white)
        .accessibilityHidden(blackout)
        .overlay {
            if blackout {
                Button { blackout = false } label: {
                    Color.black.ignoresSafeArea().contentShape(Rectangle())
                }.buttonStyle(.plain).ignoresSafeArea()
                    .accessibilityLabel("녹화 화면 다시 표시")
            }
        }
        .statusBarHidden(blackout)
        .persistentSystemOverlays(blackout ? .hidden : .automatic)
        .onAppear { if scenePhase == .active { camera.resume() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.resume() }
            else if phase == .background { blackout = false; camera.pause() }
        }
        .onChange(of: camera.recordingPhase) { _, phase in
            if phase == .recording && blackoutOnRecord { blackout = true }
            if phase != .recording { blackout = false }
            UIApplication.shared.isIdleTimerDisabled = phase == .starting || phase == .recording || phase == .stopping
        }
        .onChange(of: blackout) { _, enabled in
            if enabled {
                previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 0
            } else if let previousBrightness {
                UIScreen.main.brightness = previousBrightness
                self.previousBrightness = nil
            }
        }
        .onDisappear {
            if let previousBrightness { UIScreen.main.brightness = previousBrightness; self.previousBrightness = nil }
            UIApplication.shared.isIdleTimerDisabled = false
            camera.pause()
        }
        .sheet(isPresented: $showLibrary) { CaptureLibrary() }
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ uiView: PreviewSurface, context: Context) {}
}

private struct CaptureLibrary: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView("아직 촬영 파일이 없어요", systemImage: "photo", description: Text("사진과 동영상을 이곳에서 공유할 수 있어요."))
                } else {
                    List(files, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.lastPathComponent, systemImage: url.pathExtension == "mov" ? "video" : "photo")
                                .font(.caption).lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("사진 및 동영상")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .task {
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Captures", isDirectory: true)
                files = ((try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.creationDateKey])) ?? [])
                    .filter { ["jpg", "mov"].contains($0.pathExtension.lowercased()) }
                    .sorted { lhs, rhs in
                        let a = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        let b = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        return a > b
                    }
            }
        }
    }
}
