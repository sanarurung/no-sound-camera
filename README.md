# Quiet Camera

iPhone용 SwiftUI + AVFoundation 카메라. iOS 18.0 이상 / Xcode 16 이상.

## 촬영 방식

- **자동**: `AVCapturePhotoOutput.isShutterSoundSuppressionSupported`를 매 촬영마다 확인합니다. 지원되면 `AVCapturePhotoSettings.isShutterSoundSuppressionEnabled = true`로 JPEG 사진을 촬영합니다.
- 공식 사진 무음을 지원하지 않으면 `AVCaptureVideoDataOutput`의 새 영상 프레임을 JPEG로 저장합니다. **프레임** 모드는 항상 이 방식을 사용합니다.
- 프레임은 화면 스크린샷이 아니라 카메라 픽셀 버퍼입니다. 해상도는 기기와 세션이 협상한 영상 크기에 따르며, 저장 후 실제 픽셀 크기를 화면에 표시합니다. 4K·48MP·야간 모드·기본 카메라 앱과 동일한 화질을 보장하지 않습니다.
- 공식 사진 무음 지원 여부는 지역·기기 조건에 따라 달라집니다. 미지원 상황에서 유음 사진 촬영으로 전환하지 않습니다.
- 앱 자체 촬영음, 마이크 입력, 비공개 API, 시스템 볼륨 변경은 사용하지 않습니다. 프레임 저장 방식의 실제 촬영음 여부는 해당 iPhone에서 확인해야 합니다.

공식 문서: [촬영음 억제 지원 여부](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported), [촬영음 억제 설정](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isshuttersoundsuppressionenabled), [영상 프레임 출력](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput).

## 기능

전·후면 광각 카메라, 최대 5배 디지털 줌(기기 제한 적용), 격자, 세로 촬영, 사진 앱 저장, 앱 내부 원본 보관 및 공유를 제공합니다. 전면 저장 파일은 거울 반전을 적용하지 않습니다. 플래시는 꺼져 있습니다. 미리보기는 전체 프레임이 보이도록 레터박스로 표시합니다.

카메라 권한만 먼저 요청하며, 사진 앱 추가 권한은 첫 저장 시 요청합니다. 사진 접근을 거부해도 `Documents/Captures`에 원본을 보관하며 왼쪽 아래 갤러리에서 이전 촬영 파일도 공유할 수 있습니다. Finder 파일 공유도 지원합니다. 앱 내부 원본은 자동 삭제하지 않으며, 앱 삭제 시 함께 삭제됩니다. 네트워크 전송 기능은 없습니다.

## GitHub에서 빌드

`main`에 push하면 `.github/workflows/ios-build.yml`이 macOS 러너에서 실행됩니다. Actions → **iOS build** → 실행 내역 → Artifacts에서 **QuietCamera-unsigned-iphone**을 받으세요. `workflow_dispatch` 수동 실행도 지원합니다.

포함 파일:

- `QuietCamera-unsigned.ipa`: 실제 iPhone 아키텍처로 빌드한 **미서명** 앱
- `SHA256SUMS.txt`: 패키지 체크섬
- `BUILD-NOTES.md`: 이 안내

**미서명 IPA는 그대로 iPhone에 설치할 수 없습니다.** Apple 개발자 인증서·프로비저닝으로 재서명하거나 Mac의 Xcode에서 본인 Team을 선택해 설치해야 합니다. 이 워크플로는 인증서 없이 컴파일과 패키징을 검증합니다. TestFlight/App Store 업로드, 자동 서명, 실기기 테스트는 포함하지 않습니다.

서명 설치: `QuietCamera.xcodeproj` 열기 → QuietCamera target → Signing & Capabilities → 본인 Team 선택 → 필요하면 고유 Bundle Identifier 설정 → iPhone 연결 → Run. 개발용 설치에는 iPhone의 개발자 모드가 필요할 수 있습니다.

## 로컬 빌드 (Mac)

외부 패키지나 XcodeGen 없이 바로 열 수 있는 프로젝트입니다.

```sh
python3 scripts/generate_project.py --check
xcodebuild build -project QuietCamera.xcodeproj -scheme QuietCamera \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Swift 파일을 추가/삭제하면 `python3 scripts/generate_project.py`로 프로젝트를 다시 생성하세요. 프로젝트는 Swift 5 언어 모드를 명시하며 Swift 6 엄격 동시성 모드로의 전환은 별도 작업입니다.

## 실기기 확인

1. 카메라 권한 허용/거부 후 설정에서 재허용, 앱 복귀를 확인합니다.
2. 자동 모드에서 표시되는 사진/프레임 경로와 촬영음을 실제로 확인합니다. 프레임 강제 모드도 확인합니다.
3. 전·후면 전환, 줌, 연속 탭 차단, 세로 방향과 전면 좌우 방향을 확인합니다.
4. 사진 추가 권한을 허용한 경우 사진 앱 저장을 확인합니다. 거부한 경우 앱 갤러리에서 공유 후 재실행해 파일 보존을 확인합니다.
5. HOME 이동·잠금·전화 등 중단 후 복귀와 촬영 재개를 확인합니다.
6. 앱의 프레임 픽셀 크기와 사진 앱의 실제 이미지 크기를 비교합니다.

GitHub 빌드 성공은 컴파일·패키징 성공을 뜻합니다. 실제 카메라 동작, 화질, 무음 여부는 기기 검증이 필요합니다.
