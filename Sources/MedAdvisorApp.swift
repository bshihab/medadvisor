import SwiftUI
import UIKit
import GoogleSignIn
import FirebaseMessaging

@main
struct MedAdvisorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @ObservedObject private var push = PushManager.shared

    init() {
        AccountStore.configure()   // Firebase/Identity Platform — before any Auth use
        _ = DevLog.shared          // start capturing diagnostics from launch
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    ModelDownloader.shared.resume()
                    RubricSync.refresh()   // cloud rubrics (silent, offline-safe)
                    PushManager.shared.bootstrap()
                }
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                // Tapping a mentor-note notification lands here.
                .sheet(isPresented: $push.openNotes) {
                    NavigationStack { MentorNotesView() }
                }
        }
        // Re-drive the download whenever the app comes back — transfers only run
        // at full speed while we're active, and resume() picks up from the exact
        // byte the partial file left off at.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ModelDownloader.shared.resume()
                Task { await PrivateBackup.syncPending() }   // drain any backup backlog
            }
        }
    }
}


/// Minimal app delegate: hands the raw APNs device token to Firebase
/// Messaging (which wraps it into the FCM registration token we upload).
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] APNs registration failed: \(error.localizedDescription)")
    }
}
