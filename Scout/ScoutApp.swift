import SwiftUI

// "I know I can, be what I wanna be" - Nas (probably)
// Main app entry point

@main
struct ScoutApp: App {
    @StateObject private var frameStorage = FrameStorage()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(frameStorage)
        }
    }
}
