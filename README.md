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
- 📷 **Front & Back Camera** – Switch between cameras on the fly
- 🎥 **Hold-to-Record** – Only saves frames while you hold the record button
- 🎯 **Smart Deduplication** – Uses perceptual hashing to skip similar frames
- ↩️ **Undo Support** – Easily undo accidental deletions or keep/discard actions
- 🔍 **Fast Review UI** – Swipe through frames, keep or delete with a tap
- 💾 **Local Storage** – All frames stored on device, review offline
- ☁️ **Bulk Upload** – Upload kept frames directly to Roboflow with progress tracking
- 🏷️ **Auto-Nullify** – Automatically marks uploaded frames as null/negative examples
- 🤖 **Roboflow Integration** – Direct inference through Roboflow's API
- ⚙️ **Configurable Threshold** – Adjust confidence levels for capture sensitivity

## Requirements

- iOS 16.0 or later
- iPhone (optimized for iPhone)
- A Roboflow account with an object detection model
- Camera and Photos permissions

## Getting Started

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
   - Accept camera and photos permissions when prompted

### Configuration

1. **Get your Roboflow credentials:**
   - Log in to [Roboflow](https://roboflow.com)
   - Open your object detection project
   - Navigate to your model version
   - Copy the Model ID (format: `workspace/version`, e.g., `my-workspace/3`)
   - Get your API key from your [Roboflow settings](https://app.roboflow.com/settings/api)
   - Note your **Workspace** name and **Project ID** from your project URL

2. **Configure Scout:**
   - Open Scout and tap the **Settings** tab
   - Enter your **Model ID** (for inference)
   - Enter your **API Key**
   - Enter your **Workspace** name (for upload)
   - Enter your **Project ID** (for upload)
   - Adjust **Confidence Threshold** if needed (default: 40%)

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
4. Scout uploads kept frames to Roboflow and marks them as null/negative examples
5. Progress is shown with a progress bar
6. Once complete, frames are ready in your Roboflow project
7. Generate a new model version and retrain to reduce false positives

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
- **Platform:** iOS 16.0+
- **API:** Roboflow Inference & Upload APIs
- **Camera:** AVFoundation
- **Storage:** UserDefaults + Documents Directory
- **Image Similarity:** Perceptual hashing (custom implementation)
- **Architecture:** MVVM with ObservableObject state management

## Privacy & Security

- **Local First:** All frame data is stored on your device
- **No Backend:** Scout doesn't store or transmit your images to any server except Roboflow's API for inference
- **API Key Protection:** API keys are stored only in iOS app storage (UserDefaults) and never logged or exposed
- **Camera Permission:** Required for frame capture; you control when scanning is active
- **Photos Permission:** Required only when exporting frames to your Photos library
- **Generic Scenes:** Scout is designed for object detection on generic scenes—avoid filming people or sensitive content

## Project Structure

```
Scout/
├── ScoutApp.swift          # App entry point
├── ContentView.swift       # Main tab navigation
├── CameraView.swift        # Camera feed and scanning logic
├── FrameReviewView.swift   # Swipe review interface
├── SettingsView.swift      # Configuration UI
├── RoboflowService.swift   # Roboflow API integration
├── Models.swift            # Data models and storage
├── Info.plist             # App permissions and config
└── Assets.xcassets/       # App icons and assets
```

## Building for Release

1. Open `Scout.xcodeproj` in Xcode
2. Select **Any iOS Device** as the build target
3. Set your development team in Signing & Capabilities
4. Archive the app: **Product > Archive**
5. Distribute via App Store Connect or TestFlight

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
