import SwiftUI
import UIKit

@main
struct MedAdvisorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Handles background URLSession events so the model download survives the app
/// being backgrounded or killed: on launch we re-attach to any in-flight
/// download, and when the system relaunches us to deliver a finished download we
/// hand it the completion handler.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ModelDownloader.shared.resume()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelDownloader.shared.backgroundCompletion = completionHandler
        ModelDownloader.shared.resume()
    }
}
