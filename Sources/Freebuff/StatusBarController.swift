import SwiftUI
import AppKit

/// Manages the NSStatusItem (menu bar icon) and NSPopover (dropdown panel).
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingView: NSHostingView<MenuBarIconView>!

    let viewModel: StatusViewModel

    init(viewModel: StatusViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        setupPopover()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Simple static icon — no state-dependent styling needed
        let iconView = MenuBarIconView()
        hostingView = NSHostingView(rootView: iconView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 22, height: 18)

        if let button = statusItem.button {
            button.addSubview(hostingView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Right-click now shows a context menu instead of toggling the popover.
    private func showContextMenu() {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Status", action: #selector(openPopover), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let newSessionItem = NSMenuItem(title: "New Session", action: #selector(newSession), keyEquivalent: "n")
        newSessionItem.keyEquivalentModifierMask = .command
        newSessionItem.target = self
        menu.addItem(newSessionItem)

        if viewModel.fullHistory.first(where: { $0.status == "completed" }) != nil {
            let resumeItem = NSMenuItem(title: "Resume Last Session", action: #selector(resumeLastSession), keyEquivalent: "r")
            resumeItem.keyEquivalentModifierMask = .command
            resumeItem.target = self
            menu.addItem(resumeItem)
        }

        menu.addItem(NSMenuItem.separator())

        if !viewModel.messages.isEmpty {
            let clearChatItem = NSMenuItem(title: "Clear Chat", action: #selector(clearChatFromMenu), keyEquivalent: "l")
            clearChatItem.keyEquivalentModifierMask = .command
            clearChatItem.target = self
            menu.addItem(clearChatItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Freebuff", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset so left-click goes back to toggle behavior
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }



    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 680, height: 720)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(viewModel: viewModel)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        // If right-click, show context menu
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Public method for Dock menu / external callers to show the popover.
    func showPopover() {
        openPopover()
    }

    @objc private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func newSession() {
        // Open popover, switch to Chat tab, focus input
        openPopover()
        viewModel.selectedTab = 0
        // Focus will be handled by the user pressing ⌘K or clicking
    }

    @objc private func resumeLastSession() {
        guard let last = viewModel.fullHistory.first(where: { $0.status == "completed" }) else { return }
        openPopover()
        viewModel.resumeSession(task: last.task)
    }

    @objc private func clearChatFromMenu() {
        viewModel.clearChat()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Cleanup if needed
    }

    /// Close popover when app resigns active (click outside)
    func handleAppResignActive() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
