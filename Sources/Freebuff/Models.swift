import Foundation

// MARK: - Status File Schema

/// Live status written by the CLI agent to ~/.freebuff/status.json
struct StatusData: Codable, Equatable {
    /// "running", "idle", or "done"
    var status: String

    /// Human-readable task description (e.g. "find ways to improve the ui")
    var task: String

    /// ISO 8601 timestamp when the session started
    var started_at: String

    /// ISO 8601 timestamp when the session is estimated to end (optional)
    var estimated_end_at: String?

    /// Progress from 0.0 to 1.0
    var progress: Double

    /// Optional: working directory of the CLI agent (for git diff detection)
    var cwd: String?

    /// Convenience: parse started_at into Date
    var startedDate: Date? {
        ISO8601DateFormatter().date(from: started_at)
    }

    /// Convenience: parse estimated_end_at into Date
    var estimatedEndDate: Date? {
        guard let end = estimated_end_at else { return nil }
        return ISO8601DateFormatter().date(from: end)
    }

    /// Is the session considered active?
    var isRunning: Bool {
        status == "running"
    }
}

// MARK: - History File Schema

/// A completed session, appended to ~/.freebuff/history.json
struct HistoryEntry: Codable, Identifiable, Equatable {
    /// UUID string for the session
    var id: String

    /// Task description
    var task: String

    /// ISO 8601 start timestamp
    var started_at: String

    /// ISO 8601 end timestamp
    var ended_at: String

    /// "completed", "cancelled", or "running" (virtual)
    var status: String

    /// Optional: lines added (green "+N" in UI)
    var lines_added: Int?

    /// Optional: lines removed (red "-N" in UI)
    var lines_removed: Int?

    var startedDate: Date? {
        ISO8601DateFormatter().date(from: started_at)
    }

    var endedDate: Date? {
        ISO8601DateFormatter().date(from: ended_at)
    }

    /// Duration string like "4m 12s" — for running sessions shows elapsed
    var durationString: String {
        guard let start = startedDate else { return "--" }
        if status == "running" {
            return formatDuration(Date().timeIntervalSince(start))
        }
        guard let end = endedDate else { return "--" }
        let interval = max(0, end.timeIntervalSince(start))
        return formatDuration(interval)
    }

    /// Relative time string like "2m ago" — for running sessions shows "active"
    var relativeTimeString: String {
        if status == "running" { return "active" }
        guard let end = endedDate else { return "--" }
        let interval = Date().timeIntervalSince(end)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Chat / Prompt Schema

/// A chat message shown in the popover conversation
struct ChatMessage: Codable, Identifiable, Equatable {
    var id: String
    /// "user" or "agent"
    var role: String
    /// Message content
    var content: String
    /// ISO 8601 timestamp
    var timestamp: String

    var date: Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }

    var timeLabel: String {
        guard let d = date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

/// Written by the app to ~/.freebuff/prompt.json when user submits a prompt
struct PromptData: Codable {
    var content: String
    var timestamp: String
}

/// Read by the app from ~/.freebuff/response.json
struct ResponseData: Codable {
    var content: String
    var timestamp: String
}

// MARK: - Usage Stats Schema

/// Per-day usage counters keyed by "YYYY-MM-DD".
/// Persisted inside UsageStats.dailyEntries.
struct DailyUsage: Codable, Equatable {
    var prompts: Int = 0
    var responses: Int = 0
    var sessions: Int = 0
    /// Total characters across all prompts today (for real token estimation)
    var promptChars: Int = 0
    /// Total characters across all responses today
    var responseChars: Int = 0
}

/// Aggregate usage metrics persisted to ~/.freebuff/usage.json.
/// Daily entries pruned to last 30 days on each save.
struct UsageStats: Codable, Equatable {
    /// Total number of user prompts sent across all sessions
    var totalPrompts: Int = 0

    /// Total number of agent responses received
    var totalResponses: Int = 0

    /// Total characters across all prompts (for real token estimation: chars/4 ≈ tokens)
    var totalPromptChars: Int = 0

    /// Total characters across all responses
    var totalResponseChars: Int = 0

    /// Total number of completed sessions
    var totalSessions: Int = 0

    /// Total agent time across all sessions (seconds)
    var totalAgentSeconds: TimeInterval = 0

    /// Per-day breakdown: "YYYY-MM-DD" → DailyUsage
    /// Entries older than 30 days are pruned on save.
    var dailyEntries: [String: DailyUsage] = [:]

    // MARK: - Derived: today

    // MARK: - Helpers

    static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's date key (e.g. "2026-07-06")
    static var todayKey: String {
        dateKeyFormatter.string(from: Date())
    }

    /// Today's session count (from daily entry)
    var todaySessions: Int {
        dailyEntries[Self.todayKey]?.sessions ?? 0
    }

    /// Today's prompt count (from daily entry)
    var todayPrompts: Int {
        dailyEntries[Self.todayKey]?.prompts ?? 0
    }

    /// Last 7 days of daily entries sorted by date, for sparkline & breakdown
    var last7Days: [(date: String, usage: DailyUsage)] {
        // Fill gaps so we always show exactly 7 slots
        var result: [(String, DailyUsage)] = []
        let calendar = Calendar.current
        for i in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let key = Self.dateKeyFormatter.string(from: date)
            let entry = dailyEntries[key] ?? DailyUsage()
            result.append((key, entry))
        }
        return result
    }

    static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E"
        return f
    }()

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    /// Short date labels for sparkline (e.g. "Mon", "Tue")
    static func shortDayLabel(for dateKey: String) -> String {
        guard let date = dateKeyFormatter.date(from: dateKey) else { return "" }
        return shortDayFormatter.string(from: date)
    }

    // MARK: - Derived: credits & context

    /// Estimated API credits burnt (prompts × approx token cost)
    var estimatedCredits: Double {
        Double(totalPrompts) * 0.001
    }

    /// Formatted credits string
    var creditsString: String {
        if estimatedCredits < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", estimatedCredits)
    }

    // MARK: - This month

    /// Filter daily entries to current month only
    private var thisMonthEntries: [(String, DailyUsage)] {
        let calendar = Calendar.current
        let thisMonth = calendar.component(.month, from: Date())
        let thisYear = calendar.component(.year, from: Date())
        return dailyEntries.compactMap { key, usage in
            guard let date = Self.dateKeyFormatter.date(from: key) else { return nil }
            let m = calendar.component(.month, from: date)
            let y = calendar.component(.year, from: date)
            guard m == thisMonth && y == thisYear else { return nil }
            return (key, usage)
        }.sorted { $0.0 < $1.0 }
    }

    /// This month's prompt count
    var thisMonthPrompts: Int {
        thisMonthEntries.reduce(0) { $0 + $1.1.prompts }
    }

    /// This month's response count
    var thisMonthResponses: Int {
        thisMonthEntries.reduce(0) { $0 + $1.1.responses }
    }

    /// This month's session count
    var thisMonthSessions: Int {
        thisMonthEntries.reduce(0) { $0 + $1.1.sessions }
    }

    /// This month's estimated credits
    var thisMonthCredits: Double {
        Double(thisMonthPrompts) * 0.001
    }

    /// Formatted this-month credits string
    var thisMonthCreditsString: String {
        if thisMonthCredits < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", thisMonthCredits)
    }

    /// Total agent time formatted
    var totalTimeString: String {
        formatDuration(totalAgentSeconds)
    }

    /// Estimated context fill percentage (0–100)
    /// Uses real character counts: chars/4 ≈ tokens.
    func contextFillPercent(windowTokens: Int = 128_000) -> Double {
        let estimatedTokens = Double(totalPromptChars + totalResponseChars) / 4.0
        let contextWindow = Double(max(1, windowTokens))
        return min(100.0, (estimatedTokens / contextWindow) * 100.0)
    }

    /// Approximate token count from real char data
    var estimatedTokens: Int {
        (totalPromptChars + totalResponseChars) / 4
    }

    /// Context fill label
    func contextFillLabel(windowTokens: Int = 128_000) -> String {
        let pct = contextFillPercent(windowTokens: windowTokens)
        if pct < 1 { return "<1%" }
        return String(format: "%.0f%%", pct)
    }

    // MARK: - Mutations

    /// Increment today's prompt count and the all-time counter.
    mutating func recordPrompt(charCount: Int = 0) {
        totalPrompts += 1
        totalPromptChars += charCount
        let key = Self.todayKey
        var today = dailyEntries[key] ?? DailyUsage()
        today.prompts += 1
        today.promptChars += charCount
        dailyEntries[key] = today
    }

    /// Increment today's response count and the all-time counter.
    mutating func recordResponse(charCount: Int = 0) {
        totalResponses += 1
        totalResponseChars += charCount
        let key = Self.todayKey
        var today = dailyEntries[key] ?? DailyUsage()
        today.responses += 1
        today.responseChars += charCount
        dailyEntries[key] = today
    }

    /// Record a completed session in both all-time and today counts.
    mutating func recordSession(durationSeconds: TimeInterval) {
        totalSessions += 1
        totalAgentSeconds += durationSeconds
        let key = Self.todayKey
        var today = dailyEntries[key] ?? DailyUsage()
        today.sessions += 1
        dailyEntries[key] = today
    }

    /// Prune daily entries older than 30 days.
    /// All-time totals are preserved — only per-day granularity is dropped.
    mutating func pruneOldEntries() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -30,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()

        dailyEntries = dailyEntries.filter { key, _ in
            guard let date = Self.dateKeyFormatter.date(from: key) else { return true }
            return date >= cutoff
        }
    }
}

// MARK: - Helpers

/// Format a past date as a relative duration string like "2m ago", "14h ago"
func formatDurationSince(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "\(Int(interval))s ago" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}

func formatDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = Int(max(0, interval))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
}

func formatTimeRemaining(elapsed: TimeInterval, progress: Double, estimatedEnd: Date?) -> String {
    if let end = estimatedEnd {
        let remaining = max(0, end.timeIntervalSinceNow)
        if remaining < 60 {
            return "<1m left"
        }
        return "~\(Int(remaining / 60))m left"
    }
    // Estimate from progress
    guard progress > 0.01 else { return "..." }
    let total = elapsed / progress
    let remaining = total - elapsed
    if remaining < 60 {
        return "<1m left"
    }
    return "~\(Int(remaining / 60))m left"
}
