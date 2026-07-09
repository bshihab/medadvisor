import UIKit
import UserNotifications
import FirebaseMessaging

/// MC7 client: push notifications for mentor notes.
/// Contract (PLAN.md MC7, SETTLED): register the FCM registration token via
/// POST /v1/me/push-token {token, platform:"ios"}; DELETE (token in body) on
/// sign-out; notification data carries {noteId, sessionId, orgId} for
/// deep-linking. Permission is asked IN CONTEXT (right after joining a
/// program — the moment a mentor exists who might write to you), never at
/// first launch.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    /// nil = never asked; then mirrors the system grant.
    @Published private(set) var authorized: Bool?
    /// Set when the user taps a note notification — RootView opens the notes list.
    @Published var openNotes = false

    private static let uploadedTokenKey = "pushTokenUploaded"

    private override init() { super.init() }

    /// Call once at launch: wires delegates and reads the current permission.
    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        Task { await refreshAuthorization() }
    }

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorized = nil
        case .denied:        authorized = false
        default:
            authorized = true
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// The in-context ask. Safe to call repeatedly — iOS only prompts once.
    func requestPermission() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        authorized = granted
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// After sign-in: if permission already exists, make sure the current
    /// token is registered under THIS account.
    func syncAfterSignIn() {
        guard authorized == true else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let token = Messaging.messaging().fcmToken { upload(token) }
    }

    /// Before sign-out (while the auth token still works): withdraw this
    /// device from the account's registry. Best-effort.
    func unregisterForSignOut() async {
        guard let token = UserDefaults.standard.string(forKey: Self.uploadedTokenKey) else { return }
        struct Body: Encodable { let token: String }
        struct Reply: Decodable { let ok: Bool }
        let _: Reply? = try? await AccountStore.shared.call(
            "v1/me/push-token", method: "DELETE", body: Body(token: token))
        UserDefaults.standard.removeObject(forKey: Self.uploadedTokenKey)
    }

    private func upload(_ token: String) {
        guard AccountStore.shared.isSignedIn else { return }
        struct Body: Encodable { let token: String; let platform: String }
        struct Reply: Decodable { let ok: Bool }
        Task {
            let reply: Reply? = try? await AccountStore.shared.call(
                "v1/me/push-token", method: "POST", body: Body(token: token, platform: "ios"))
            if reply?.ok == true {
                UserDefaults.standard.set(token, forKey: Self.uploadedTokenKey)
            }
        }
    }
}

extension PushManager: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in self.upload(fcmToken) }
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// Show mentor-note banners even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in await NotesStore.shared.refresh() }   // badge updates live
    }

    /// Tap → open the notes list.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let isNote = userInfo["noteId"] != nil
        Task { @MainActor in
            if isNote {
                await NotesStore.shared.refresh()
                self.openNotes = true
            }
            completionHandler()
        }
    }
}
