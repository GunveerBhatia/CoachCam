# Coach Cam — Technical Plan

## Folder structure
```
CoachCam/
├─ project.yml                  XcodeGen spec (the only project file we edit)
├─ .github/workflows/build.yml  CI: build the unsigned .ipa + "latest" release
├─ docs/                        SETUP.md, PLAN.md
└─ CoachCam/
   ├─ App/          App entry, AppState (shared observable state)
   ├─ Camera/       CameraService (AVCaptureSession), LensController, PhotoCapture,
   │                CapabilityProbe. Outputs are pluggable, so video can be added later.
   ├─ Analysis/     FrameAnalyzer (throttled to 12 fps) + detectors:
   │                People (body pose, face), Objects (YOLO), Scene (classify, horizon,
   │                saliency), Light, Motion (CoreMotion + frame differences)
   ├─ Modes/        ModeClassifier (mirror, selfie, headshot, …) with hysteresis
   ├─ AutoSettings/ Lens, exposure, HDR, low-light, and white-balance policies + override badges
   ├─ Coaching/     RuleEngine (reads playbook.json), Smoother, CoachingPill
   ├─ Poses/        PoseLibrary (poses.json), VibePicker, step checker
   ├─ Capture/      Burst + best-shot scorer, low-light multi-frame merge
   ├─ Editing/      Enhance + looks (Dusk, Daylight, Night, Soft Portrait) in Core Image
   ├─ Ideas/        ClaudeClient, KeychainStore
   ├─ Style/        StyleStore (on-device history, bias)
   ├─ Debug/        DebugOverlay, LogStore (viewable and shareable)
   ├─ UI/           CameraScreen, badges, settings
   └─ Resources/    config.json (every threshold), playbook.json (rules),
                    poses.json (60+ poses), Models/*.mlpackage
```

## Choices
| Need | Choice | Why |
|---|---|---|
| Project | XcodeGen | Text file → .xcodeproj on CI; no Mac needed |
| CI | GitHub Actions `macos-latest`, public repo | Free, unlimited Mac minutes on public repos |
| Install | SideStore + iloader + LocalDevVPN | Free Apple ID, refreshes on the phone |
| Min iOS | **18.0** | Camera Control / volume-button capture (`onCameraCaptureEvent`) and `displayVideoZoomFactorMultiplier` need 18. Nothing we plan needs 26+. |
| People and pose | Vision (`VNDetectHumanBodyPoseRequest`, face rectangles rev. 3 for yaw/roll/pitch, face landmarks) | Built in, fast, free. The long-standing VN API is used (well documented, lower build risk than the newer Swift-only API). |
| Objects | **YOLO11n** (Ultralytics) exported to Core ML with NMS, about 5–6 MB | Smallest and fastest modern COCO detector; about 2–4 ms on the Neural Engine. COCO covers umbrella, cup, bicycle, car, bench, handbag, bottle, cell phone, pizza, cake, and more. License is AGPL-3.0, which is fine for a personal app you don't distribute. Fallback: Apple's YOLOv3-Tiny Core ML model (MIT license, older, less accurate). |
| Scene | Vision `ClassifyImageRequest`, `DetectHorizonRequest`, saliency | Built in |
| Motion | CoreMotion device motion | Gyro, tilt, and pitch for level and food angles |
| Looks | Core Image | Fast, on the GPU, built in |
| Ideas | Claude API, Sonnet model (`claude-sonnet-5`; re-checked against Anthropic's docs at M9) | Only called when you tap Ideas |
| Third-party code | **None planned** | Faster CI, nothing to break |

## What iOS won't let us do (honest list)
- **Apple's Night mode, Deep Fusion, and Smart HDR can't be forced.** Setting
  `photoQualityPrioritization = .quality` lets iOS apply its own processing when it decides to.
  For very dark scenes we build our own version: bracketed burst → align (Vision image
  registration) → average.
- **Variable aperture:** as far as I know, AVFoundation only *reports* the aperture
  (`lensAperture`); third-party apps can't *set* it. M1 adds a capability probe that shows
  on screen exactly what your phone exposes, so we can confirm.
- **2x and 8x are crops** of the 1x and 4x sensors. We reach them through zoom factors on the
  virtual triple camera. Quality should be close to Apple's Camera app, but may not match it exactly.
- **Portrait blur isn't automatic.** We can get depth data and blur the background ourselves
  in Core Image; it won't be identical to Apple's Portrait mode.
- **Macro** happens when iOS automatically switches to the ultra wide at close range.
  We allow that switch but can't control it frame by frame.
- **Mirror detection** is a heuristic: a person with a phone near their chest or face, facing
  the camera. It will sometimes be wrong; you can tap the mode badge to fix it.
- **Sunset timing:** exact golden and blue hour needs your location (optional permission).
  Without it, we estimate from the time of day.
- **No Xcode debugger or simulator on Windows.** We rely on the in-app debug overlay and log.
- **Free Apple ID:** re-sign every 7 days, 3 apps max, no iCloud/push/App Groups (we don't need them).
