import SwiftUI
import AppKit
import UserNotifications

/// Entry point for the Freebuff menu bar app.
///
/// The app runs as an accessory (no Dock icon — LSUIElement in Info.plist).
/// It sets up a custom NSStatusItem with a progress ring icon and a popover panel.
@main
struct FreebuffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var viewModel: StatusViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (LSUIElement in Info.plist handles this, but belt-and-suspenders)
        NSApp.setActivationPolicy(.accessory)

        // Request notification permission
        requestNotificationPermission()

        let vm = StatusViewModel()
        self.viewModel = vm
        vm.startWatching()

        statusBarController = StatusBarController(viewModel: vm)

        // Register for login items on first launch
        vm.registerLoginItem()

        // Listen for app resign active to close popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stopWatching()
    }

    @objc private func appDidResignActive() {
        statusBarController?.handleAppResignActive()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[Freebuff] Notification permission error: \(error.localizedDescription)")
            }
            if granted {
                print("[Freebuff] Notification permission granted")
            }
        }
    }
}
