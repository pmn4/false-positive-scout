# False Positive Scout

**Capture null frames to improve your object detection model.**

Scout is a native iOS app that helps you collect false-positive frames from your Roboflow object detection model. Point Scout at scenes where nothing should be detected, and it automatically saves frames where your model incorrectly fires. These "null frames" are valuable negative examples that help reduce false positives when added back to your training data.

## What are Null Frames?

When training object detection models, it's important to include negative examples—images where your target objects are absent. Without these, models often develop false positives, detecting objects in backgrounds, textures, or lighting conditions where nothing should be detected.

**Scout automates null frame collection:**
1. Start detection mode and point your iPhone camera at scenes that should trigger zero detections
2. Scout runs your model continuously in the background
3. **Hold the record button** when you see false positives to save frames
4. Scout automatically deduplicates similar frames while you're recording
5. Review saved frames with a swipe interface and undo mistakes
6. Bulk upload kept frames directly to Roboflow and mark them as null examples

## Features

- 📱 **Native iOS App** – Built with SwiftUI for iPhone
- 🧠 **On-Device Inference** – Runs object detection models locally via Core ML (no network required after download)
- 🔒 **Dual Authentication** – OAuth 2.1 (PKCE) or API key (clone-and-build friendly)
- 📷 **Front & Back Camera** – Switch between cameras on the fly
- 🎥 **Hold-to-Record** – Only saves frames while you hold the record button
- 🎯 **Smart Deduplication** – Uses perceptual hashing to skip similar frames
- ↩️ **Undo Support** – Easily undo accidental deletions or keep/discard actions
- 🔍 **Fast Review UI** – Swipe through frames, keep or delete with a tap
- 💾 **Local Storage** – All frames stored on device, review offline
- ☁️ **Bulk Upload** – Upload kept frames directly to Roboflow with progress tracking
- 🏷️ **Auto-Tagging** – Tags uploads with "scout" for easy filtering
- 🏷️ **Auto-Nullify** – Automatically marks uploaded frames as null/negative examples
- 📦 **Batch Grouping** – Groups uploads into annotation batches with session timestamp
- 📥 **Model Caching** – Downloads models once, runs fully offline afterward
- ⚙️ **Configurable Threshold** – Adjust confidence levels for capture sensitivity

## Requirements

- iOS 16.0 or later
- iPhone (optimized for iPhone)
- A Roboflow account with an object detection model
- Camera permission

## Getting Started

Scout offers **two authentication options**:

1. **OAuth 2.1 (Recommended for production):** Sign in with Roboflow via Universal Links
2. **API Key (Quick clone-and-build):** Paste an API key — no OAuth setup needed

Choose the path that fits your workflow. OAuth is preferred for App Store distribution and provides better security, but API key is faster for local testing.

---

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/pmn4/false-positive-scout.git
   cd false-positive-scout
   ```

2. **Open in Xcode:**
   ```bash
   open Scout.xcodeproj
   ```

3. **Build and Run:**
   - Select your iPhone or simulator as the build target
   - Press `Cmd+R` to build and run
   - Accept camera permission when prompted

---

## Configuration Path 1: OAuth (Recommended)

#### 1. Set Up Universal Links for OAuth Redirect

Scout uses **https://** redirect URIs via iOS Universal Links (required by Roboflow OAuth).

**Option A: Use the provided pmnewell.com URL (recommended for testing):**
- Redirect URI: `https://pmnewell.com/false-positive-scout/oauth/callback`
- The `apple-app-site-association` file is hosted at `https://pmnewell.com/.well-known/apple-app-site-association` (maintained in pmn4/pmn4.github.io repository)
- See `docs/apple-app-site-association` in this repository for a reference template
- Skip to step 2 (no hosting setup needed)

**Option B: Use your own domain (for production):**
1. **Host the apple-app-site-association file:**
   - Copy `apple-app-site-association` from this repository
   - Replace `TEAM_ID` with your Apple Developer Team ID
   - Host it at `https://yourdomain.com/.well-known/apple-app-site-association`
   - OR at `https://yourdomain.com/apple-app-site-association` (root fallback)
   - Must be served with `Content-Type: application/json` or `application/pkcs7-mime`
   - Must be accessible over HTTPS (certificate valid, no redirects)

2. **Update the redirect URI in code:**
   - Open `Scout/OAuthManager.swift`
   - Update `redirectURI` to your domain + path (e.g., `https://yourdomain.com/oauth/callback`)
   - Ensure the path matches what's in your `apple-app-site-association` file

#### 2. Configure Associated Domains in Xcode

1. **Open the project in Xcode:**
   ```bash
   open Scout.xcodeproj
   ```

2. **Add Associated Domains capability:**
   - Select the **Scout** target
   - Go to **Signing & Capabilities** tab
   - Click **+ Capability**
   - Add **Associated Domains**
   - Add domain: `applinks:pmnewell.com` (or `applinks:yourdomain.com` if using your own)
   - Do NOT include `https://` or paths in the Associated Domains entry

#### 3. Register a Roboflow OAuth App

1. **Open Roboflow Developer Settings:**
   - Log in to [Roboflow](https://app.roboflow.com)
   - Go to **Workspace Settings > Developer**

2. **Create a new OAuth app:**
   - Click **Create OAuth App** (or **New app**)
   - Fill in the following:
     - **Name**: `Scout` (or your preferred name)
     - **Homepage URL**: Your app homepage (e.g., `https://github.com/pmn4/false-positive-scout`)
     - **Redirect URI**: `https://pmnewell.com/false-positive-scout/oauth/callback`
       - (or your custom domain if using Option B above)
       - Must exactly match the redirect URI in `OAuthManager.swift`
     - **Token endpoint authentication**: `client_secret_post` (default)
     - **Allowed scopes**: Select the following scopes:
       - `workspace:read` - List workspaces
       - `project:read` - List projects
       - `version:read` - List model versions for download
       - `image:create` - Upload null frames
       - `image:read` - Read uploaded images
       - `image:tag` - Tag uploads with "scout"
       - `image:annotate` - Mark images as null examples
       - `batch:create` - Create annotation batches
       - `batch:read` - Read batch info
     - **Visibility**: `Internal` (recommended) or `Unlisted`

3. **Copy your Client ID:**
   - After creating the app, copy the **Client ID** (starts with `rfc_...`)
   - You'll paste this into the Scout code in the next step

#### 4. Configure Scout with Your OAuth Client ID

1. **Update the OAuth Client ID:**
   - Open `Scout/OAuthManager.swift`
   - Find the line: `private let clientId = "YOUR_ROBOFLOW_OAUTH_CLIENT_ID"`
   - Replace `YOUR_ROBOFLOW_OAUTH_CLIENT_ID` with your Client ID from step 3
   - Verify `redirectURI` matches your Roboflow OAuth app redirect URI exactly

5. **Sign in and configure Scout:**
   - Open Scout and tap the **Settings** tab
   - Tap **Sign in with Roboflow**
   - Authorize Scout to access your workspaces, projects, and models

6. **Download an on-device detection model:**
   - After sign-in, tap **Load Workspaces & Projects**
   - Under **On-Device Detection Model**:
     - Select the **Workspace** containing your model
     - Select the **Project** with a trained object detection model
     - Choose a **Model Version** (Core ML compatible: RF-DETR, YoloLite)
     - Tap **Download Model** to cache it locally
   - The model downloads once and runs **fully offline** for all future scouting
   - Supports **RF-DETR**, **YoloLite**, and **Classification** models exported to Core ML

7. **Select upload destination:**
   - Under **Upload Destination**, choose the project where null frames will be uploaded
   - This can be the same project as your detection model, or a different one

8. **Adjust detection threshold (optional):**
   - Set **Confidence Threshold** (default: 40%)
   - Lower values capture more detections, including weak false positives

---

## Configuration Path 2: API Key (Quick Setup)

**No OAuth, no Universal Links, no AASA hosting required.** Ideal for clone-and-build or quick testing.

1. **Get your Roboflow API key:**
   - Log in to [Roboflow](https://app.roboflow.com)
   - Go to **Settings > API**
   - Copy your API key

2. **Configure Scout:**
   - Open Scout and tap the **Settings** tab
   - Scroll to **Authentication (Option 2: API Key)**
   - Paste your **API Key**
   - Enter your **Project ID** (from your project URL, e.g., `my-project`)

3. **Download an on-device model:**
   - **Current limitation:** In-app model download requires OAuth authentication
   - **API key users cannot download models directly in Scout at this time**
   - **Workaround options:**
     - Sign in with OAuth to download the model, then sign out and use API key for uploads
     - Or manually download a Core ML model from Roboflow and load it via code (not covered in this quick path)

4. **Start scouting:**
   - API key will be used for upload, tagging, nullify, and batch creation
   - All upload features work the same as OAuth path

**Notes:** 
- OAuth takes priority. If you're signed in with OAuth, the API key is ignored. Sign out to use API key for uploads.
- The "Start" button on the Scan tab remains disabled until a model is loaded (requires OAuth model download for now).

---

### Usage

#### Scouting for False Positives

1. Tap the **Scan** tab
2. Point the camera at scenes where your model should **NOT** detect anything
3. Tap **Start** to begin detection mode
4. Scout runs inference continuously in the background
5. When you see a false positive, **press and hold** the record button (circular button)
6. While holding, frames with detections are saved (duplicate frames are automatically filtered)
7. Release the button to stop saving frames
8. The counter shows how many frames have been captured
9. Switch cameras with the flip button if needed
10. Tap **Stop Scanning** when finished

**Tips:**
- Detection runs continuously—you only save what you want by holding the button
- This prevents accidental true-positive captures (e.g., walking past actual objects)
- Hold the button steady for a few seconds to capture variations
- Similar frames are automatically deduplicated using perceptual hashing

#### Reviewing Frames

1. Tap the **Review** tab (badge shows frame count)
2. **Swipe left/right** to navigate through captured frames
3. Tap **Keep** (green) to mark a frame for upload, or tap to toggle to discard (orange)
4. Tap **Delete** (red) to remove a frame entirely
5. Use the **Undo button** (↩️) in the top left to undo the last action
6. Use the menu (•••) to upload or clear all frames

#### Uploading to Roboflow

1. In the Review tab, tap the menu (•••) in the top right
2. Select **Upload & Nullify**
3. Tap **Upload & Nullify** to start the bulk upload
4. Scout uploads kept frames to Roboflow and automatically marks them as null/negative examples using COCO JSON annotations (same mechanism as the Roboflow CLI/SDK)
5. Progress is shown with a progress bar
6. Completion screen shows:
   - **Full success**: Frames uploaded and marked as null (removed from review list)
   - **Partial success**: Frames uploaded but nullify failed (can retry)
   - **Failure**: Upload failed entirely
7. For partial successes, tap **Retry Nullify** to mark uploaded images as null (no re-upload)
8. Frames that succeed are automatically removed from your review list
9. Generate a new model version and retrain to reduce false positives

**Upload vs Nullify Failures:**
- **Upload failure**: Image never reached Roboflow (full failure, can retry full upload)
- **Nullify failure**: Image is in Roboflow but not marked as null (partial success)
  - Retry from the app with **Retry Nullify** (only marks as null, doesn't re-upload)
  - Or mark as Null manually in the Roboflow UI (∅ button in Annotate)
- Successfully uploaded+nullified frames are removed from review to prevent duplicate uploads

### Example Scenarios

**Security Camera Model:**
- Point Scout at empty hallways, parking lots, or rooms
- Capture false positives from shadows, lights, or objects that aren't people

**Product Detection Model:**
- Show Scout shelves without your target products
- Capture frames where similar items or packaging causes false detections

**Wildlife Detection Model:**
- Film vegetation, terrain, or weather conditions without animals
- Collect frames where patterns in nature trigger false alerts

## Technical Stack

- **Language:** Swift 5.0
- **Framework:** SwiftUI
- **Platform:** iOS 15.4+ (iOS 18.0+ for instance segmentation models)
- **On-Device Inference:** Core ML + Vision framework
- **Authentication:** OAuth 2.1 (authorization code + PKCE) via ASWebAuthenticationSession
- **API:** Roboflow REST API (api.roboflow.com) with Bearer tokens
- **Model Format:** Core ML (.mlpackage) - RF-DETR, YoloLite, Classification
- **Camera:** AVFoundation
- **Storage:** UserDefaults + Documents Directory + Keychain (OAuth tokens) + Caches (models)
- **Image Similarity:** Perceptual hashing (custom implementation)
- **Architecture:** MVVM with ObservableObject state management

## Privacy & Security

- **On-Device Inference:** Detection runs entirely on-device via Core ML (no images sent to cloud for inference)
- **Offline Operation:** After model download, scouting works completely offline
- **Local First:** All frame data is stored on your device
- **OAuth Security:** Access tokens stored securely in iOS Keychain; refresh tokens valid for 30 days
- **Minimal Scopes:** Requests only necessary permissions (workspace/project/version read, image create/read/tag/annotate, batch create/read)
- **PKCE Protection:** Uses OAuth 2.1 with PKCE (Proof Key for Code Exchange) for public clients
- **Camera Permission:** Required for frame capture; you control when scanning is active
- **Direct Upload:** Frames are uploaded directly to your Roboflow project (no Photos export)
- **Auto-Tagging:** Uploads tagged with "scout" for easy identification
- **Batch Grouping:** Groups uploads by session timestamp (e.g., "Scout - 2026-10-05 18:34") for annotation workflow
- **Generic Scenes:** Scout is designed for object detection on generic scenes—avoid filming people or sensitive content

## Project Structure

```
Scout/
├── ScoutApp.swift          # App entry point
├── ContentView.swift       # Main tab navigation
├── CameraView.swift        # Camera feed with on-device inference
├── FrameReviewView.swift   # Swipe review interface
├── SettingsView.swift      # OAuth sign-in, model picker, project picker UI
├── OAuthManager.swift      # OAuth 2.1 + PKCE flow manager
├── ModelManager.swift      # Core ML model download, caching, inference
├── RoboflowService.swift   # Roboflow REST API (upload, tag, annotate)
├── Models.swift            # Data models and storage
├── Info.plist             # App permissions, OAuth URL scheme
└── Assets.xcassets/       # App icons and assets
```

## Testing OAuth Flow & On-Device Inference

After configuring your OAuth Client ID:

1. **Build and run** Scout on a physical device or simulator (iOS 15.4+)
2. **Sign in:**
   - Open Settings and tap **Sign in with Roboflow**
   - Authorize Scout in the web view (you'll see your OAuth app name)
   - Verify redirect: Scout should close the web view and show "Signed in to Roboflow"
3. **Download a model:**
   - Tap **Load Workspaces & Projects**
   - Select your workspace and a project with a trained Core ML-compatible model (RF-DETR or YoloLite)
   - Choose a model version and tap **Download Model**
   - Wait for "Model ready for on-device inference" confirmation
4. **Select upload destination:**
   - Choose the project where null frames will be uploaded
5. **Test scouting:**
   - Go to the **Scan** tab
   - Tap **Start** (button is disabled until model is loaded)
   - Point camera at scenes, hold the record button when false positives occur
   - Captured frames appear in the **Review** tab
6. **Test upload:**
   - Review captured frames
   - Tap **Upload & Nullify** from the menu
   - Uploaded frames are tagged with "scout" and marked as null examples

### Troubleshooting OAuth

- **"Invalid redirect URI" or "Unsupported scheme" error:**
  - Roboflow requires `https://` redirect URIs (or `http://` for localhost only)
  - Verify the redirect URI in your Roboflow OAuth app exactly matches `redirectURI` in `OAuthManager.swift`
  - If using a custom domain, ensure it starts with `https://`

- **"Invalid client" error:**
  - Double-check the Client ID in `OAuthManager.swift` matches your Roboflow OAuth app
  - Ensure you didn't include extra spaces or quotes

- **Sign-in opens but doesn't return to Scout:**
  - **Check Associated Domains:**
    - In Xcode, go to Scout target > Signing & Capabilities > Associated Domains
    - Verify domain is listed (e.g., `applinks:pmnewell.com`)
    - Do NOT include `https://` or paths in Associated Domains
  - **Verify apple-app-site-association file:**
    - Visit `https://yourdomain.com/.well-known/apple-app-site-association`
    - Should return valid JSON (not 404)
    - Must be served over HTTPS with valid certificate
    - Check `TEAM_ID` matches your Apple Developer Team ID
    - Check `paths` array includes your OAuth callback path
  - **Test Universal Link:**
    - In Safari on your iPhone, visit your redirect URL
    - Should prompt to open in Scout (if Associated Domains is configured correctly)
  - **Rebuild after configuration changes:**
    - Clean build folder (Cmd+Shift+K)
    - Rebuild and reinstall the app

- **Token expired / refresh failed:**
  - Access tokens expire after 1 hour; refresh tokens expire after 30 days
  - Sign out and sign in again to get fresh tokens

- **Upload/model download fails with 401/403:**
  - Your OAuth app must have the required scopes: `workspace:read`, `project:read`, `version:read`, `image:create`, `image:read`, `image:tag`, `image:annotate`
  - Sign out, update scopes in Roboflow OAuth app settings, then sign in again

### Troubleshooting On-Device Inference

- **"Start" button is disabled / grayed out:**
  - A Core ML model must be downloaded first
  - Go to Settings > On-Device Detection Model > Download Model

- **Model download fails:**
  - Ensure your project has a trained model version
  - Only RF-DETR, YoloLite, and Classification models support Core ML export
  - Check that `version:read` scope is enabled in your OAuth app

- **"No model loaded" error during scanning:**
  - The downloaded model may have failed to load
  - Try downloading the model again from Settings
  - Check device storage (models can be 10-100+ MB)

- **Inference is slow or uses too much battery:**
  - Core ML models run on Neural Engine (A11+ / iPhone 8+) for best performance
  - Older devices fall back to GPU, which is slower and less power-efficient
  - Consider using a lighter model architecture (YoloLite instead of RF-DETR)

- **No detections or incorrect detections:**
  - Verify you downloaded the correct model version
  - Check the confidence threshold (Settings > Detection Settings)
  - Ensure the model was trained on similar object classes and conditions

## apple-app-site-association File

The default OAuth redirect URI (`https://pmnewell.com/false-positive-scout/oauth/callback`) uses the pmnewell.com domain. The `apple-app-site-association` file is hosted at:

**Live file:** `https://pmnewell.com/.well-known/apple-app-site-association`

This file is maintained in the `pmn4/pmn4.github.io` repository (Patrick's site repository), **not** in this repository.

**Reference template:** See `docs/apple-app-site-association` in this repository for a reference template showing the required format.

### If using your own custom domain:

1. **Update the TEAM_ID in the template:**
   - Copy `docs/apple-app-site-association`
   - Replace `<TEAMID>` with your Apple Developer Team ID
   - Find your Team ID in Xcode: Scout target > Signing & Capabilities > Team

2. **Host at your domain:**
   - Place the file at `https://yourdomain.com/.well-known/apple-app-site-association`
   - Ensure it's served over HTTPS with a valid certificate
   - Content-Type should be `application/json` or `application/pkcs7-mime`
   - Verify it's accessible before testing OAuth

3. **Update the redirect URI:**
   - Change `redirectURI` in `Scout/OAuthManager.swift`
   - Update the Associated Domains in Xcode: `applinks:yourdomain.com`
   - Register the new redirect URI in your Roboflow OAuth app settings

## Building for Release

1. Open `Scout.xcodeproj` in Xcode
2. Select **Any iOS Device** as the build target
3. Set your development team in Signing & Capabilities
4. Add **Associated Domains** capability with your domain (e.g., `applinks:pmnewell.com`)
5. Verify bundle ID is `com.scout.app`
6. Archive the app: **Product > Archive**
7. Distribute via App Store Connect or TestFlight

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## LEGAL / DISCLAIMER

This software is provided **AS IS**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement.

**Patrick Newell and contributors shall not be liable** for any claim, damages, or other liability—whether in an action of contract, tort, or otherwise—arising from, out of, or in connection with the software or the use or other dealings in the software.

**By using this software, you assume all risk.** You are solely responsible for how you deploy, configure, and operate False Positive Scout, including any use of cameras, third-party APIs (such as Roboflow), exported images, and training data derived from those images.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Built for the Roboflow community to make null frame collection easier and more efficient, especially for developers working in the field with iPhones.

---

**Need help?** Check out the [Roboflow documentation](https://docs.roboflow.com) or visit the [Roboflow community forum](https://discuss.roboflow.com).
