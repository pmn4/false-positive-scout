import SwiftUI

// "It ain't hard to tell, I excel, then prevail" - Nas (probably)
// Main navigation and coordination view

struct ContentView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @AppStorage("scout_model_id") private var modelId: String = ""
    @AppStorage("scout_api_key") private var apiKey: String = ""
    @AppStorage("scout_confidence") private var confidence: Int = 40
    
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            CameraView()
                .tabItem {
                    Label("Scan", systemImage: "camera.fill")
                }
                .tag(0)
            
            FrameReviewView()
                .tabItem {
                    Label("Review", systemImage: "photo.on.rectangle.angled")
                }
                .badge(frameStorage.frames.count)
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(FrameStorage())
}
