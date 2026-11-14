import SwiftUI
import UIKit

@main
struct ProjectMurdockApp: App {
    
    @StateObject private var coordinator = MurdockCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            TacticalHUDView(coordinator: coordinator)
                .statusBar(hidden: true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    // Prevent screen sleep during sensory surveillance
                    UIApplication.shared.isIdleTimerDisabled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        coordinator.startAllEngines()
                    }
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                    coordinator.stopAllEngines()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            coordinator.startAllEngines()
                        }
                    case .background, .inactive:
                        coordinator.stopAllEngines()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
