import SwiftUI

// "It ain't hard to tell, I excel, then prevail" - Nas (probably)
// Main navigation and coordination view

struct ContentView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @AppStorage("scout_confidence") private var confidence: Int = 40
    @StateObject private var oauthManager = OAuthManager.shared
    
    @State private var selectedTab = 0
    @State private var hasCheckedInitialAuth = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            CameraView(isActive: Binding(
                get: { selectedTab == 0 },
                set: { _ in }
            ))
                .tabItem {
                    Label("Scout", systemImage: "camera.fill")
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
        .onAppear {
            // On first launch, if user isn't authenticated, open Settings tab
            // so they can configure their API key right away
            if !hasCheckedInitialAuth {
                hasCheckedInitialAuth = true
                
                let apiKey = KeychainHelper.loadAPIKey() ?? Secrets.roboflowAPIKey ?? ""
                let isConfigured: Bool
                
                if OAuthConfig.isEnabled {
                    // OAuth enabled: check OAuth OR API key
                    isConfigured = oauthManager.isAuthenticated || !apiKey.isEmpty
                } else {
                    // OAuth disabled: check API key only
                    isConfigured = !apiKey.isEmpty
                }
                
                if !isConfigured {
                    selectedTab = 2 // Settings tab
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(FrameStorage())
}
