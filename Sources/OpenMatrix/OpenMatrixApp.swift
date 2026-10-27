import BackgroundTasks
import SwiftUI
import UIKit

@main
struct OpenMatrixApp: App {
    @UIApplicationDelegateAdaptor(OpenMatrixAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class OpenMatrixAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: LastFMService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                LastFMBackgroundRefresh.handle(refreshTask)
            }
        }
        LastFMBackgroundRefresh.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LastFMBackgroundRefresh.schedule()
    }
}
