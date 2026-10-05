# False Positive Scout

**Capture null frames to improve your object detection model.**

Scout is a native iOS app that helps you collect false-positive frames from your Roboflow object detection model. Point Scout at scenes where nothing should be detected, and it automatically saves frames where your model incorrectly fires. These "null frames" are valuable negative examples that help reduce false positives when added back to your training data.

## What are Null Frames?

When training object detection models, it's important to include negative examples—images where your target objects are absent. Without these, models often develop false positives, detecting objects in backgrounds, textures, or lighting conditions where nothing should be detected.

**Scout automates null frame collection:**
1. You point your iPhone camera at scenes that should trigger zero detections
2. Scout runs your model continuously in the background
3. Whenever the model incorrectly detects something (a false positive), Scout saves that frame
4. You review, keep or discard frames with a fast swipe interface
5. Export kept frames to your Photos library and upload them to Roboflow as null examples

## Features

- 📱 **Native iOS App** – Built with SwiftUI for iPhone
- 📷 **Front & Back Camera** – Switch between cameras on the fly
- 🎯 **Smart Debouncing** – Prevents rapid-fire duplicate captures (3-second cooldown)
- 🔍 **Fast Review UI** – Swipe through frames, keep or delete with a tap
- 💾 **Local Storage** – All frames stored on device, review offline
- 📤 **Photos Export** – Save kept frames to Photos for upload to Roboflow
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

2. **Configure Scout:**
   - Open Scout and tap the **Settings** tab
   - Enter your **Model ID**
   - Enter your **API Key**
   - Adjust **Confidence Threshold** if needed (default: 40%)

### Usage

#### Scanning for Null Frames

1. Tap the **Scan** tab
2. Point the camera at scenes where your model should **NOT** detect anything
3. Tap **Start** to begin scanning
4. Scout checks frames every 2 seconds
5. When a detection occurs (false positive), the frame is automatically saved
6. The counter shows how many frames have been captured
7. Tap **Stop** when finished

**Tips:**
- Switch between front and back cameras using the camera flip button
- Try different backgrounds, lighting, and angles
- Look for scenes similar to where your model will be deployed

#### Reviewing Frames

1. Tap the **Review** tab (badge shows frame count)
2. **Swipe left/right** to navigate through captured frames
3. Tap **Keep** (green) to mark a frame for export, or tap again to discard (orange)
4. Tap **Delete** (red) to remove a frame entirely
5. Use the menu (•••) to export or clear all frames

#### Exporting to Roboflow

1. In the Review tab, tap the menu (•••) in the top right
2. Select **Export Kept Frames**
3. Tap **Save to Photos** to export frames to your Photos library
4. Open [Roboflow](https://app.roboflow.com) in your browser
5. Navigate to your project and upload the exported images
6. Label them as negative examples (or leave them unlabeled as null frames)
7. Generate a new model version and retrain

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
- **API:** Roboflow Inference API
- **Camera:** AVFoundation
- **Storage:** UserDefaults + Documents Directory

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
