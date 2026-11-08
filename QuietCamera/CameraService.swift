import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit

/// All capture state and AVFoundation mutations belong to queue.
/// Published state is delivered on the main queue. Audio is attached only for movies.
final class CameraService: NSObject, ObservableObject {
    enum Mode: String, CaseIterable {
        case automatic = "자동"
        case frame = "프레임"
    }

    struct Lens: Identifiable {
        let id: String
        let label: String
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let encoder = DispatchQueue(label: "camera.encode", qos: .userInitiated)
    private let context = CIContext()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var movieMode = false
    private var lifecycle = RecordingLifecycle()
    private var recordingRequest: UUID?
    private var devices: [AVCaptureDevice] = []
    // Accessed on the main queue only. Gives a stopped movie time to finalize on background entry.
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var active = false
    private var busy = false
    private var pendingFrame: UUID?
    private var observers: [NSObjectProtocol] = []

    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var nativeQuietSupported = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var message = "카메라를 준비하고 있어요"
    @Published private(set) var lastURL: URL?
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var selectedLensID = ""
    @Published private(set) var videoMode = false
    @Published private(set) var recordingPhase = RecordingLifecycle.Phase.idle
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingHasAudio = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.cancelPendingFrame()
                self.stopMovie()
                self.publish { $0.ready = false; $0.message = "카메라 사용이 잠시 중단되었어요" }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.active { self.configureAndStart() } }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            guard let self else { return }
            self.queue.async {
                self.cancelPendingFrame()
                self.stopMovie()
                if error?.code == .mediaServicesWereReset, self.active {
                    self.startSession()
                } else {
                    self.publish { $0.ready = false; $0.message = "카메라 오류. 앱을 다시 열어주세요" }
                }
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func publish(_ update: @escaping (CameraService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { update(self) }
        }
    }

    func resume() {
        queue.async {
            self.active = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.queue.async {
                        if granted { self.configureAndStart() } else { self.permissionDenied() }
                    }
                }
            default: self.permissionDenied()
            }
        }
    }

    func pause() {
        queue.async {
            self.active = false
            self.cancelPendingFrame()
            self.stopMovie()
            // Finalize the movie before stopping the session. The delegate stops it afterwards.
            if self.lifecycle.phase == .idle || self.lifecycle.phase == .saving {
                if self.session.isRunning { self.session.stopRunning() }
            }
            self.publish { $0.ready = false }
        }
    }

    private func permissionDenied() {
        publish { $0.cameraDenied = true; $0.ready = false; $0.message = "설정에서 카메라 사용을 허용해주세요" }
    }

    private func configureAndStart() {
        guard active else { return }
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                // .photo favors the full still pipeline; frames use the negotiated video size.
                session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    throw CameraError.unavailable
                }
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CameraError.unavailable }
                session.addInput(newInput)
                input = newInput
                guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
                    session.removeInput(newInput)
                    input = nil
                    throw CameraError.unavailable
                }
                session.addOutput(photoOutput)
                session.addOutput(videoOutput)
                devices = AVCaptureDevice.DiscoverySession(deviceTypes: [
                    .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
                ], mediaType: .video, position: .unspecified).devices
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                videoOutput.setSampleBufferDelegate(self, queue: queue)
                photoOutput.maxPhotoQualityPrioritization = .quality
                configureConnections()
                configured = true
            }
            startSession()
        } catch {
            publish { $0.ready = false; $0.message = "카메라를 열 수 없어요: \(error.localizedDescription)" }
        }
    }

    private func configureConnections() {
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video),
                           movieOutput.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        if !movieMode, let dimensions = input?.device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { photoOutput.maxPhotoDimensions = dimensions }
        publishCapabilities()
    }

    private func publishCapabilities() {
        let supported = photoOutput.isShutterSoundSuppressionSupported
        let maximum = min(input?.device.activeFormat.videoMaxZoomFactor ?? 1, 5)
        let currentZoom = input?.device.videoZoomFactor ?? 1
        let current = input?.device
        let available = devices.filter { $0.position == current?.position }.sorted {
            func rank(_ device: AVCaptureDevice) -> Int {
                switch device.deviceType {
                case .builtInUltraWideCamera: return 0
                case .builtInTelephotoCamera: return 2
                default: return 1
                }
            }
            return rank($0) < rank($1)
        }.map { device -> Lens in
            let label: String
            switch device.deviceType {
            case .builtInUltraWideCamera: label = "초광각"
            case .builtInTelephotoCamera: label = "망원"
            default: label = "광각"
            }
            return Lens(id: device.uniqueID, label: label)
        }
        publish {
            $0.nativeQuietSupported = supported
            $0.zoom = currentZoom
            $0.maxZoom = maximum
            $0.lenses = available
            $0.selectedLensID = current?.uniqueID ?? ""
        }
    }

    private func startSession() {
        guard configured, active else { return }
        if !session.isRunning { session.startRunning() }
        publishCapabilities()
        let running = session.isRunning && !session.isInterrupted
        publish {
            $0.ready = running
            $0.cameraDenied = false
            if !$0.capturing { $0.message = running ? "촬영 준비 완료" : "카메라를 사용할 수 없어요" }
        }
    }

    func flip() {
        queue.async {
            guard self.configured, self.active, !self.busy, let old = self.input else { return }
            let position: AVCaptureDevice.Position = old.device.position == .back ? .front : .back
            guard let device = self.devices.first(where: { $0.position == position && $0.deviceType == .builtInWideAngleCamera })
                ?? self.devices.first(where: { $0.position == position }) else { return }
            self.replaceCamera(with: device)
        }
    }

    func selectLens(_ id: String) {
        queue.async {
            guard self.configured, self.active, !self.busy,
                  let device = self.devices.first(where: { $0.uniqueID == id }),
                  device.uniqueID != self.input?.device.uniqueID else { return }
            self.replaceCamera(with: device)
        }
    }

    private func replaceCamera(with device: AVCaptureDevice) {
        guard let old = input, let replacement = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(replacement) {
            session.addInput(replacement)
            input = replacement
            if movieMode { chooseVideoPreset() }
        } else { session.addInput(old) }
        configureConnections()
        session.commitConfiguration()
        publishCapabilities()
    }

    /// Separate movie and photo output graphs so unsupported simultaneous outputs cannot block recording.
    func setVideoMode(_ enabled: Bool) {
        queue.async {
            guard self.configured, self.active, !self.busy, enabled != self.movieMode else { return }
            self.session.beginConfiguration()
            let previous = self.movieMode
            do {
                try self.installOutputs(video: enabled)
            } catch {
                try? self.installOutputs(video: previous)
                self.publish { $0.message = "촬영 모드를 변경할 수 없어요" }
            }
            self.configureConnections()
            self.session.commitConfiguration()
            let installed = self.movieMode
            self.publish { $0.videoMode = installed }
            self.publishCapabilities()
        }
    }

    private func chooseVideoPreset() {
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
    }

    private func installOutputs(video: Bool) throws {
        for output in session.outputs { session.removeOutput(output) }
        removeAudioInput()
        if video { chooseVideoPreset() } else { session.sessionPreset = .photo }
        let outputs: [AVCaptureOutput] = video ? [movieOutput] : [photoOutput, videoOutput]
        for output in outputs {
            guard session.canAddOutput(output) else { throw CameraError.unavailable }
            session.addOutput(output)
        }
        movieMode = video
    }

    private func updateRecordingPhase() {
        let phase = lifecycle.phase
        publish { $0.recordingPhase = phase }
    }

    func startRecording(includeAudio: Bool) {
        queue.async {
            guard self.active, self.movieMode, self.session.isRunning, !self.session.isInterrupted,
                  !self.busy, self.lifecycle.begin() else { return }
            self.busy = true
            DispatchQueue.main.async { self.beginMovieBackgroundTask() }
            let request = UUID()
            self.recordingRequest = request
            self.updateRecordingPhase()
            self.publish { $0.capturing = true; $0.message = "녹화를 준비하고 있어요" }
            if includeAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    self.queue.async { self.beginMovie(request: request, audio: granted) }
                }
            } else {
                self.beginMovie(request: request, audio: includeAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
            }
        }
    }

    private func beginMovie(request: UUID, audio: Bool) {
        guard recordingRequest == request, active, lifecycle.phase == .authorizing else { return }
        do {
            session.beginConfiguration()
            removeAudioInput()
            if audio, let device = AVCaptureDevice.default(for: .audio),
               let microphone = try? AVCaptureDeviceInput(device: device), session.canAddInput(microphone) {
                session.addInput(microphone)
                audioInput = microphone
            }
            configureConnections()
            session.commitConfiguration()
            let url = try capturesDirectory().appendingPathComponent("Quiet-\(UUID().uuidString).mov")
            guard lifecycle.authorized(), let connection = movieOutput.connection(with: .video), connection.isActive else {
                throw CameraError.unavailable
            }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
            if movieOutput.availableVideoCodecTypes.contains(.h264) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
            let hasAudio = audioInput != nil
            publish { $0.recordingHasAudio = hasAudio }
            updateRecordingPhase()
            movieOutput.startRecording(to: url, recordingDelegate: self)
        } catch {
            detachAudio()
            lifecycle.reset()
            updateRecordingPhase()
            finish("녹화를 시작할 수 없어요: \(error.localizedDescription)")
        }
    }

    func stopRecording() { queue.async { self.stopMovie() } }

    private func beginMovieBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish camera movie") { [weak self] in
            guard let self else { return }
            self.queue.async { self.stopMovie() }
            self.endMovieBackgroundTask()
        }
    }

    private func endMovieBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func stopMovie() {
        let wasAuthorizing = lifecycle.phase == .authorizing
        let shouldStop = lifecycle.stop()
        if wasAuthorizing {
            recordingRequest = nil
            finish("녹화 준비가 취소되었어요")
        }
        updateRecordingPhase()
        if shouldStop { movieOutput.stopRecording() }
    }

    private func removeAudioInput() {
        if let audioInput { session.removeInput(audioInput); self.audioInput = nil }
    }

    private func detachAudio() {
        session.beginConfiguration()
        removeAudioInput()
        session.commitConfiguration()
    }

    private func capturesDirectory() throws -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func setZoom(_ factor: CGFloat) {
        queue.async {
            guard let device = self.input?.device, !self.busy else { return }
            do {
                try device.lockForConfiguration()
                let value = min(max(factor, 1), min(device.activeFormat.videoMaxZoomFactor, 5))
                device.videoZoomFactor = value
                device.unlockForConfiguration()
                self.publish { $0.zoom = value }
            } catch { self.publish { $0.message = "줌을 변경할 수 없어요" } }
        }
    }

    func capture(mode: Mode) {
        queue.async {
            guard self.active, !self.movieMode, self.session.isRunning, !self.session.isInterrupted, !self.busy else { return }
            self.busy = true
            self.publish { $0.capturing = true; $0.message = "사진을 저장하고 있어요" }
            // Re-check on every request. Never invoke the still API without suppression support.
            if mode == .automatic && self.photoOutput.isShutterSoundSuppressionSupported {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.isShutterSoundSuppressionEnabled = true
                settings.flashMode = .off
                settings.photoQualityPrioritization = .quality
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            } else {
                let request = UUID()
                self.pendingFrame = request
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard self.pendingFrame == request else { return }
                    self.pendingFrame = nil
                    self.finish("영상 프레임을 받지 못했어요. 다시 촬영해주세요")
                }
            }
        }
    }

    private func cancelPendingFrame() {
        if pendingFrame != nil { pendingFrame = nil; finish("촬영이 중단되었어요") }
    }

    private func finish(_ message: String) {
        busy = false
        DispatchQueue.main.async { self.endMovieBackgroundTask() }
        if lifecycle.phase == .saving {
            lifecycle.reset()
            recordingRequest = nil
            updateRecordingPhase()
        }
        publish { $0.capturing = false; $0.message = message }
    }

    private func save(_ data: Data, suffix: String, source: String) {
        // Called on encoder queue. Keep a recoverable original before requesting Photos access.
        do {
            let url = try capturesDirectory().appendingPathComponent("Quiet-\(UUID().uuidString).\(suffix)")
            try data.write(to: url, options: .atomic)
            let thumb = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 180, height: 180))
            publish { $0.lastURL = url; $0.thumbnail = thumb }
            saveToLibrary(url: url, type: .photo, source: source)
        } catch {
            queue.async { self.finish("저장 실패: \(error.localizedDescription)") }
        }
    }

    private func saveToLibrary(url: URL, type: PHAssetResourceType, source: String) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    self.queue.async { self.finish("앱 내부에 저장됨 · 공유 버튼으로 내보내세요") }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: type, fileURL: url, options: nil)
                }) { success, _ in
                    self.queue.async {
                        self.finish(success ? "\(source) · 사진 앱에 저장했어요" : "사진 앱 저장 실패 · 앱 내부 원본은 공유 가능해요")
                    }
                }
            }
    }

    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "사용 가능한 카메라가 없습니다" }
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            let stopRequested = self.lifecycle.didStart()
            self.updateRecordingPhase()
            self.publish {
                $0.recordingStartedAt = Date()
                $0.message = $0.recordingHasAudio ? "동영상 녹화 중 · 소리 포함" : "동영상 녹화 중 · 소리 없음"
            }
            if stopRequested { self.movieOutput.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.lifecycle.didFinish()
            self.updateRecordingPhase()
            self.detachAudio()
            if !self.active && self.session.isRunning { self.session.stopRunning() }
            self.publish { $0.recordingStartedAt = nil; $0.message = "동영상을 저장하고 있어요" }
            let recordingError = error as NSError?
            let successful = error == nil || (recordingError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard successful, size > 0 else {
                // Keep partial files locally for recovery; do not claim they are playable.
                self.finish("녹화 완료 실패 · 앱 내부 파일을 확인해주세요")
                return
            }
            self.publish { $0.lastURL = url; $0.thumbnail = nil }
            self.saveToLibrary(url: url, type: .video, source: "동영상")
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard pendingFrame != nil, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pendingFrame = nil
        // Retain exactly the first new buffer after the shutter request, not a stale preview image.
        encoder.async {
            let image = CIImage(cvPixelBuffer: buffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let data = self.context.jpegRepresentation(of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]) else {
                self.queue.async { self.finish("사진 변환에 실패했어요") }
                return
            }
            let size = "\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))"
            self.save(data, suffix: "jpg", source: "프레임 \(size)")
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            queue.async { self.finish("사진 처리에 실패했어요. 다시 촬영해주세요") }
            return
        }
        encoder.async { self.save(data, suffix: "jpg", source: "고화질 사진") }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error { queue.async { self.finish("촬영 실패: \(error.localizedDescription)") } }
    }
}
