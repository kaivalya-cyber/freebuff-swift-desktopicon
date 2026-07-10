import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: StatusViewModel
    @FocusState private var isInputFocused: Bool
    @State private var expandedDays: Set<String> = []
    @State private var showCheatsheet = false
    @State private var showClearConfirm = false
    @State private var showCopyAllConfirm = false
    @State private var sparklineAnimProgress: Double = 0
    @State private var showCSVExportConfirm = false
    @State private var hoveredSparklineIndex: Int? = nil
    @State private var isDropTargeted: Bool = false
    @State private var deleteConfirmEntry: HistoryEntry? = nil
    @State private var showResetStatsConfirm = false
    @State private var showResetAllConfirm = false
    @State private var onboardingStep: Int = 0
    @State private var onboardingAnimsActive: Bool = false
    @State private var getStartedPulse: Bool = false
    @State private var checkmarkSpring: Bool = false
    @State private var cardEntrance: Bool = false
    @State private var spotlightFlash: Bool = false
    @State private var stepLabelBounce: Bool = false
    @State private var bodyTextPulse: Bool = false
    @State private var completeSparkles: Bool = false

    /// Current app version for Settings display
    private var appVersion: String { viewModel.currentAppVersion }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerSection.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                Divider().padding(.horizontal, 14)
                tabPicker.padding(.horizontal, 14).padding(.vertical, 6)
                Divider().padding(.horizontal, 14)
                if viewModel.selectedTab == 0 { chatContent } else if viewModel.selectedTab == 1 { statsContent } else { historyTabContent }
            }
            .frame(width: 680)
            .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
            .blur(radius: viewModel.showOnboarding ? 2.5 : 0)
            .animation(.easeInOut(duration: 0.3), value: viewModel.showOnboarding)
                        .onAppear { viewModel.applyTheme() }
            .onChange(of: viewModel.showOnboarding) { showing in if showing { onboardingStep = 0; onboardingAnimsActive = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { cardEntrance = true } } else { onboardingAnimsActive = false; getStartedPulse = false; checkmarkSpring = false; cardEntrance = false; completeSparkles = false } }
            .onChange(of: onboardingStep) { step in getStartedPulse = step == onboardingSteps.count - 1; if step == onboardingSteps.count - 1 { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { checkmarkSpring = true } } else { checkmarkSpring = false }; spotlightFlash = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { spotlightFlash = false }; stepLabelBounce = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { stepLabelBounce = false }; bodyTextPulse = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { bodyTextPulse = false } }

            // Keyboard shortcuts (invisible buttons)
            Button("") { isInputFocused = true }.keyboardShortcut("k", modifiers: .command).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            Button("") { if !isInputFocused { showCheatsheet.toggle() } }.keyboardShortcut("/", modifiers: .command).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            Button("") { showCheatsheet = false; viewModel.showSettings = false; viewModel.showOnboarding = false; onboardingStep = 0; showClearConfirm = false; showCopyAllConfirm = false; showResetStatsConfirm = false; showResetAllConfirm = false; deleteConfirmEntry = nil }.keyboardShortcut(.escape).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            Button("") { if !isInputFocused { viewModel.undoRestore(); isInputFocused = true } }.keyboardShortcut("z", modifiers: .command).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            Button("") { viewModel.clearChat() }.keyboardShortcut("l", modifiers: .command).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            Button("") { if let last = viewModel.fullHistory.first(where: { $0.status == "completed" }) { viewModel.resumeSession(task: last.task); isInputFocused = true } }.keyboardShortcut("r", modifiers: .command).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            // Arrow key navigation for onboarding (only active during tour)
            if viewModel.showOnboarding {
                Button("") { navigateOnboarding(by: -1) }.keyboardShortcut(.leftArrow).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
                Button("") { navigateOnboarding(by: 1) }.keyboardShortcut(.rightArrow).frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
            }

            if viewModel.showSettings { settingsOverlay }
            if showCheatsheet { cheatsheetOverlay }
            if showClearConfirm { confirmationDialog(title: "Clear chat?", message: "This will remove all messages and cannot be undone.", confirm: { viewModel.clearChat(); showClearConfirm = false }, cancel: { showClearConfirm = false }) }
            if showCopyAllConfirm { confirmationDialog(title: "Copy all?", message: "Copy the entire conversation as formatted text to clipboard.", confirm: { copyAllConversation(); showCopyAllConfirm = false }, cancel: { showCopyAllConfirm = false }) }
            if showCSVExportConfirm { confirmationDialog(title: "Export CSV?", message: "Save last 7 days of usage data as a CSV file.", confirm: { exportCSV(); showCSVExportConfirm = false }, cancel: { showCSVExportConfirm = false }) }
            if let entry = deleteConfirmEntry { confirmationDialog(title: "Delete session?", message: "Remove '\(entry.task)' from history? This cannot be undone.", confirm: { viewModel.deleteHistoryEntry(id: entry.id); deleteConfirmEntry = nil }, cancel: { deleteConfirmEntry = nil }) }
            if showResetStatsConfirm { confirmationDialog(title: "Reset stats?", message: "This will wipe all usage data (prompts, responses, sessions, context fill). This cannot be undone.", confirm: { viewModel.resetUsageStats(); showResetStatsConfirm = false }, cancel: { showResetStatsConfirm = false }) }
            if showResetAllConfirm { confirmationDialog(title: "Reset all data?", message: "This will wipe all history, usage stats, and current session data. This cannot be undone.", confirm: { viewModel.resetAllData(); showResetAllConfirm = false }, cancel: { showResetAllConfirm = false }) }
            if viewModel.showOnboarding { onboardingOverlay }
            if viewModel.showChangelog { changelogOverlay }
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("View", selection: Binding(get: { viewModel.selectedTab }, set: { viewModel.selectedTab = $0 })) {
            Text("Chat").tag(0); Text("Stats").tag(1); Text("History").tag(2)
        }.pickerStyle(.segmented)
    }

    // MARK: - Chat content

    @ViewBuilder
    private var chatContent: some View {
        VStack(spacing: 0) {
            if viewModel.showCompletionBanner { completionBanner }
            ZStack {
                chatSection
                if isDropTargeted { dropZoneOverlay }
            }
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            if !viewModel.messages.isEmpty {
                HStack {
                    Text("Drop files to add paths · ⌘K focus · ⌘/ shortcuts").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                    Button { showCopyAllConfirm = true } label: {
                        HStack(spacing: 3) { Image(systemName: "doc.on.doc").font(.system(size: 9)); Text("Copy all").font(.system(size: 10)) }.foregroundColor(.secondary)
                    }.buttonStyle(.plain).padding(.trailing, 8)
                    Button { showClearConfirm = true } label: {
                        HStack(spacing: 3) { Image(systemName: "trash").font(.system(size: 9)); Text("Clear").font(.system(size: 10)) }.foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.top, 4)
            }
            Divider().padding(.horizontal, 14)
            inputSection.padding(.horizontal, 14).padding(.vertical, 8)
            Divider().padding(.horizontal, 14)
            historySection.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        }
    }

    private var dropZoneOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
            VStack(spacing: 4) {
                Image(systemName: "plus.rectangle.on.folder").font(.system(size: 20)).foregroundColor(.blue.opacity(0.7))
                Text("Drop files to add paths").font(.system(size: 11, weight: .medium)).foregroundColor(.blue.opacity(0.7))
            }
        }
        .padding(12)
    }

    private func copyAllConversation() {
        let text = viewModel.messages.map { msg in
            let prefix = msg.role == "user" ? "You" : "Agent"
            return "\(prefix) [\(msg.timeLabel)]:\n\(msg.content)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Completion banner

    private var completionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(.green)
            Text("Session Complete!").font(.system(size: 11, weight: .semibold))
            Text("·").foregroundColor(.secondary)
            Text(viewModel.completionTaskName).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.2)) { viewModel.showCompletionBanner = false } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(.secondary.opacity(0.6))
            }.buttonStyle(.plain)
        }.padding(.horizontal, 14).padding(.vertical, 8)
        .background(Rectangle().fill(Color.green.opacity(0.08)).overlay(alignment: .bottom) { Divider() })
    }

    // MARK: - Settings overlay

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { viewModel.showSettings = false } }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundColor(.secondary)
                    Text("Settings").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { viewModel.showSettings = false } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.6))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 16).padding(.vertical, 12)

                Divider()

                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("API cost per prompt").font(.system(size: 11)).foregroundColor(.secondary); Spacer(); Text(String(format: "$%.4f", viewModel.costPerPrompt)).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                        Slider(value: $viewModel.costPerPrompt, in: 0.0001...0.01, step: 0.0001).onChange(of: viewModel.costPerPrompt) { _ in viewModel.saveSettings() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Context window").font(.system(size: 11)).foregroundColor(.secondary); Spacer(); Text("\(viewModel.contextWindowTokens / 1000)K tokens").font(.system(size: 11, weight: .semibold)) }
                        Slider(value: Binding(get: { Double(viewModel.contextWindowTokens) }, set: { viewModel.contextWindowTokens = Int($0) }), in: 32000...256000, step: 32000).onChange(of: viewModel.contextWindowTokens) { _ in viewModel.saveSettings() }
                    }
                    HStack {
                        Text("Compact Stats by default").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                        Toggle("", isOn: $viewModel.compactDefault).toggleStyle(.switch).onChange(of: viewModel.compactDefault) { _ in viewModel.saveSettings() }
                    }
                    HStack {
                        Text("Appearance").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                        Picker("", selection: Binding(get: { viewModel.overrideTheme ?? "system" }, set: { viewModel.overrideTheme = $0 == "system" ? nil : $0; viewModel.applyTheme(); viewModel.saveSettings() })) {
                            Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                        }.pickerStyle(.segmented).frame(width: 140)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        HStack {
                            Text("Session complete").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                            Toggle("", isOn: $viewModel.notificationsEnabled).toggleStyle(.switch).onChange(of: viewModel.notificationsEnabled) { _ in viewModel.saveSettings() }
                        }
                        HStack {
                            Text("Weekly summary").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                            Toggle("", isOn: $viewModel.weeklySummaryEnabled).toggleStyle(.switch).onChange(of: viewModel.weeklySummaryEnabled) { _ in viewModel.saveSettings(); viewModel.scheduleWeeklySummary() }
                        }
                        HStack {
                            Text("Sound").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                            Picker("", selection: $viewModel.notificationSound) {
                                Text("Default").tag("default"); Text("None").tag("")
                            }.pickerStyle(.segmented).frame(width: 110).disabled(!viewModel.notificationsEnabled).onChange(of: viewModel.notificationSound) { _ in viewModel.saveSettings() }
                        }
                    }

                    Divider()

                    Button { showResetStatsConfirm = true } label: {
                        HStack(spacing: 4) { Image(systemName: "trash").font(.system(size: 10)); Text("Reset usage stats").font(.system(size: 11)) }
                            .foregroundColor(.red.opacity(0.7)).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                    }.buttonStyle(.plain)

                    Button { showResetAllConfirm = true } label: {
                        HStack(spacing: 4) { Image(systemName: "trash.fill").font(.system(size: 10)); Text("Reset all data").font(.system(size: 11)) }
                            .foregroundColor(.red).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
                    }.buttonStyle(.plain)

                    Button { viewModel.resetSettings() } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)); Text("Reset to defaults").font(.system(size: 11)) }
                            .foregroundColor(.secondary).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }.buttonStyle(.plain)

                    Divider()

                    Button {
                        viewModel.showSettings = false
                        viewModel.showOnboarding = true
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "questionmark.circle").font(.system(size: 10)); Text("Replay guided tour").font(.system(size: 11)) }
                            .foregroundColor(.blue.opacity(0.8)).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
                    }.buttonStyle(.plain)

                    Button {
                        viewModel.showSettings = false
                        viewModel.showChangelog = true
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "sparkles").font(.system(size: 10)); Text("What's New").font(.system(size: 11)) }
                            .foregroundColor(.purple.opacity(0.8)).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
                    }.buttonStyle(.plain)
                }.padding(16)

                // Version footer
                Text("Freebuff \(appVersion)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.3))
                    .padding(.bottom, 10)
            }
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.2), radius: 12, y: 2))
        }
    }

    // MARK: - Onboarding overlay (guided tour)

    private let onboardingSteps: [(icon: String, title: String, body: String, spot: Int)] = [
        // spot: 0=center, 1=header, 2=input, 3=tabs
        ("cpu.fill", "Welcome to Freebuff", "Your AI coding companion lives in the menu bar. Let's take a quick tour.\n\nClick Next to get started — or Skip to jump right in.\n\n← → arrow keys or Esc to skip.", 0),
        ("eye.fill", "Monitor Your Agents", "When a Codebuff agent is running, the header turns green with live progress, elapsed time, and estimated completion.\n\nYou'll see your task name and a progress bar update in real-time.\n\n⌘/ to view all shortcuts anytime.", 1),
        ("bubble.left.and.bubble.right.fill", "Chat & Prompt", "The Chat tab lets you send prompts to Codebuff. Agents respond inline — just type or drop file paths.\n\n⌘K to focus, ⌘R to resume, ⌘L to clear.", 2),
        ("chart.bar.fill", "Stats & History", "Track your usage across the Stats tab — sessions, credits, context fill, and a 7-day sparkline.\n\nThe History tab saves every completed session so you can resume, review diffs, and measure productivity.\n\n⌘K to focus chat, ⌘/ for all shortcuts.", 3)
    ]

    private var onboardingOverlay: some View {
        let spot = onboardingSteps[onboardingStep].spot
        let borderGradient = LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack(alignment: spot == 1 || spot == 3 ? .top : spot == 2 ? .bottom : .center) {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { viewModel.showOnboarding = false } }

            // Vignette gradient to focus attention on the card
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.25)],
                center: .center,
                startRadius: 160,
                endRadius: 400
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Spotlight flash on step change
            RoundedRectangle(cornerRadius: spot == 3 ? 8 : 10)
                .fill(Color.white)
                .frame(width: 656, height: spot == 1 ? 78 : spot == 2 ? 42 : spot == 3 ? 34 : 0)
                .padding(spot == 1 ? .top : spot == 2 ? .bottom : .top, spot == 1 ? 8 : spot == 2 ? 4 : spot == 3 ? 20 : 0)
                .opacity(spotlightFlash && spot != 0 ? 0.10 : 0)
                .animation(.easeOut(duration: 0.15), value: spotlightFlash)

            // Spotlight border rendered ABOVE the dark overlay (pulsing glow)
            if spot == 1 {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderGradient, lineWidth: 2)
                    .frame(width: 656, height: 78)
                    .padding(.top, 8)
                    .opacity(onboardingAnimsActive ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: onboardingAnimsActive)
            } else if spot == 2 {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderGradient, lineWidth: 2)
                    .frame(width: 656, height: 42)
                    .padding(.bottom, 4)
                    .opacity(onboardingAnimsActive ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: onboardingAnimsActive)
            } else if spot == 3 {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderGradient, lineWidth: 2)
                    .frame(width: 656, height: 34)
                    .padding(.top, 20)
                    .opacity(onboardingAnimsActive ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: onboardingAnimsActive)
            }

            VStack(spacing: 0) {
                // Hero icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(onboardingAnimsActive ? 4 : -4))
                        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: onboardingAnimsActive)
                    Image(systemName: onboardingSteps[onboardingStep].icon)
                        .font(.system(size: onboardingStep == 0 ? 24 : 22))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(onboardingAnimsActive ? -4 : 4))
                        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: onboardingAnimsActive)
                }
                .scaleEffect(onboardingAnimsActive ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: onboardingAnimsActive)
                .padding(.top, 24)

                Text(onboardingSteps[onboardingStep].title)
                    .font(.system(size: 17, weight: .bold))
                    .padding(.top, 12)

                Text(onboardingSteps[onboardingStep].body)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary.opacity(bodyTextPulse ? 1.0 : 0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .animation(.easeOut(duration: 0.25), value: bodyTextPulse)

                // Step progress indicator
                Text("Step \(onboardingStep + 1) of \(onboardingSteps.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(stepLabelBounce ? 0.8 : 0.5))
                    .scaleEffect(stepLabelBounce ? 1.15 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: stepLabelBounce)
                    .padding(.top, 14)

                // Step dots
                HStack(spacing: 6) {
                    ForEach(0..<onboardingSteps.count, id: \.self) { i in
                        Circle()
                            .fill(i <= onboardingStep ? Color.blue.opacity(i == onboardingStep ? 1.0 : 0.55) : Color.secondary.opacity(0.25))
                            .frame(width: 6, height: 6)
                            .scaleEffect(i == onboardingStep ? 1.3 : 1.0)
                            .shadow(color: i == onboardingStep ? Color.blue.opacity(0.5) : .clear, radius: i == onboardingStep ? 4 : 0)
                            .animation(.easeInOut(duration: 0.3), value: onboardingStep)
                            .help(onboardingSteps[i].title)
                    }
                }
                .padding(.top, 12)

                // Arrow key hint
                Text("← → arrow keys to navigate")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.4))
                    .padding(.top, 4)
                Text("⌘K focus · ⌘R resume · ⌘L clear · ⌘/ shortcuts")
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary.opacity(0.3))
                    .padding(.top, 1)

                // Navigation
                HStack(spacing: 0) {
                    if onboardingStep > 0 {
                        Button {
                            navigateOnboarding(by: -1)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                                Text("Back").font(.system(size: 12))
                            }
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { viewModel.showOnboarding = false }
                        } label: {
                            Text("Skip").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.3))
                        }.buttonStyle(.plain).padding(.horizontal, 8)
                        Spacer()
                    } else {
                        Button {
                            NSSound(named: "Pop")?.play()
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.showOnboarding = false
                            }
                        } label: {
                            Text("Skip")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.vertical, 8).padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    Button {
                        if onboardingStep == onboardingSteps.count - 1 { completeSparkles = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { completeSparkles = false } }
                        navigateOnboarding(by: 1)
                    } label: {
                        HStack(spacing: 3) {
                            Text(onboardingStep == onboardingSteps.count - 1 ? "Get Started" : "Next")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: onboardingStep == onboardingSteps.count - 1 ? "checkmark" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .scaleEffect(onboardingStep == onboardingSteps.count - 1 ? (checkmarkSpring ? 1.0 : 0.01) : 1.0)
                                .animation(onboardingStep == onboardingSteps.count - 1 ? .spring(response: 0.4, dampingFraction: 0.6) : .default, value: checkmarkSpring)
                                .offset(x: onboardingStep < onboardingSteps.count - 1 && onboardingAnimsActive ? 3 : 0)
                                .animation(onboardingStep < onboardingSteps.count - 1 ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: onboardingAnimsActive)
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 8).padding(.horizontal, 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)))
                        .scaleEffect(onboardingStep == onboardingSteps.count - 1 && getStartedPulse ? 1.06 : 1.0)
                        .shadow(color: onboardingStep == onboardingSteps.count - 1 && getStartedPulse ? Color.purple.opacity(0.5) : .clear, radius: onboardingStep == onboardingSteps.count - 1 && getStartedPulse ? 8 : 0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: getStartedPulse)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
            }
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.3), radius: 24, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .opacity(onboardingAnimsActive ? 0.5 : 0.1)
                .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: onboardingAnimsActive)
            )
            .overlay(alignment: spot == 1 || spot == 3 ? .top : .bottom) {
                if spot == 1 || spot == 2 || spot == 3 {
                    pointerArrow(direction: spot == 2 ? .down : .up)
                        .offset(y: spot == 2 ? 8 : -8)
                }
            }
            // Swipe hint chevrons at card edges
            .overlay(alignment: .leading) {
                if onboardingStep > 0 {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .light))
                        .foregroundColor(.secondary.opacity(0.15))
                        .padding(.leading, 6)
                }
            }
            .overlay(alignment: .trailing) {
                if onboardingStep < onboardingSteps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .light))
                        .foregroundColor(.secondary.opacity(0.15))
                        .padding(.trailing, 6)
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .scaleEffect(cardEntrance ? 1.0 : 0.92)
            .opacity(cardEntrance ? 1.0 : 0.0)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: cardEntrance)
            .id(onboardingStep)
            .padding(spot == 1 || spot == 3 ? .top : spot == 2 ? .bottom : [], spot == 1 || spot == 2 || spot == 3 ? 20 : 0)
            // Sparkle burst on completion
            .overlay {
                if completeSparkles {
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            let angle = Double(i) / 8 * .pi * 2
                            let dx = cos(angle) * 60
                            let dy = sin(angle) * 60
                            Circle()
                                .fill([Color.blue, .purple, .pink, .cyan][i % 4].opacity(0.6))
                                .frame(width: 5, height: 5)
                                .offset(x: completeSparkles ? dx : 0, y: completeSparkles ? dy : 0)
                                .opacity(completeSparkles ? 0 : 1)
                                .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(Double(i) * 0.03), value: completeSparkles)
                        }
                    }
                }
            }
            .gesture(DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        if value.translation.width < -30 {
                            navigateOnboarding(by: 1)
                        } else if value.translation.width > 30 && onboardingStep > 0 {
                            navigateOnboarding(by: -1)
                        }
                    }
                }
            )
        }
    }

    // MARK: - Cheatsheet overlay

    private var cheatsheetOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showCheatsheet = false } }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "keyboard.fill").font(.system(size: 13)).foregroundColor(.secondary)
                    Text("Keyboard Shortcuts").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.15)) { showCheatsheet = false } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.6))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 16).padding(.vertical, 12)

                Divider()

                VStack(spacing: 10) {
                    shortcutRow(keys: "⌘K", description: "Focus chat input")
                    shortcutRow(keys: "⌘R", description: "Resume last session")
                    shortcutRow(keys: "⌘L", description: "Clear chat")
                    shortcutRow(keys: "⌘Z", description: "Restore last sent message")
                    shortcutRow(keys: "← →", description: "Navigate onboarding tour")
                    shortcutRow(keys: "⌘/", description: "Show this cheatsheet")
                    shortcutRow(keys: "⌘Return", description: "Submit prompt")
                    shortcutRow(keys: "Esc", description: "Close popover / dismiss overlay")
                }.padding(16)
            }
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.2), radius: 12, y: 2))
        }
    }

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack {
            Text(keys).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.primary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Changelog overlay

    private let changelogItems: [(version: String, date: String, changes: [String])] = [
        ("v1.1", "July 2026", [
            "Guided onboarding tour with spotlight callouts and pointer arrows",
            "Replay tour anytime from Settings",
            "Click-to-dismiss or arrow key navigation in the tour"
        ]),
        ("v1.0", "July 2026", [
            "Guided onboarding tour with spotlight callouts",
            "Live session monitoring with progress tracking",
            "Chat tab for sending prompts to Codebuff agents",
            "Stats dashboard with usage metrics and sparkline",
            "Full session history with search and filters",
            "Right-click context menu with quick actions",
            "Keyboard shortcuts for power users (⌘K ⌘R ⌘L ⌘Z ⌘/)",
            "Dark/light theme toggle",
            "Weekly summary notifications",
            "Auto-complete for stale sessions"
        ])
    ]

    private var changelogOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { viewModel.dismissChangelog() } }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundColor(.blue)
                    Text("What's New").font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { viewModel.dismissChangelog() } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.6))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 20).padding(.vertical, 16)

                Divider().padding(.horizontal, 20)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(changelogItems, id: \.version) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Text(item.version)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)))
                                    Text(item.date)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(item.changes, id: \.self) { change in
                                        HStack(alignment: .top, spacing: 6) {
                                            Circle().fill(Color.blue.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 5)
                                            Text(change).font(.system(size: 11)).foregroundColor(.primary.opacity(0.85))
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(20)
                }.frame(maxHeight: 300)

                Divider().padding(.horizontal, 20)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.dismissChangelog() }
                } label: {
                    Text("Got it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.vertical, 8).padding(.horizontal, 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 14)
            }
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.25), radius: 20, y: 4))
        }
    }

    // MARK: - Onboarding navigation helper

    private func navigateOnboarding(by delta: Int) {
        let next = onboardingStep + delta
        if next < 0 && delta < 0 { return }
        NSSound(named: "Pop")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.easeInOut(duration: 0.2)) {
            if next >= 0 && next < onboardingSteps.count {
                onboardingStep = next
            } else if delta > 0 {
                viewModel.completeOnboarding()
            }
        }
    }

    // MARK: - Pointer arrow for onboarding spotlight

    private enum ArrowDirection { case up, down }

    private func pointerArrow(direction: ArrowDirection) -> some View {
        Path { p in
            let w: CGFloat = 16, h: CGFloat = 8
            if direction == .up {
                p.move(to: CGPoint(x: w / 2, y: 0))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
            } else {
                p.move(to: CGPoint(x: w / 2, y: h))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 0))
            }
            p.closeSubpath()
        }
        .fill(Color(nsColor: .windowBackgroundColor))
        .frame(width: 16, height: 8)
    }

    // MARK: - Confirmation dialog

    private func confirmationDialog(title: String, message: String, confirm: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { cancel() }
            VStack(spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.top, 16).padding(.bottom, 4)
                Text(message).font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16).padding(.bottom, 16)
                Divider()
                HStack(spacing: 0) {
                    Button { cancel() } label: { Text("Cancel").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.plain)
                    Divider()
                    Button { confirm() } label: { Text(verbatim: title.hasPrefix("Clear") ? "Clear" : title.hasPrefix("Delete") ? "Delete" : title.hasPrefix("Export") ? "Export" : title.hasPrefix("Reset") ? "Reset" : "Copy").font(.system(size: 12, weight: .semibold)).foregroundColor(title.hasPrefix("Clear") || title.hasPrefix("Delete") || title.hasPrefix("Reset") ? .red : .blue).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.plain)
                }
            }
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.2), radius: 12, y: 2))
        }
    }

    // MARK: - Stats content

    @ViewBuilder
    private var statsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { viewModel.compactMode.toggle() } } label: {
                    HStack(spacing: 4) { Image(systemName: viewModel.compactMode ? "rectangle.expand.vertical" : "rectangle.compress.vertical").font(.system(size: 9)); Text(viewModel.compactMode ? "Expand" : "Compact").font(.system(size: 10)) }
                        .foregroundColor(.secondary).padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 14).padding(.top, 6)
            if viewModel.compactMode { compactStatsView } else { sideBySideStatsView }
        }
    }

    private var compactStatsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) { sparklineCard; statsCardsView; forceRecomputeButton; exportCSVButton; dailyBreakdownView }.padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var sideBySideStatsView: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) { statsCardsView; forceRecomputeButton; exportCSVButton }.frame(width: 290)
            ScrollView(.vertical, showsIndicators: false) { VStack(spacing: 10) { sparklineCard; dailyBreakdownView } }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statsCardsView: some View {
        Group {
            statsCard(icon: "clock.arrow.2.circlepath", iconColor: .blue, title: "Total Session Usage") {
                statsRow(label: "Sessions", value: "\(viewModel.usageStats.totalSessions)"); statsRow(label: "Total time", value: viewModel.liveTotalTimeString); statsRow(label: "Today", value: "\(viewModel.usageStats.todaySessions) sessions")
            }
            statsCard(icon: "flame.fill", iconColor: .orange, title: "API Credits Burnt") {
                statsRow(label: "Estimated cost", value: viewModel.liveCreditsString); statsRow(label: "This month", value: viewModel.usageStats.thisMonthCreditsString); statsRow(label: "Prompts", value: "\(viewModel.usageStats.totalPrompts)"); statsRow(label: "Responses", value: "\(viewModel.usageStats.totalResponses)"); statsRow(label: "Today", value: "\(viewModel.usageStats.todayPrompts) prompts")
            }
            statsCard(icon: "rectangle.stack.fill", iconColor: .purple, title: "Context Filled Up") { contextFillContent }
        }
    }

    private var contextFillContent: some View {
        let window = viewModel.contextWindowTokens; let fillPct = viewModel.liveContextFillPercent
        return VStack(alignment: .leading, spacing: 6) {
            HStack { Text(fillPct < 1 ? "<1%" : String(format: "%.0f%%", fillPct)).font(.system(size: 15, weight: .bold)); Text("of \(window / 1000)K").font(.system(size: 11)).foregroundColor(.secondary) }
            GeometryReader { geo in ZStack(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 10); RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: contextFillGradient, startPoint: .leading, endPoint: .trailing)).frame(width: max(6, geo.size.width * CGFloat(fillPct / 100.0)), height: 10).animation(.easeInOut(duration: 0.5), value: fillPct) } }.frame(height: 10)
            Text("~\(viewModel.usageStats.estimatedTokens) tokens").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var forceRecomputeButton: some View {
        Button { viewModel.forceRecomputeFromHistory() } label: {
            HStack(spacing: 4) { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .semibold)); Text("Recompute from history").font(.system(size: 10, weight: .medium)) }
                .foregroundColor(.secondary).padding(.vertical, 6).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }.buttonStyle(.plain)
    }

    private var exportCSVButton: some View {
        Button { showCSVExportConfirm = true } label: {
            HStack(spacing: 4) { Image(systemName: "square.and.arrow.up").font(.system(size: 9, weight: .semibold)); Text("Export CSV").font(.system(size: 10, weight: .medium)) }
                .foregroundColor(.secondary).padding(.vertical, 6).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }.buttonStyle(.plain)
    }

    private func exportCSV() {
        let csv = viewModel.exportUsageCSV()
        let savePanel = NSSavePanel()
        savePanel.title = "Export Usage Data"
        savePanel.nameFieldStringValue = "freebuff_usage_\(formattedDateForFile()).csv"
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func formattedDateForFile() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: - Sparkline

    private var sparklineCard: some View {
        let days = viewModel.usageStats.last7Days; let maxVal = max(days.map { $0.usage.prompts }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 11, weight: .semibold)).foregroundColor(.green).frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.12))); Text("7-Day Activity").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary); Spacer(); Text("\(viewModel.usageStats.totalPrompts) total").font(.system(size: 10)).foregroundColor(.secondary) }
            ZStack {
                GeometryReader { geo in let w = geo.size.width; let h = geo.size.height - 4
                    ZStack(alignment: .bottomLeading) {
                        areaPath(days: days, maxVal: maxVal, w: w, h: h)
                            .trim(from: 0, to: sparklineAnimProgress)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        linePath(days: days, maxVal: maxVal, w: w, h: h)
                            .trim(from: 0, to: sparklineAnimProgress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        // Invisible hover targets at each data point
                        ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                            let x = days.count > 1 ? CGFloat(i) * (w / CGFloat(days.count - 1)) : w / 2
                            let y = h - (CGFloat(d.usage.prompts) / CGFloat(maxVal)) * h
                            Circle().fill(Color.clear).frame(width: 20, height: 20)
                                .position(x: x, y: y)
                                .onHover { inside in hoveredSparklineIndex = inside ? i : nil }
                        }
                        // Tooltip popup positioned near the hovered data point
                        if let idx = hoveredSparklineIndex, idx < days.count {
                            let d = days[idx]
                            let pointY = h - (CGFloat(d.usage.prompts) / CGFloat(maxVal)) * h
                            tooltipPopup(day: d, dateIndex: idx)
                                .position(x: min(max(40, w * CGFloat(idx) / CGFloat(max(days.count - 1, 1))), w - 40), y: max(12, pointY - 30))
                                .transition(.opacity.combined(with: .scale(scale: 0.9))).animation(.easeInOut(duration: 0.15), value: hoveredSparklineIndex)
                        }
                    }
                    .onAppear { animateSparkline() }
                    .onChange(of: days.map { $0.usage.prompts }) { _ in animateSparkline() }
                }.frame(height: 80)
            }
            HStack(spacing: 0) { ForEach(days, id: \.date) { d in Text(UsageStats.shortDayLabel(for: d.date)).font(.system(size: 9)).foregroundColor(.secondary).frame(maxWidth: .infinity) } }
        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func tooltipPopup(day: (date: String, usage: DailyUsage), dateIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dayLabel(for: day.date)).font(.system(size: 10, weight: .semibold))
            HStack(spacing: 6) {
                Text("\(day.usage.prompts) prompts").font(.system(size: 9)).foregroundColor(.secondary)
                Text("\(day.usage.responses) responses").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Text("\(day.usage.sessions) session\(day.usage.sessions == 1 ? "" : "s")").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 4, y: 1))
    }

    private func animateSparkline() {
        sparklineAnimProgress = 0
        withAnimation(.easeInOut(duration: 0.8)) { sparklineAnimProgress = 1 }
    }

    private func areaPath(days: [(date: String, usage: DailyUsage)], maxVal: Int, w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            guard days.count > 1 else { return }
            let s = w / CGFloat(days.count - 1)
            p.move(to: CGPoint(x: 0, y: h))
            for (i, d) in days.enumerated() { p.addLine(to: CGPoint(x: CGFloat(i) * s, y: h - (CGFloat(d.usage.prompts) / CGFloat(maxVal)) * h)) }
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        }
    }

    private func linePath(days: [(date: String, usage: DailyUsage)], maxVal: Int, w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            guard days.count > 1 else { return }
            let s = w / CGFloat(days.count - 1)
            p.move(to: CGPoint(x: 0, y: h - (CGFloat(days[0].usage.prompts) / CGFloat(maxVal)) * h))
            for (i, d) in days.enumerated() { p.addLine(to: CGPoint(x: CGFloat(i) * s, y: h - (CGFloat(d.usage.prompts) / CGFloat(maxVal)) * h)) }
        }
    }

    // MARK: - Daily breakdown

    @ViewBuilder private var dailyBreakdownView: some View {
        let days = viewModel.usageStats.last7Days.filter { $0.usage.prompts > 0 || $0.usage.responses > 0 || $0.usage.sessions > 0 }
        if !days.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Daily Breakdown").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).padding(.bottom, 2); ForEach(days, id: \.date) { dayBreakdownRow(date: $0, usage: $1) } } }
    }

    private func dayBreakdownRow(date: String, usage: DailyUsage) -> some View {
        let isExpanded = expandedDays.contains(date)
        return VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { if isExpanded { expandedDays.remove(date) } else { expandedDays.insert(date) } } } label: {
                HStack(spacing: 4) { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary); Text(dayLabel(for: date)).font(.system(size: 11, weight: .medium)); Spacer(); Text("\(usage.prompts)p / \(usage.responses)r").font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit() }.padding(.vertical, 5).padding(.horizontal, 8).background(RoundedRectangle(cornerRadius: 6).fill(isExpanded ? Color.primary.opacity(0.05) : Color.clear))
            }.buttonStyle(.plain)
            if isExpanded { HStack(spacing: 16) { statColumn(label: "Prompts", value: "\(usage.prompts)"); statColumn(label: "Responses", value: "\(usage.responses)"); statColumn(label: "Sessions", value: "\(usage.sessions)"); statColumn(label: "Tokens", value: "\((usage.promptChars + usage.responseChars) / 4)") }.padding(.horizontal, 12).padding(.bottom, 6) }
        }
    }

    private func statColumn(label: String, value: String) -> some View { VStack(alignment: .leading, spacing: 2) { Text(label).font(.system(size: 9)).foregroundColor(.secondary); Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary).monospacedDigit() } }
    private func dayLabel(for dateKey: String) -> String {
        guard let date = UsageStats.dateKeyFormatter.date(from: dateKey) else { return dateKey }
        if Calendar.current.isDateInToday(date) { return "Today" }; if Calendar.current.isDateInYesterday(date) { return "Yesterday" }; return UsageStats.weekdayFormatter.string(from: date)
    }
    private var contextFillGradient: [Color] { let pct = viewModel.liveContextFillPercent; if pct < 50 { return [.green, .green.opacity(0.7)] } else if pct < 80 { return [.yellow, .orange] } else { return [.orange, .red] } }
    private func statsCard<Content: View>(icon: String, iconColor: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(iconColor).frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(iconColor.opacity(0.12))); Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary) }; VStack(spacing: 4) { content() } }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
    private func statsRow(label: String, value: String) -> some View { HStack { Text(label).font(.system(size: 11)).foregroundColor(.secondary); Spacer(); Text(value).font(.system(size: 11, weight: .semibold)).foregroundColor(.primary).monospacedDigit() } }

    // MARK: - Header

    @ViewBuilder private var headerSection: some View {
        HStack(alignment: .top) { if let status = viewModel.currentStatus, viewModel.isActive { activeHeader(status: status) } else { idleHeader }; Spacer(); Button { let next: String? = viewModel.overrideTheme == "dark" ? "light" : viewModel.overrideTheme == "light" ? nil : "dark"; viewModel.overrideTheme = next; viewModel.applyTheme(); viewModel.saveSettings() } label: { Image(systemName: viewModel.overrideTheme == "dark" ? "moon.fill" : viewModel.overrideTheme == "light" ? "sun.max.fill" : "circle.lefthalf.filled").font(.system(size: 13)).foregroundColor(.secondary.opacity(0.5)) }.buttonStyle(.plain).help("Toggle theme").padding(.top, 2).padding(.trailing, 2); Button { withAnimation(.easeInOut(duration: 0.2)) { viewModel.showSettings = true } } label: { Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundColor(.secondary.opacity(0.5)) }.buttonStyle(.plain).padding(.top, 2) }
    }
    private func activeHeader(status: StatusData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { Circle().fill(Color.green).frame(width: 7, height: 7).overlay(Circle().fill(Color.green.opacity(0.4)).frame(width: 11, height: 11)); Text(viewModel.statusText).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary); if let startDate = status.startedDate { Text("since \(timeFormatter.string(from: startDate))").font(.system(size: 10)).foregroundColor(.secondary) } }; Text(status.task).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundColor(.primary); AnimatedProgressBar(progress: viewModel.animatedProgress).frame(height: 4)
            HStack { Text(viewModel.elapsedString).font(.system(size: 11)).foregroundColor(.secondary); Text("·").foregroundColor(.secondary); Text(viewModel.remainingString).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary) }
        }
    }
    private var idleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7); Text(viewModel.statusText == "Done" ? "Done" : "Idle").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary) }
            if viewModel.statusText == "Done" {
                Text(viewModel.currentStatus?.task ?? "Task completed").font(.system(size: 13, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
            } else if let last = viewModel.fullHistory.first(where: { $0.status == "completed" }) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No active session").font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                        Text("Waiting for agent to start…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.resumeSession(task: last.task)
                        isInputFocused = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                            Text("Resume").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No active session").font(.system(size: 13, weight: .semibold)).foregroundColor(.primary); Text("Waiting for agent to start…").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Chat

    @ViewBuilder private var chatSection: some View {
        if viewModel.messages.isEmpty && !viewModel.isThinking { EmptyView() } else { ScrollViewReader { proxy in ScrollView(.vertical, showsIndicators: false) { VStack(alignment: .leading, spacing: 8) { ForEach(viewModel.messages) { msg in ChatBubble(message: msg, onCopy: { copyToClipboard(msg.content) }).id(msg.id) }; if viewModel.isThinking { HStack(spacing: 4) { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12); Text("Thinking…").font(.system(size: 11)).foregroundColor(.secondary) }.padding(.leading, 4).id("thinking") } }.padding(.horizontal, 14).padding(.vertical, 6) }.frame(maxHeight: 180).onChange(of: viewModel.messages.count) { _ in if let last = viewModel.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }.onChange(of: viewModel.isThinking) { t in if t { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } } } }
    }
    private func copyToClipboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    // MARK: - Input

    private var inputSection: some View {
        HStack(spacing: 8) {
            if !viewModel.messages.isEmpty {
                Button { viewModel.clearChat() } label: {
                    Image(systemName: "eraser.line.dashed").font(.system(size: 13)).foregroundColor(.secondary.opacity(0.5))
                }.buttonStyle(.plain).help("Clear chat")
            }
            TextField("Type a prompt… (⌘K)", text: $viewModel.inputText).textFieldStyle(.plain).font(.system(size: 12)).focused($isInputFocused).onSubmit { viewModel.submitPrompt() }.padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Button { viewModel.submitPrompt() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary.opacity(0.4) : .blue) }.buttonStyle(.plain).disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func handleDrop(providers: [NSItemProvider]) { for p in providers { if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { i, _ in if let d = i as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { DispatchQueue.main.async { if !viewModel.inputText.isEmpty && !viewModel.inputText.hasSuffix(" ") { viewModel.inputText += " " }; viewModel.inputText += u.path; isInputFocused = true } } } } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { i, _ in if let t = i as? String { DispatchQueue.main.async { if !viewModel.inputText.isEmpty && !viewModel.inputText.hasSuffix(" ") { viewModel.inputText += " " }; viewModel.inputText += t; isInputFocused = true } } } } } }

    // MARK: - History tab

    @ViewBuilder private var historyTabContent: some View {
        VStack(spacing: 0) {
            // Header: title + refresh button
            HStack {
                Text("History").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if let lastRefresh = viewModel.lastHistoryRefresh {
                    Text("Updated \(refreshTimeFormatter.string(from: lastRefresh))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.trailing, 4)
                }
                Button { viewModel.forceRefreshHistory() } label: {
                    HStack(spacing: 3) {
                        if viewModel.isRefreshingHistory {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                        }
                        Text("Refresh").font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRefreshingHistory)
            }.padding(.horizontal, 14).padding(.top, 8)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Search by task name…", text: $viewModel.historySearchText)
                    .textFieldStyle(.plain).font(.system(size: 11))
                if !viewModel.historySearchText.isEmpty {
                    Button { viewModel.historySearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 14).padding(.vertical, 6)

            // Filter pickers
            HStack(spacing: 8) {
                // Status filter
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    Picker("Status", selection: $viewModel.historyFilterStatus) {
                        Text("All").tag("all")
                        Text("Running").tag("running")
                        Text("Completed").tag("completed")
                        Text("Cancelled").tag("cancelled")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .font(.system(size: 10))
                }

                // Date filter
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    Picker("Date", selection: $viewModel.historyFilterDate) {
                        Text("All time").tag("all")
                        Text("Today").tag("today")
                        Text("This week").tag("week")
                        Text("This month").tag("month")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .font(.system(size: 10))
                }

                Spacer()

                // Active filter indicator
                if viewModel.historyFilterStatus != "all" || viewModel.historyFilterDate != "all" {
                    Button {
                        viewModel.historyFilterStatus = "all"
                        viewModel.historyFilterDate = "all"
                    } label: {
                        Text("Clear filters").font(.system(size: 9)).foregroundColor(.blue.opacity(0.7))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 6)

            Divider().padding(.horizontal, 14)

            // Session list
            let entries = viewModel.filteredHistory
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.questionmark").font(.system(size: 24)).foregroundColor(.secondary.opacity(0.4))
                    Text(viewModel.historySearchText.isEmpty && viewModel.historyFilterStatus == "all" && viewModel.historyFilterDate == "all"
                         ? "No sessions yet" : "No matching sessions")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Text(viewModel.historySearchText.isEmpty && viewModel.historyFilterStatus == "all" && viewModel.historyFilterDate == "all"
                         ? "Sessions will appear here after they complete." : "Try adjusting the filters or search term.")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entries.count) session\(entries.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).padding(.bottom, 2)
                        ForEach(entries) { entry in
                            HStack(spacing: 0) {
                                Button {
                                    viewModel.resumeSession(task: entry.task)
                                } label: {
                                    HStack {
                                        HistoryRowView(entry: entry, onCopy: {
                                            copyToClipboard(entry.task)
                                        })
                                        Spacer()
                                        Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.4))
                                    }
                                }
                                .buttonStyle(.plain)
                                Button {
                                    deleteConfirmEntry = entry
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary.opacity(0.3))
                                        .padding(.leading, 6)
                                }
                                .buttonStyle(.plain)
                                .opacity(entry.id == "__running__" ? 0 : 1)
                            }
                            Divider().opacity(0.3)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        if !viewModel.history.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Recent Sessions").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).padding(.bottom, 2); ForEach(viewModel.history) { entry in HistoryRowView(entry: entry) } } }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage; let isUser: Bool; let onCopy: () -> Void
    @State private var showCopied = false
    init(message: ChatMessage, onCopy: @escaping () -> Void) { self.message = message; self.isUser = message.role == "user"; self.onCopy = onCopy }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            if !isUser { Image(systemName: "cpu.fill").font(.system(size: 10)).foregroundColor(.purple).frame(width: 18, height: 18).background(Circle().fill(Color.purple.opacity(0.15))) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(message.content).font(.system(size: 11.5)).foregroundColor(.primary).padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 10).fill(isUser ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1)))
                HStack(spacing: 6) { Text(message.timeLabel).font(.system(size: 9)).foregroundColor(.secondary); if !isUser { Button { onCopy(); showCopied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showCopied = false } } label: { Group { if showCopied { Text("Copied!").font(.system(size: 9)).foregroundColor(.green) } else { Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5)) } } }.buttonStyle(.plain) } }
            }
            if !isUser { Spacer(minLength: 40) }
            if isUser { Image(systemName: "person.circle.fill").font(.system(size: 10)).foregroundColor(.blue).frame(width: 18, height: 18).background(Circle().fill(Color.blue.opacity(0.15))) }
        }
    }
}

// MARK: - Animated Progress Bar

struct AnimatedProgressBar: View {
    let progress: Double
    var body: some View { GeometryReader { geo in ZStack(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)); RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)).frame(width: max(4, geo.size.width * CGFloat(progress))).animation(.easeInOut(duration: 0.6), value: progress) } } }
}

// MARK: - VisualEffectView

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material; let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = material; v.blendingMode = blendingMode; v.state = .active; v.isEmphasized = true; return v }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
private let refreshTimeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm:ss a"; return f }()
