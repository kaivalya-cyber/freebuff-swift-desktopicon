import Foundation
import Combine
import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

/// Manages all state by watching ~/.freebuff/ for file changes (DispatchSource),
/// with a 1s display timer for elapsed-time updates.
@MainActor
final class StatusViewModel: ObservableObject {

    // MARK: - Published state

    @Published var currentStatus: StatusData?
    @Published var history: [HistoryEntry] = []
    @Published var fullHistory: [HistoryEntry] = []
    @Published var historySearchText: String = ""
    @Published var historyFilterStatus: String = "all"   // all, completed, cancelled
    @Published var historyFilterDate: String = "all"       // all, today, week, month
    @Published var isRefreshingHistory: Bool = false
    @Published var lastHistoryRefresh: Date? = nil
    @Published var isStale: Bool = false
    @Published var elapsedString: String = "0s elapsed"
    @Published var remainingString: String = "..."
    @Published var statusText: String = "Idle"
    @Published var animatedProgress: Double = 0.0

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false

    /// 0 = chat, 1 = stats
    @Published var selectedTab: Int = 0

    /// Toggle for compact single-column Stats layout
    @Published var compactMode: Bool = false

    /// Completion banner in Chat tab
    @Published var showCompletionBanner: Bool = false
    @Published var completionTaskName: String = ""

    /// Last sent message text for ⌘Z undo restoration
    @Published var lastSentMessage: String?

    /// Aggregate usage stats from ~/.freebuff/usage.json
    @Published var usageStats: UsageStats = UsageStats()

    // MARK: - Settings

    @Published var showSettings: Bool = false
    @Published var showOnboarding: Bool = false
    @Published var showChangelog: Bool = false
    @Published var costPerPrompt: Double = 0.001
    @Published var contextWindowTokens: Int = 128_000
    @Published var compactDefault: Bool = false
    @Published var overrideTheme: String? = nil  // nil = system, "light", "dark"
    @Published var notificationsEnabled: Bool = true
    @Published var notificationSound: String = "default"  // "default" or named sound
    @Published var weeklySummaryEnabled: Bool = true

    private var configPath: String { "\(freebuffDir)/config.json" }

    var isActive: Bool {
        guard let s = currentStatus, s.isRunning else { return false }
        return true
    }

    /// Live total agent time — includes the currently running session's elapsed time.
    var liveTotalTimeString: String {
        var total = usageStats.totalAgentSeconds
        if let s = currentStatus, s.isRunning, let start = s.startedDate {
            total += Date().timeIntervalSince(start)
        }
        return formatDuration(total)
    }

    /// Live context fill percentage that includes estimated chars from the
    /// currently running session, so the bar fills up in real-time.
    /// Reconciles today's recorded chars with the session estimate to prevent
    /// the bar from shrinking when a session completes.
    var liveContextFillPercent: Double {
        let baseChars = usageStats.totalPromptChars + usageStats.totalResponseChars
        var chars = baseChars
        if let s = currentStatus, s.isRunning, let start = s.startedDate {
            let elapsed = Date().timeIntervalSince(start)
            // Mirror recordCompletedSession's minimum allocation
            let estimatedSessionChars = max(200, Int(elapsed) * 5) + max(500, Int(elapsed) * 15)
            // Separate today's recorded chars from historical to avoid double-counting
            let todayRecorded = (usageStats.dailyEntries[UsageStats.todayKey]?.promptChars ?? 0)
                + (usageStats.dailyEntries[UsageStats.todayKey]?.responseChars ?? 0)
            let historicalChars = max(0, baseChars - todayRecorded)
            let todayContribution = max(todayRecorded, estimatedSessionChars)
            chars = historicalChars + todayContribution
        }
        let tokens = Double(chars) / 4.0
        return min(100.0, (tokens / Double(max(1, contextWindowTokens))) * 100.0)
    }

    /// Live estimated credits that include the currently running session.
    var liveCreditsString: String {
        var prompts = usageStats.totalPrompts
        if currentStatus?.isRunning == true { prompts += 1 }
        let credits = Double(prompts) * costPerPrompt
        if credits < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", credits)
    }

    // MARK: - File paths

    private let freebuffDir: String = {
        NSString(string: "~/.freebuff").expandingTildeInPath
    }()

    private var statusPath: String { "\(freebuffDir)/status.json" }
    private var historyPath: String { "\(freebuffDir)/history.json" }
    private var responsePath: String { "\(freebuffDir)/response.json" }
    private var promptPath: String { "\(freebuffDir)/prompt.json" }
    private var usagePath: String { "\(freebuffDir)/usage.json" }

    // MARK: - File watching (DispatchSource — event-driven)

    private var dirFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
    private var displayTimer: AnyCancellable?

    private let staleTimeout: TimeInterval = 300  // 5 minutes — CLI agents can be slow to update
    private var wasRunning: Bool = false
    private var lastResponseContent: String?

    /// Cached file mtimes to avoid redundant reads
    private var cachedStatusMtime: Date = .distantPast
    private var cachedHistoryMtime: Date = .distantPast
    private var cachedResponseMtime: Date = .distantPast
    private var cachedPromptMtime: Date = .distantPast
    private var cachedUsageMtime: Date = .distantPast

    /// Track last seen task name to detect new CLI-driven sessions
    private var lastSeenTask: String?

    /// Guard against double-counting: set when app writes prompt.json,
    /// checked by loadPrompt() to avoid counting the same prompt twice.
    private var wrotePromptFromApp: Bool = false

    /// Track the last completed session (task+started_at) to avoid creating
    /// duplicate history entries when status.json still says "done" across
    /// multiple reloads or app restarts.
    private var lastCompletedTaskStartedAt: String?

    /// Auto-complete threshold: if a session hasn't been updated in this many
    /// seconds, force-complete it (CLI likely crashed or lost connection).
    private let autoCompleteTimeout: TimeInterval = 300  // 5 minutes

    func startWatching() {
        ensureDirectoryExists()

        // 1s timer: mtime-check all files + update UI.  mtime caching makes
        // this cheap (stat-only when nothing changed) while guaranteeing that
        // checkStaleness() fires even when the DispatchSource is silent.
        displayTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reloadChangedFiles()
            }

        // Open a fd on the directory (not individual files — survives file deletion/recreation)
        dirFD = open(freebuffDir, O_EVTONLY)
        guard dirFD >= 0 else {
            // Fallback: timer-based polling if DispatchSource fails
            print("[Freebuff] Could not open directory fd, falling back to timer")
            startFallbackTimer()
            return
        }

        dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        dirSource?.setEventHandler { [weak self] in
            guard let self else { return }
            // Throttle: coalesce rapid events into a single check
            // DispatchSource coalesces events automatically on the same queue,
            // but we add a tiny debounce to batch writes from the CLI (start → immediate update).
            self.scheduleReload()
        }

        dirSource?.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }

        dirSource?.resume()

        // Load history FIRST so cold-start "done" dedup has data to check against
        loadFullHistory()
        loadUsage()
        loadSettings()

        // Immediate first load
        reloadChangedFiles()
        bootstrapUsageIfNeeded()
        scheduleWeeklySummary()

        // Show onboarding on first launch (no config.json yet)
        if !FileManager.default.fileExists(atPath: configPath) {
            showOnboarding = true
        }
    }

    /// Debounce: rapid directory events get coalesced to a single async reload
    private var reloadWorkItem: DispatchWorkItem?

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadChangedFiles()
            }
        }
        reloadWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func stopWatching() {
        dirSource?.cancel()
        dirSource = nil
        displayTimer?.cancel()
        displayTimer = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
    }

    // MARK: - Fallback timer (when DispatchSource unavailable)

    private var fallbackTimer: AnyCancellable?

    private func startFallbackTimer() {
        fallbackTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reloadChangedFiles()
            }
        // Load history FIRST so cold-start "done" dedup has data to check against
        loadFullHistory()
        loadUsage()
        loadSettings()

        reloadChangedFiles()
        bootstrapUsageIfNeeded()
        scheduleWeeklySummary()
    }

    // MARK: - Reload logic (mtime-aware)

    private func reloadChangedFiles() {
        // --- status.json ---
        let statusChanged = mtimeChanged(path: statusPath, cached: &cachedStatusMtime)
        if statusChanged {
            loadStatus()
        } else if let s = currentStatus, s.isRunning {
            // File didn't change, but we should check staleness periodically
            checkStaleness()
            updateTimeDisplay()
        }

        // --- history.json ---
        if mtimeChanged(path: historyPath, cached: &cachedHistoryMtime) {
            loadHistory()
            loadFullHistory()
        }

        // --- response.json ---
        if mtimeChanged(path: responsePath, cached: &cachedResponseMtime) {
            loadResponse()
        }

        // --- prompt.json --- (CLI-written prompts)
        if mtimeChanged(path: promptPath, cached: &cachedPromptMtime) {
            loadPrompt()
        }

        // --- usage.json ---
        if mtimeChanged(path: usagePath, cached: &cachedUsageMtime) {
            loadUsage()
        }
    }

    /// Returns true if the file's mtime differs from the cached value.
    /// Always updates the cache.
    private func mtimeChanged(path: String, cached: inout Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            let changed = cached != .distantPast // file was there, now gone
            cached = .distantPast
            return changed
        }
        let changed = mtime != cached
        cached = mtime
        return changed
    }

    /// Only update elapsed/remaining strings — called by 1s display timer.
    /// No file I/O, no allocations aside from string formatting.
    private func updateTimeDisplay() {
        guard let status = currentStatus, status.isRunning else { return }

        if let start = status.startedDate {
            let elapsed = Date().timeIntervalSince(start)
            let newElapsed = "\(formatDuration(elapsed)) elapsed"
            if newElapsed != elapsedString {
                elapsedString = newElapsed
            }
        }
        let newRemaining = formatTimeRemaining(
            elapsed: status.startedDate.map { Date().timeIntervalSince($0) } ?? 0,
            progress: status.progress,
            estimatedEnd: status.estimatedEndDate
        )
        if newRemaining != remainingString {
            remainingString = newRemaining
        }
    }

    /// Check if the current running session has gone stale (only called when mtime hasn't changed).
    /// If stale for > autoCompleteTimeout (1hr), force-complete it so history gets recorded.
    private func checkStaleness() {
        guard let s = currentStatus, s.isRunning else { return }
        let age = Date().timeIntervalSince(cachedStatusMtime)
        if age > staleTimeout, !isStale {
            isStale = true
            setIfChanged(&statusText, "Stale — last update \(formatDurationSince(cachedStatusMtime)) ago")
        }
        // Auto-complete: CLI hasn't updated status.json in over an hour — session likely ended
        if age > autoCompleteTimeout {
            autoCompleteStaleSession(age: age)
        }
    }

    /// Force-complete a stale session: save it to history, update usage,
    /// write "done" to status.json on disk, and clear the running state.
    private func autoCompleteStaleSession(age: TimeInterval) {
        guard let status = currentStatus, status.isRunning else { return }

        // Don't double-complete the same session
        let taskKey = "\(status.task)|\(status.started_at)"
        guard taskKey != lastCompletedTaskStartedAt else { return }
        lastCompletedTaskStartedAt = taskKey

        // Estimate duration: from start to last mtime update
        let duration = max(0, cachedStatusMtime.timeIntervalSince(status.startedDate ?? cachedStatusMtime))

        // Record completion
        recordCompletedSession(durationSeconds: duration)
        saveCompletedSessionToHistory()

        // Set wasRunning = false BEFORE writing status.json, so when the write
        // triggers reloadChangedFiles() → loadStatus() → checkAndNotify(),
        // the guard (wasRunning || isNewCompletion) prevents a duplicate entry.
        wasRunning = false

        // Write "done" to status.json on disk so the CLI and future app restarts
        // see the completed state instead of re-reading the stale "running".
        var doneStatus = status
        doneStatus.status = "done"
        doneStatus.progress = 1.0
        if let encoded = try? JSONEncoder().encode(doneStatus) {
            try? encoded.write(to: URL(fileURLWithPath: statusPath))
        }

        // Clear running state so UI reflects completion
        setIfChanged(&statusText, "Done")
        setIfChanged(&animatedProgress, 1.0)
        setIfChanged(&remainingString, "Complete")
        if let start = status.startedDate {
            setIfChanged(&elapsedString, "\(formatDuration(duration)) total")
        }
        lastSeenTask = nil
        isStale = false

        print("[Freebuff] Auto-completed stale session '\(status.task)' after \(Int(age/60))m of inactivity")
    }

    // MARK: - File loaders (same logic, guarded writes)

    private func loadStatus() {
        let path = statusPath
        guard FileManager.default.fileExists(atPath: path) else {
            currentStatus = nil
            isStale = false
            setIfChanged(&statusText, "Idle")
            setIfChanged(&animatedProgress, 0.0)
            lastSeenTask = nil
            checkAndNotify()
            return
        }

        // Always load the file data — age check is for staleness flag only, not a skip-guard
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(StatusData.self, from: data) else { return }

        currentStatus = status

        // Check if the file hasn't been touched recently (stale = CLI may have stalled)
        let age = Date().timeIntervalSince(cachedStatusMtime)
        if age > staleTimeout, status.isRunning {
            isStale = true
            setIfChanged(&statusText, "Stale — last update \(formatDurationSince(cachedStatusMtime)) ago")
        } else {
            isStale = false
        }

        // Track new CLI-driven sessions: if task changed (including from nil after
        // a prior completion), count as a prompt so usage stats reflect CLI usage.
        if status.isRunning, status.task != lastSeenTask {
            incrementUsagePrompts(charCount: status.task.count)
        }
        if status.isRunning {
            lastSeenTask = status.task
        }

        if status.isRunning {
            // Cold-start guard: if this "running" session was already completed
            // (exists in history.json), treat it as done instead of re-activating.
            let alreadyCompleted = fullHistory.contains { $0.task == status.task && $0.started_at == status.started_at && $0.status == "completed" }
            if alreadyCompleted {
                // Write "done" to disk so we don't keep hitting this path.
                // Mutate currentStatus too — otherwise checkAndNotify() sets
                // wasRunning=true (isRunning still true), causing a duplicate
                // on the next mtime-change reload.
                var fixed = status
                fixed.status = "done"
                fixed.progress = 1.0
                currentStatus = fixed
                if let encoded = try? JSONEncoder().encode(fixed) {
                    try? encoded.write(to: URL(fileURLWithPath: statusPath))
                }
                setIfChanged(&statusText, "Done")
                setIfChanged(&animatedProgress, 1.0)
                setIfChanged(&remainingString, "Complete")
                lastSeenTask = nil
                isStale = false
            } else {
                setIfChanged(&statusText, isStale ? statusText : "Working")
                setIfChanged(&animatedProgress, status.progress)
                updateTimeDisplay()
            }
        } else if status.status == "done" {
            setIfChanged(&statusText, "Done")
            setIfChanged(&animatedProgress, 1.0)
            if let start = status.startedDate, let end = status.estimatedEndDate {
                setIfChanged(&elapsedString, "\(formatDuration(end.timeIntervalSince(start))) total")
            }
            setIfChanged(&remainingString, "Complete")
            lastSeenTask = nil
        } else {
            setIfChanged(&statusText, "Idle")
            setIfChanged(&animatedProgress, 0.0)
            lastSeenTask = nil
        }

        checkAndNotify()
    }

    private func checkAndNotify() {
        // Detect completion: either we saw a transition (wasRunning → Done)
        // or status.json already says "done" on cold start (wasRunning was false but
        // the status is done and we haven't recorded this session yet).
        if statusText == "Done", let status = currentStatus {
            let taskKey = "\(status.task)|\(status.started_at)"
            // Guard against duplicates: check in-memory tracker AND existing history entries
            let alreadyInHistory = fullHistory.contains { $0.task == status.task && $0.started_at == status.started_at }
            let isNewCompletion = taskKey != lastCompletedTaskStartedAt && !alreadyInHistory

            if wasRunning || isNewCompletion {
                if isNewCompletion {
                    lastCompletedTaskStartedAt = taskKey
                }
                if wasRunning {
                    sendCompletionNotification()
                    // Show completion banner in Chat tab
                    completionTaskName = status.task
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showCompletionBanner = true
                    }
                }
                // Record session stats and write history (once per session)
                if let start = status.startedDate {
                    let duration = Date().timeIntervalSince(start)
                    recordCompletedSession(durationSeconds: duration)
                }
                saveCompletedSessionToHistory()
            }
        }
        wasRunning = currentStatus?.isRunning == true
    }

    /// Append a HistoryEntry for the just-completed session to history.json
    /// and refresh the in-memory lists so the UI updates immediately.
    /// Git diff stats are detected asynchronously on a background queue
    /// to avoid blocking the main thread.
    private func saveCompletedSessionToHistory() {
        guard let status = currentStatus else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        let startedAt = status.started_at
        let endedAt = now
        let entryId = UUID().uuidString

        let entry = HistoryEntry(
            id: entryId,
            task: status.task,
            started_at: startedAt,
            ended_at: endedAt,
            status: "completed",
            lines_added: nil,
            lines_removed: nil
        )

        // Read existing entries, append, write back
        let path = historyPath
        var entries: [HistoryEntry] = []
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = existing
        }
        entries.append(entry)

        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: URL(fileURLWithPath: path))
        }

        // Refresh in-memory history lists
        let sorted = entries.sorted { a, b in
            (a.endedDate ?? .distantPast) > (b.endedDate ?? .distantPast)
        }
        fullHistory = sorted
        history = Array(sorted.prefix(5))

        // Asynchronously try to detect git diff stats — no UI blocking
        let sessionStart = status.startedDate ?? Date().addingTimeInterval(-3600)
        let workingDir = status.cwd
        Task.detached(priority: .background) { [weak self, entryId] in
            guard let self = self,
                  let diffStats = self.tryGetGitDiffStats(since: sessionStart, cwd: workingDir) else { return }
            await self.patchHistoryEntry(id: entryId, added: diffStats.added, removed: diffStats.removed)
        }
    }

    /// Patch an existing history entry with git diff stats.
    @MainActor
    private func patchHistoryEntry(id: String, added: Int, removed: Int) {
        let path = historyPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var entries = try? JSONDecoder().decode([HistoryEntry].self, from: data),
              let idx = entries.firstIndex(where: { $0.id == id }) else { return }

        entries[idx] = HistoryEntry(
            id: entries[idx].id,
            task: entries[idx].task,
            started_at: entries[idx].started_at,
            ended_at: entries[idx].ended_at,
            status: entries[idx].status,
            lines_added: added,
            lines_removed: removed
        )

        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: URL(fileURLWithPath: path))
        }

        // Refresh in-memory lists
        let sorted = entries.sorted { a, b in
            (a.endedDate ?? .distantPast) > (b.endedDate ?? .distantPast)
        }
        fullHistory = sorted
        history = Array(sorted.prefix(5))
    }

    private func sendCompletionNotification() {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Freebuff — Session Complete"
        content.body = currentStatus?.task ?? "Your agent has finished its task."
        content.sound = notificationSound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(notificationSound))

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Freebuff] Notification error: \(error.localizedDescription)")
            }
        }
    }

    private func loadHistory() {
        let path = historyPath
        guard FileManager.default.fileExists(atPath: path) else {
            if !history.isEmpty { history = [] }
            return
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let decoder = JSONDecoder()
        guard let entries = try? decoder.decode([HistoryEntry].self, from: data) else { return }

        let newHistory = Array(entries.sorted { a, b in
            (a.endedDate ?? .distantPast) > (b.endedDate ?? .distantPast)
        }.prefix(5))

        if newHistory != history {
            history = newHistory
        }
    }

    /// Load ALL history entries for the History tab (not just the last 5).
    private func loadFullHistory() {
        let path = historyPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            if !fullHistory.isEmpty { fullHistory = [] }
            return
        }
        let decoder = JSONDecoder()
        guard let entries = try? decoder.decode([HistoryEntry].self, from: data) else { return }
        let sorted = entries.sorted { a, b in
            (a.endedDate ?? .distantPast) > (b.endedDate ?? .distantPast)
        }
        if sorted != fullHistory { fullHistory = sorted }
    }

    /// Filtered history for the History tab — chains status → date → search.
    /// Also synthesizes an "in-progress" entry from the currently running session.
    var filteredHistory: [HistoryEntry] {
        var entries = fullHistory

        // If a session is currently running, prepend a virtual entry
        if let status = currentStatus, status.isRunning {
            let now = ISO8601DateFormatter().string(from: Date())
            let runningEntry = HistoryEntry(
                id: "__running__",
                task: status.task,
                started_at: status.started_at,
                ended_at: now,  // still running — used for "just now" display
                status: "running",
                lines_added: nil,
                lines_removed: nil
            )
            entries.insert(runningEntry, at: 0)
        }

        // 1. Status filter
        switch historyFilterStatus {
        case "completed": entries = entries.filter { $0.status == "completed" }
        case "cancelled": entries = entries.filter { $0.status == "cancelled" }
        case "running": entries = entries.filter { $0.status == "running" }
        default: break
        }

        // 2. Date filter
        let now = Date()
        let calendar = Calendar.current
        switch historyFilterDate {
        case "today":
            let startOfToday = calendar.startOfDay(for: now)
            entries = entries.filter { ($0.endedDate ?? .distantPast) >= startOfToday }
        case "week":
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { break }
            entries = entries.filter { ($0.endedDate ?? .distantPast) >= weekAgo }
        case "month":
            guard let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) else { break }
            entries = entries.filter { ($0.endedDate ?? .distantPast) >= monthAgo }
        default: break
        }

        // 3. Text search
        let q = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            entries = entries.filter { $0.task.lowercased().contains(q) || ($0.id.lowercased().contains(q)) }
        }

        return entries
    }

    /// Force re-read history.json and refresh in-memory lists.
    func forceRefreshHistory() {
        isRefreshingHistory = true
        loadFullHistory()
        loadHistory()
        lastHistoryRefresh = Date()
        // Brief delay to show spinner
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            isRefreshingHistory = false
        }
    }

    private func loadResponse() {
        let path = responsePath
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(ResponseData.self, from: data) else { return }

        guard response.content != lastResponseContent else { return }
        lastResponseContent = response.content

        let msg = ChatMessage(
            id: UUID().uuidString,
            role: "agent",
            content: response.content,
            timestamp: response.timestamp
        )

        messages.append(msg)
        if isThinking { isThinking = false }

        // Track response count in usage stats (with real char count)
        incrementUsageResponses(charCount: response.content.count)

        // Cap at 20 messages for memory efficiency
        if messages.count > 20 {
            messages = Array(messages.suffix(20))
        }
    }

    /// Load prompt.json written by the CLI or agent bridge.
    /// Counts as a prompt unless the app itself just wrote it (guard flag).
    private func loadPrompt() {
        // Skip if the app wrote this — already counted in submitPrompt()
        if wrotePromptFromApp {
            wrotePromptFromApp = false
            return
        }

        let path = promptPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let prompt = try? JSONDecoder().decode(PromptData.self, from: data) else { return }

        // Guard against empty content (file creation race)
        guard !prompt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        incrementUsagePrompts(charCount: prompt.content.count)
    }

    // MARK: - Prompt submission

    func submitPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let now = ISO8601DateFormatter().string(from: Date())

        let msg = ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: text,
            timestamp: now
        )
        messages.append(msg)
        isThinking = true

        // Cap messages
        if messages.count > 20 {
            messages = Array(messages.suffix(20))
        }

        let prompt = PromptData(content: text, timestamp: now)
        if let data = try? JSONEncoder().encode(prompt) {
            try? data.write(to: URL(fileURLWithPath: promptPath))
        }

        lastSentMessage = text
        inputText = ""

        // Track prompt count in usage stats (with real char count)
        incrementUsagePrompts(charCount: text.count)
        wrotePromptFromApp = true

        // Fire off the agent bridge asynchronously — it reads
        // prompt.json, runs Codebuff, and writes response.json.
        // The DispatchSource picks up the response file change.
        callAgentBridge()
    }

    // MARK: - Agent bridge

    /// Spawn a background Process that runs the Python bridge script.
    /// The script reads ~/.freebuff/prompt.json, pipes it through
    /// `npx codebuff`, and writes ~/.freebuff/response.json.
    /// This runs fully async — we don't await it. The DispatchSource
    /// detects response.json being written and loads it into chat.
    private func callAgentBridge() {
        let scriptPath = findBridgeScript()
        guard let scriptPath else {
            // Write an error response directly so the user sees it in chat
            writeBridgeError("Agent bridge script not found. Run 'bash cli/freebuff.sh setup' to install it.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath]
        process.qualityOfService = .utility

        // Non-blocking: fire and forget. The DispatchSource handles the response.
        process.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                // Bridge failed — write an error so the user isn't left hanging
                let errorMsg = "Agent bridge exited with code \(proc.terminationStatus). "
                    + "Check that `npx codebuff` works from your terminal."
                Task { @MainActor [weak self] in
                    self?.writeBridgeError(errorMsg)
                }
            }
            // On success, the bridge already wrote response.json.
            // The DispatchSource fires → loadResponse() picks it up.
        }

        do {
            try process.run()
        } catch {
            writeBridgeError("Failed to start agent bridge: \(error.localizedDescription)")
        }
    }

    /// Locate handle-prompt.py: first try the app bundle Resources,
    /// then the project repo (for dev builds via `swift build`).
    private func findBridgeScript() -> String? {
        // 1. App bundle (production)
        if let path = Bundle.main.path(forResource: "handle-prompt", ofType: "py"),
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        // 2. Repo-relative (development via `swift build`)
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StatusViewModel.swift
            .deletingLastPathComponent()  // Freebuff
            .deletingLastPathComponent()  // Sources
            .appendingPathComponent("cli")
            .appendingPathComponent("handle-prompt.py")
        let repoPath = fileURL.path
        if FileManager.default.fileExists(atPath: repoPath) {
            return repoPath
        }

        // 3. ~/.freebuff/ (manual install)
        let homePath = NSString(string: "~/.freebuff/handle-prompt.py").expandingTildeInPath
        if FileManager.default.fileExists(atPath: homePath) {
            return homePath
        }

        return nil
    }

    /// Write an error message directly to response.json so it appears
    /// in chat rather than silently failing.
    private func writeBridgeError(_ message: String) {
        let errorResponse = ResponseData(
            content: message,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(errorResponse) {
            try? data.write(to: URL(fileURLWithPath: responsePath))
        }
    }

    // MARK: - Usage tracking

    /// Load aggregate usage stats from ~/.freebuff/usage.json
    private func loadUsage() {
        let path = usagePath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }
        let decoder = JSONDecoder()
        guard let stats = try? decoder.decode(UsageStats.self, from: data) else { return }

        if stats != usageStats {
            usageStats = stats
        }

        // Recompute total agent time from full history
        recomputeTotalTime()
    }

    /// Increment the prompt counter (with char count) and persist.
    private func incrementUsagePrompts(charCount: Int = 0) {
        var stats = loadOrCreateUsage()
        stats.recordPrompt(charCount: charCount)
        stats.pruneOldEntries()
        saveUsage(stats)
    }

    /// Increment the response counter (with char count) and persist.
    private func incrementUsageResponses(charCount: Int = 0) {
        var stats = loadOrCreateUsage()
        stats.recordResponse(charCount: charCount)
        stats.pruneOldEntries()
        saveUsage(stats)
    }

    /// Increment session count and add session duration.
    /// Ensures minimum char counts per day so context fill shows meaningful
    /// numbers even for CLI sessions that don't write prompt.json/response.json.
    /// Does NOT increment prompt/response counters — those are tracked
    /// individually by loadStatus/submitPrompt/loadResponse.
    private func recordCompletedSession(durationSeconds: TimeInterval) {
        var stats = loadOrCreateUsage()
        stats.recordSession(durationSeconds: durationSeconds)
        // Ensure minimum char counts for today's daily entry.
        // ~5 prompt chars/sec + ~15 response chars/sec.
        let minPromptChars = max(200, Int(durationSeconds) * 5)
        let minResponseChars = max(500, Int(durationSeconds) * 15)
        let todayKey = UsageStats.todayKey
        var today = stats.dailyEntries[todayKey] ?? DailyUsage()
        if today.promptChars < minPromptChars {
            let delta = minPromptChars - today.promptChars
            stats.totalPromptChars += delta
            today.promptChars = minPromptChars
        }
        if today.responseChars < minResponseChars {
            let delta = minResponseChars - today.responseChars
            stats.totalResponseChars += delta
            today.responseChars = minResponseChars
        }
        stats.dailyEntries[todayKey] = today
        stats.pruneOldEntries()
        saveUsage(stats)
    }

    /// Guard against save→reload→save loops when recomputeTotalTime
    /// corrects the usage file.
    private var isSavingUsage: Bool = false

    /// Recompute total agent time and session count from the full history.json.
    /// This bootstraps stats for sessions that completed while the app wasn't running,
    /// or sessions that predate the usage tracking feature.
    private func recomputeTotalTime() {
        guard !isSavingUsage else { return }

        let path = historyPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        guard let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }

        // Count completed sessions from history
        let completedEntries = entries.filter { $0.status == "completed" }
        let historySessionCount = completedEntries.count

        let totalSeconds = completedEntries.reduce(0.0) { acc, entry in
            guard let start = entry.startedDate,
                  let end = entry.endedDate else { return acc }
            return acc + max(0, end.timeIntervalSince(start))
        }

        let countChanged = usageStats.totalSessions != historySessionCount
        let timeChanged = abs(usageStats.totalAgentSeconds - totalSeconds) > 1.0

        if countChanged || timeChanged {
            var stats = usageStats
            stats.totalSessions = historySessionCount
            stats.totalAgentSeconds = totalSeconds
            isSavingUsage = true
            usageStats = stats
            saveUsage(stats)
            isSavingUsage = false
        }
    }

    private func loadOrCreateUsage() -> UsageStats {
        let path = usagePath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let stats = try? JSONDecoder().decode(UsageStats.self, from: data) else {
            return UsageStats()
        }
        return stats
    }

    private func saveUsage(_ stats: UsageStats) {
        // Skip derived computation here — loadUsage() handles it
        // on the DispatchSource re-read, avoiding redundant I/O.
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: URL(fileURLWithPath: usagePath))
        }
        if stats != usageStats {
            usageStats = stats
        }
    }

    // MARK: - Reset settings

    func resetSettings() {
        costPerPrompt = 0.001
        contextWindowTokens = 128_000
        compactDefault = false
        compactMode = false
        overrideTheme = nil
        notificationsEnabled = true
        notificationSound = "default"
        weeklySummaryEnabled = true
        applyTheme()
        saveSettings()
    }

    /// Dismiss the onboarding screen and write a default config so it never re-shows.
    func completeOnboarding() {
        showOnboarding = false
        saveSettings()  // writes config.json, preventing the overlay from re-appearing
    }

    /// Restore last sent message to input field (⌘Z undo)
    func undoRestore() {
        guard let msg = lastSentMessage else { return }
        inputText = msg
        lastSentMessage = nil
    }

    /// Resume a past session: populate input with the task name and switch to Chat tab
    func resumeSession(task: String) {
        inputText = task
        selectedTab = 0
    }

    /// Wipe usage.json and reset in-memory stats to zero.
    func resetUsageStats() {
        try? FileManager.default.removeItem(atPath: usagePath)
        usageStats = UsageStats()
    }

    /// Wipe all data: history.json, usage.json, status.json, and in-memory state.
    func resetAllData() {
        try? FileManager.default.removeItem(atPath: historyPath)
        try? FileManager.default.removeItem(atPath: usagePath)
        try? FileManager.default.removeItem(atPath: statusPath)
        usageStats = UsageStats()
        fullHistory = []
        history = []
        currentStatus = nil
        setIfChanged(&statusText, "Idle")
        setIfChanged(&animatedProgress, 0.0)
        lastSeenTask = nil
        lastCompletedTaskStartedAt = nil
        isStale = false
    }

    /// Delete a single history entry from history.json by ID.
    func deleteHistoryEntry(id: String) {
        let path = historyPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }

        entries.removeAll { $0.id == id }

        // Write back to history.json
        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: URL(fileURLWithPath: path))
        }

        // Update in-memory lists
        fullHistory.removeAll { $0.id == id }
        history.removeAll { $0.id == id }
    }

    // MARK: - Clear chat

    func clearChat() {
        messages.removeAll()
        lastResponseContent = nil
        isThinking = false
        inputText = ""
        lastSentMessage = nil
    }

    // MARK: - Settings persistence

    func loadSettings() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return }
        let decoder = JSONDecoder()
        struct SettingsPayload: Codable {
            var costPerPrompt: Double?
            var contextWindowTokens: Double?
            var compactDefault: Double?
            var overrideTheme: String?
            var notificationsEnabled: Double?
            var notificationSound: String?
            var weeklySummaryEnabled: Double?
            var lastSeenVersion: String?
        }
        if let payload = try? decoder.decode(SettingsPayload.self, from: data) {
            if let v = payload.costPerPrompt { costPerPrompt = v }
            if let v = payload.contextWindowTokens { contextWindowTokens = Int(v) }
            if let v = payload.compactDefault { compactDefault = v != 0; compactMode = compactDefault }
            if let v = payload.overrideTheme, ["light", "dark"].contains(v) { overrideTheme = v }
            if let v = payload.notificationsEnabled { notificationsEnabled = v != 0 }
            if let v = payload.notificationSound, !v.isEmpty { notificationSound = v }
            if let v = payload.weeklySummaryEnabled { weeklySummaryEnabled = v != 0 }
            // Show changelog if version changed (but not on first launch — onboarding handles that)
            if let seen = payload.lastSeenVersion, seen != currentAppVersion, showOnboarding == false {
                showChangelog = true
            }
        } else {
            guard let dict = try? decoder.decode([String: Double].self, from: data) else { return }
            if let v = dict["costPerPrompt"] { costPerPrompt = v }
            if let v = dict["contextWindowTokens"] { contextWindowTokens = Int(v) }
            if let v = dict["compactDefault"] { compactDefault = v != 0; compactMode = compactDefault }
        }
        applyTheme()
    }

    /// Current app version from Info.plist
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Dismiss changelog and record current version so it won't re-show.
    func dismissChangelog() {
        showChangelog = false
        saveSettings()
    }

    func saveSettings() {
        let dict: [String: Any] = [
            "costPerPrompt": costPerPrompt,
            "contextWindowTokens": Double(contextWindowTokens),
            "compactDefault": compactDefault ? 1 : 0,
            "overrideTheme": (overrideTheme ?? "system") as Any,
            "notificationsEnabled": notificationsEnabled ? 1 : 0,
            "notificationSound": notificationSound,
            "weeklySummaryEnabled": weeklySummaryEnabled ? 1 : 0,
            "lastSeenVersion": currentAppVersion
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Apply the user's theme preference to the app appearance.
    func applyTheme() {
        switch overrideTheme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil  // follow system
        }
    }

    // MARK: - Setup

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            atPath: freebuffDir,
            withIntermediateDirectories: true
        )
    }

    /// Create usage.json with defaults if it doesn't exist yet,
    /// and seed prompt count from any running session in status.json.
    private func bootstrapUsageIfNeeded() {
        let path = usagePath
        guard !FileManager.default.fileExists(atPath: path) else { return }

        var stats = UsageStats()

        // If a session is currently running, count it as a prompt.
        // Read status.json directly for robustness — currentStatus may not be set yet.
        let statPath = statusPath
        if FileManager.default.fileExists(atPath: statPath),
           let raw = try? Data(contentsOf: URL(fileURLWithPath: statPath)),
           let status = try? JSONDecoder().decode(StatusData.self, from: raw),
           status.isRunning {
            stats.recordPrompt(charCount: status.task.count)
        }

        // Bootstrap session count and time from history if available
        let histPath = historyPath
        if FileManager.default.fileExists(atPath: histPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: histPath)),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            let completed = entries.filter { $0.status == "completed" }
            stats.totalSessions = completed.count
            stats.totalAgentSeconds = completed.reduce(0.0) { acc, entry in
                guard let start = entry.startedDate, let end = entry.endedDate else { return acc }
                return acc + max(0, end.timeIntervalSince(start))
            }
        }

        usageStats = stats
        saveUsage(stats)
    }

    // MARK: - Git diff stats (async — non-blocking)

    /// Best-effort detection of git diff stats for a completed session.
    /// If `cwd` is provided (from status.json), uses that directory directly.
    /// Otherwise scans common project directories.
    private nonisolated func tryGetGitDiffStats(since startDate: Date, cwd: String?) -> (added: Int, removed: Int)? {
        let sinceStr = ISO8601DateFormatter().string(from: startDate)

        // If we have a working directory from status.json, try it first
        if let cwd = cwd, FileManager.default.fileExists(atPath: cwd) {
            if let stats = Self.runGitShortstat(repoPath: cwd, sinceStr: sinceStr) {
                return stats
            }
        }

        // Fallback: scan common directories
        let searchDirs = [
            NSString(string: "~/Downloads").expandingTildeInPath,
            NSString(string: "~/Projects").expandingTildeInPath,
            NSString(string: "~/Documents").expandingTildeInPath,
            NSString(string: "~/Desktop").expandingTildeInPath
        ]

        for searchDir in searchDirs {
            guard FileManager.default.fileExists(atPath: searchDir) else { continue }

            // Use a single shell pipeline: find repos → run git shortstat → return first match
            let script = """
            found=$(find "\(searchDir)" -name '.git' -type d -maxdepth 4 2>/dev/null | head -5)
            for g in $found; do
                repo=$(dirname "$g")
                out=$(cd "$repo" && git log -1 --shortstat --since="\(sinceStr)" 2>/dev/null)
                if [ -n "$out" ]; then
                    echo "$out"
                    exit 0
                fi
            done
            exit 1
            """

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", script]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            try? task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0,
                  let output = try? pipe.fileHandleForReading.readToEnd(),
                  let gitStr = String(data: output, encoding: .utf8),
                  !gitStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if let stats = Self.parseGitShortstat(gitStr) {
                return stats
            }
        }

        return nil
    }

    /// Run git log -1 --shortstat in a specific repo path.
    private nonisolated static func runGitShortstat(repoPath: String, sinceStr: String) -> (added: Int, removed: Int)? {
        let task = Process()
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["log", "-1", "--shortstat", "--since=\(sinceStr)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        try? task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let output = try? pipe.fileHandleForReading.readToEnd(),
              let gitStr = String(data: output, encoding: .utf8),
              !gitStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return parseGitShortstat(gitStr)
    }

    /// Parse `git log --shortstat` output like:
    /// " 2 files changed, 15 insertions(+), 7 deletions(-)"
    nonisolated static func parseGitShortstat(_ output: String) -> (added: Int, removed: Int)? {
        var added = 0
        var removed = 0

        if let insRange = output.range(of: #"(\d+) insertions"#, options: .regularExpression),
           let insStr = output[insRange].components(separatedBy: " ").first,
           let ins = Int(insStr) {
            added = ins
        }
        if let delRange = output.range(of: #"(\d+) deletions"#, options: .regularExpression),
           let delStr = output[delRange].components(separatedBy: " ").first,
           let del = Int(delStr) {
            removed = del
        }

        if added > 0 || removed > 0 {
            return (added, removed)
        }
        return nil
    }

    /// Force a full recalculation of all usage stats from history.json.
    /// Bypasses the isSavingUsage guard so it always runs.
    func forceRecomputeFromHistory() {
        let path = historyPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }

        let completedEntries = entries.filter { $0.status == "completed" }
        let historySessionCount = completedEntries.count
        let totalSeconds = completedEntries.reduce(0.0) { acc, entry in
            guard let start = entry.startedDate, let end = entry.endedDate else { return acc }
            return acc + max(0, end.timeIntervalSince(start))
        }

        var stats = loadOrCreateUsage()
        stats.totalSessions = historySessionCount
        stats.totalAgentSeconds = totalSeconds
        stats.pruneOldEntries()
        isSavingUsage = true
        defer { isSavingUsage = false }
        saveUsage(stats)
    }

    /// Export usage stats as a CSV string
    func exportUsageCSV() -> String {
        let days = usageStats.last7Days.sorted { $0.date < $1.date }
        var csv = "Date,Prompts,Responses,Sessions,Prompt Chars,Response Chars,Tokens\n"
        for d in days {
            let tokens = (d.usage.promptChars + d.usage.responseChars) / 4
            csv += "\(d.date),\(d.usage.prompts),\(d.usage.responses),\(d.usage.sessions),\(d.usage.promptChars),\(d.usage.responseChars),\(tokens)\n"
        }
        return csv
    }

    // MARK: - Weekly summary notification

    /// Schedule a recurring Monday morning summary notification.
    func scheduleWeeklySummary() {
        guard weeklySummaryEnabled else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["weekly-summary"])
            return
        }

        var components = DateComponents()
        components.weekday = 2  // Monday
        components.hour = 9
        components.minute = 0

        // Non-repeating: re-scheduled on each app launch / settings change for fresh stats
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let content = UNMutableNotificationContent()
        content.title = "Freebuff — Weekly Summary"
        content.body = buildWeeklySummaryBody()
        content.sound = notificationSound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(notificationSound))

        let request = UNNotificationRequest(identifier: "weekly-summary", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Freebuff] Weekly summary error: \(error.localizedDescription)")
            }
        }
    }

    private func buildWeeklySummaryBody() -> String {
        let days = usageStats.last7Days
        let totalP = days.reduce(0) { $0 + $1.usage.prompts }
        let totalR = days.reduce(0) { $0 + $1.usage.responses }
        let totalS = days.reduce(0) { $0 + $1.usage.sessions }
        let totalTokens = days.reduce(0) { ($0 + $1.usage.promptChars + $1.usage.responseChars) / 4 }
        return "\(totalP) prompts, \(totalR) responses, \(totalS) sessions — ~\(totalTokens) tokens this week."
    }

    func registerLoginItem() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("[Freebuff] Could not register login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Guarded set helper

/// Only assign if the new value differs — avoids unnecessary @Published fires / UI recomputation.
private func setIfChanged<T: Equatable>(_ target: inout T, _ value: T) {
    if target != value {
        target = value
    }
}
