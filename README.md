# False Positive Scout

Point your iPhone at things your Roboflow object detector wrongly “sees.” Scout runs **your** Core ML model live on device, saves frames while you hold the shutter, lets you swipe-review them, and uploads the mistakes you keep back to that model’s Roboflow project as **null (empty) images** so the next train learns “this is not a stick.”

Hard-negative mining you can do while walking around the house.

There is **no TestFlight or App Store build**. You try Scout by cloning this repo and sideloading with your own Xcode + Apple account.

Auth is **Log in with Roboflow** (OAuth 2.1 + PKCE, public client, no client secret). Access and refresh tokens live in Keychain on device. Paste-credential auth is removed.

## Requirements

- Mac with **Xcode 26+** (project last opened / built with Xcode 26.x toolchains)
- iPhone on **iOS 16.0+** (camera; Simulator builds but cannot capture)
- Roboflow account with a trained **object-detection** version that exposes a Core ML export (`GET /coreml/{project}/{version}`)
- Apple ID for signing (Personal Team / free account works; free-team installs typically need re-signing about every **7 days**)
- **Models:** RF-DETR Core ML exports are the path that has been exercised end-to-end. A Vision/YOLO backend also exists in code but is not claimed as fully verified.

## How to try it (sideload)

1. `git clone https://github.com/pmn4/false-positive-scout.git && cd false-positive-scout`
2. Copy the required signing template (the build fails with a clear error if it is missing):
   ```bash
   cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
   ```
3. Edit `Config/Secrets.xcconfig`: set `DEVELOPMENT_TEAM` to your Team ID and `PRODUCT_BUNDLE_IDENTIFIER` to a **unique** id (e.g. `com.yourname.falsepositivescout`).
4. Optionally copy `Config/Secrets.plist.example` → `Config/Secrets.plist` for default workspace/project (or an OAuth client ID override). The plist is **optional**.
5. Open `Scout.xcodeproj` in Xcode, plug in your iPhone, Run.
6. In **Settings**, tap **Log in with Roboflow**, approve consent, then pick workspace → project → model version; Scout downloads and caches the Core ML package.

Simulator check (no signing / no camera):

```bash
xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

## Flow

1. **Scout** — Live preview with boxes. Detection runs continuously (~10 Hz). **Frames are saved only while you hold the shutter** (“Hold button to save frames”). A frame is kept if it has detections **and** it is the first save in this hold, has more objects of some class than the last save, or looks different enough (8×8 perceptual hash; skip if similarity &gt; 0.85). Each capture stores the model `workspace/project` and version that produced it.
2. **Review** — Swipe right = keep (false positive / null candidate), left = reject. Long-press fades boxes to inspect the raw frame. Undo is available.
3. **Upload & Nullify** — Uploads each kept frame to **that frame’s** stored project (fallback: currently selected model project), then marks it null.

### When to swipe right

Keep a frame only if it contains **zero real objects of any class your project cares about**. A frame with a real stick (or ball, etc.) that the model missed is a **missing annotation**, not a null—nulling it teaches the model to ignore real objects. See Roboflow’s [Missing vs. Null Annotations](https://blog.roboflow.com/missing-and-null-image-annotations/).

### What Upload & Nullify does

For each kept frame (code paths in `FrameReviewView` / `RoboflowService`):

1. Resolves target project = `frame.modelProject` ?? currently selected `scout_model_project`.
2. Checks that project exists via `listProjects` for its workspace; skips with an error if not.
3. Uploads JPEG as `null_<uuid>.jpg` to `POST /dataset/{project}/upload` with `split=train`, `tag=scout`, `batch=Scout - yyyy-MM-dd HH:mm`.
4. Annotates null via `POST /dataset/{project}/annotate/{imageId}` with `name=annotation.coco.json` and the COCO fake-annotation workaround (see gotchas).
5. Deletes the local frame on full success. Partial failures can retry nullify only.

## Demo media

- **[PLACEHOLDER: short demo GIF or 3 screenshots — Scout / Review / Upload]**
- **[PLACEHOLDER: 30–45s demo video link]**

## Architecture (`Scout/`)

| File | Role |
|------|------|
| `ScoutApp.swift` / `ContentView.swift` | App entry, tabs |
| `CameraView.swift` | Camera, detect loop, hold-to-capture, overlay |
| `ModelManager.swift` | Download/cache Core ML, RF-DETR + Vision backends, labels/colors |
| `ModelPickerSheet.swift` | Workspace / project / version picker |
| `ThresholdManager.swift` / `ThresholdControlSheet.swift` | Global + per-class confidence |
| `FrameReviewView.swift` | Swipe deck + Upload & Nullify sheet |
| `RoboflowService.swift` | REST: list, upload, annotate-as-null |
| `Models.swift` | `Detection`, `CapturedFrame` (`modelProject` / `modelVersion`) |
| `SettingsView.swift` | Log in / Log out, model selection |
| `OAuthManager.swift` | ASWebAuthenticationSession + PKCE; tokens in Keychain; refresh + revoke |
| `ScoutLog.swift` | Decision logs always; per-frame verbose gated |
| `Config/Scout.xcconfig` + `Secrets.*` | Signing/bundle via required gitignored `Secrets.xcconfig`; optional plist defaults |

## Roboflow gotchas we learned

- **RF-DETR class order** comes from `GET /coreml/{project}/{version}` → `classes`. Index **0 is background** — skip `background_class*`.
- **Colors** from `/coreml` can be shifted; take colors **by class name** from the project endpoint.
- **Preprocessing** (Stretch vs letterbox) comes from version/model metadata; wrong mode misplaces boxes.
- **Null annotation:** empty COCO `annotations: []` is rejected. Match the Python SDK: include `info` / `licenses` / `categories`, a fake annotation whose `image_id` matches no image, body `{ "annotationFile": <coco>, "labelmap": null }`, query `name=annotation.coco.json`. Upload `name` must equal COCO `file_name`.

## Privacy & signing

- OAuth access/refresh tokens stay in Keychain. Do not commit tokens, `.env`, or footage of people (especially kids).
- `Config/Secrets.xcconfig` is gitignored and **required** (build fails if missing). `Config/Secrets.plist` is optional.
- **Caveat:** Roboflow documents open Dynamic Client Registration mainly for MCP clients. Native-app PKCE with `token_endpoint_auth_method: none` works today (verified Oct 2026) but is not officially documented for third-party iOS apps.

## License

MIT — Copyright (c) 2026 Scout Contributors.
