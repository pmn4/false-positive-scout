import SwiftUI

// "I know I can, be what I wanna be" - Nas (probably)
// Main app entry point

@main
struct ScoutApp: App {
    @StateObject private var frameStorage = FrameStorage()
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var showSplash = true
    @State private var splashOpacity: Double = 1
    @State private var splashStartedAt = Date()
    @State private var didScheduleSplashDismiss = false

    private let splashMinSeconds: Double = 0.35
    private let splashMaxSeconds: Double = 2.0
    private let splashFadeSeconds: Double = 0.3
    private let launchLogoPoints: CGFloat = 180

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(frameStorage)

                if showSplash {
                    ZStack {
                        Color("LaunchBackground")
                            .ignoresSafeArea()
                        Image("LaunchLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: launchLogoPoints, height: launchLogoPoints)
                    }
                    .opacity(splashOpacity)
                    .allowsHitTesting(splashOpacity > 0.01)
                    .ignoresSafeArea()
                    .zIndex(1)
                }
            }
            .onAppear {
                splashStartedAt = Date()
                scheduleSplashSafetyTimeout()
                if modelManager.isStartupReady {
                    dismissSplashWhenAllowed()
                }
            }
            .onChange(of: modelManager.isStartupReady) { ready in
                if ready {
                    dismissSplashWhenAllowed()
                }
            }
        }
    }

    private func scheduleSplashSafetyTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(splashMaxSeconds * 1_000_000_000))
            dismissSplashWhenAllowed(force: true)
        }
    }

    private func dismissSplashWhenAllowed(force: Bool = false) {
        guard showSplash else { return }
        if didScheduleSplashDismiss && !force { return }
        didScheduleSplashDismiss = true

        let elapsed = Date().timeIntervalSince(splashStartedAt)
        let wait = force ? 0 : max(0, splashMinSeconds - elapsed)

        Task { @MainActor in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard showSplash else { return }
            withAnimation(.easeOut(duration: splashFadeSeconds)) {
                splashOpacity = 0
            }
            try? await Task.sleep(nanoseconds: UInt64(splashFadeSeconds * 1_000_000_000))
            showSplash = false
        }
    }
}
