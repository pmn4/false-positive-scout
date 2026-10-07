# False Positive Scout

iOS app that runs a Roboflow Core ML object-detection model live on camera, auto-captures frames when detections fire, lets you swipe-review them, and uploads confirmed false positives to **that frame’s own Roboflow project** as null / negative examples.

OAuth / “Sign in with Roboflow” is **shelved** (see [issue #3](https://github.com/pmn4/false-positive-scout/issues/3)). Use an API key.

## Setup

1. Open `Scout.xcodeproj` in **Xcode 26+**, select your team under Signing & Capabilities.
2. Build & run on a device or simulator (camera needs a device).
3. In **Settings**, paste a Roboflow API key (from [app.roboflow.com/settings/api](https://app.roboflow.com/settings/api)).
4. Pick workspace → project → model version. Scout downloads the Core ML package and caches it on device.

## Flow

1. **Scout** — live preview with boxes. Frames with detections are auto-saved (deduped by similarity / object-count change). Each capture stores the model `workspace/project` and version that produced it.
2. **Review** — Tinder-style deck: swipe right to keep (false positive), left to reject. Long-press fades boxes to inspect the raw frame.
3. **Upload & Nullify** — uploads kept frames to each frame’s `modelProject` (fallback: currently selected model) and annotates them as null via Roboflow’s COCO “fake annotation” workaround.

## Build

```bash
xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

Or open in Xcode, set your development team, Run.

## Architecture (`Scout/`)

| File | Role |
|------|------|
| `ScoutApp.swift` / `ContentView.swift` | App entry, tab shell (Scout / Review / Settings) |
| `CameraView.swift` | Camera session, live detect loop, auto-capture, overlay |
| `ModelManager.swift` | Download / cache Core ML, RF-DETR + Vision backends, class labels & colors |
| `ModelPickerSheet.swift` | Workspace / project / version picker |
| `ThresholdManager.swift` / `ThresholdControlSheet.swift` | Global + per-class confidence thresholds |
| `FrameReviewView.swift` | Swipe deck, export / upload & nullify sheet |
| `RoboflowService.swift` | REST: workspaces, projects, upload, annotate-as-null |
| `Models.swift` | `Detection`, `CapturedFrame` (incl. `modelProject` / `modelVersion`) |
| `SettingsView.swift` | API key (Keychain), model selection |
| `OAuthConfig.swift` / `OAuthManager.swift` | Shelved OAuth (flagged off) |
| `ScoutLog.swift` | Decision logs always; per-frame verbose gated (`ScoutLog.verbose`) |

## Roboflow gotchas we learned

- **RF-DETR class order** comes only from `GET /coreml/{project}/{version}` → `classes`. Index **0 is background** — skip `background_class*` labels.
- **Colors** from `/coreml` are shifted vs class order. Take colors **by class name** from the project endpoint.
- **Preprocessing** (Stretch vs letterbox) comes from version / model metadata; wrong mode misplaces boxes.
- **Null annotation**: empty COCO `annotations: []` is rejected (`Unrecognized annotation format`). Match the Python SDK: include `info` / `licenses` / `categories`, a fake annotation whose `image_id` matches no image, POST body `{ "annotationFile": <coco>, "labelmap": null }`, query `name=annotation.coco.json`. Upload `name` (e.g. `null_….jpg`) must equal COCO `file_name`.
- **Upload target** is the project stored on the capture, not a separate picker default (avoids stale slugs like `wall-star`).

## Privacy

API keys live in Keychain. Do not commit keys, `.env` files, or media of people (especially kids). `.gitignore` excludes `.DS_Store`, Xcode user data, DerivedData, and local `.mlmodel` / `.mlpackage` caches.
