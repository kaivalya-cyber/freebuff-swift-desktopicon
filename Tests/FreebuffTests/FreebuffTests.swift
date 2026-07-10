import XCTest
@testable import Freebuff

@MainActor
final class FreebuffTests: XCTestCase {

    // MARK: - parseGitShortstat Tests

    func testParseGitShortstat_StandardFormat() {
        let output = " 2 files changed, 15 insertions(+), 7 deletions(-)"
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.added, 15)
        XCTAssertEqual(result?.removed, 7)
    }

    func testParseGitShortstat_OnlyInsertions() {
        let output = " 1 file changed, 10 insertions(+)"
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.added, 10)
        XCTAssertEqual(result?.removed, 0)
    }

    func testParseGitShortstat_OnlyDeletions() {
        let output = " 1 file changed, 5 deletions(-)"
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.added, 0)
        XCTAssertEqual(result?.removed, 5)
    }

    func testParseGitShortstat_MultilineIncludesStats() {
        let output = """
        commit abc123
        Author: Test User
        Date:   Mon Jul 7 2025

            Fix the bug

         3 files changed, 42 insertions(+), 8 deletions(-)
        """
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.added, 42)
        XCTAssertEqual(result?.removed, 8)
    }

    func testParseGitShortstat_NoStats() {
        let output = "commit abc123\nAuthor: Test\nDate: ...\n\n    No changes"
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNil(result)
    }

    func testParseGitShortstat_EmptyString() {
        let result = StatusViewModel.parseGitShortstatTestHelper("")
        XCTAssertNil(result)
    }

    func testParseGitShortstat_LargeNumbers() {
        let output = " 50 files changed, 12345 insertions(+), 9876 deletions(-)"
        let result = StatusViewModel.parseGitShortstatTestHelper(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.added, 12345)
        XCTAssertEqual(result?.removed, 9876)
    }

    // MARK: - filteredHistory Tests

    func testFilteredHistory_AllDefaults_ReturnsAll() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.filteredHistory.count, 4)
    }

    func testFilteredHistory_StatusFilter_Completed() {
        let vm = makeViewModel()
        vm.historyFilterStatus = "completed"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.status == "completed" })
    }

    func testFilteredHistory_StatusFilter_Cancelled() {
        let vm = makeViewModel()
        vm.historyFilterStatus = "cancelled"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.status, "cancelled")
    }

    func testFilteredHistory_DateFilter_Today() {
        let vm = makeViewModel()
        vm.historyFilterDate = "today"
        let result = vm.filteredHistory
        // Only entries with endedDate >= start of today should appear
        let startOfToday = Calendar.current.startOfDay(for: Date())
        XCTAssertTrue(result.allSatisfy { ($0.endedDate ?? .distantPast) >= startOfToday })
    }

    func testFilteredHistory_DateFilter_Week() {
        let vm = makeViewModel()
        vm.historyFilterDate = "week"
        let result = vm.filteredHistory
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        XCTAssertTrue(result.allSatisfy { ($0.endedDate ?? .distantPast) >= weekAgo })
    }

    func testFilteredHistory_DateFilter_Month() {
        let vm = makeViewModel()
        vm.historyFilterDate = "month"
        let result = vm.filteredHistory
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        XCTAssertTrue(result.allSatisfy { ($0.endedDate ?? .distantPast) >= monthAgo })
    }

    func testFilteredHistory_TextSearch_MatchesTaskName() {
        let vm = makeViewModel()
        vm.historySearchText = "refactor"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.task, "refactor the auth module")
    }

    func testFilteredHistory_TextSearch_CaseInsensitive() {
        let vm = makeViewModel()
        vm.historySearchText = "REFACTOR"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 1)
    }

    func testFilteredHistory_TextSearch_NoMatch() {
        let vm = makeViewModel()
        vm.historySearchText = "nonexistent"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 0)
    }

    func testFilteredHistory_ChainedFilters_StatusAndDate() {
        let vm = makeViewModel()
        vm.historyFilterStatus = "completed"
        vm.historyFilterDate = "today"
        let result = vm.filteredHistory
        XCTAssertTrue(result.allSatisfy { $0.status == "completed" })
        let startOfToday = Calendar.current.startOfDay(for: Date())
        XCTAssertTrue(result.allSatisfy { ($0.endedDate ?? .distantPast) >= startOfToday })
    }

    func testFilteredHistory_ChainedFilters_StatusAndText() {
        let vm = makeViewModel()
        vm.historyFilterStatus = "completed"
        vm.historySearchText = "fix"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.task, "fix the login bug")
    }

    func testFilteredHistory_ChainedFilters_AllThree() {
        let vm = makeViewModel()
        vm.historyFilterStatus = "completed"
        vm.historyFilterDate = "month"
        vm.historySearchText = "ui"
        let result = vm.filteredHistory
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.task, "update the UI components")
    }

    // MARK: - Helpers

    private func makeViewModel() -> StatusViewModel {
        let vm = StatusViewModel()
        let now = Date()
        let iso = ISO8601DateFormatter()

        // Today (completed)
        let todayStart = iso.string(from: now.addingTimeInterval(-1800)) // 30 min ago
        let todayEnd = iso.string(from: now)

        // Yesterday (completed) — use exactly 24h ago to be safe from time-of-day edge cases
        let yesterdayStart = iso.string(from: now.addingTimeInterval(-90000))
        let yesterdayEnd = iso.string(from: now.addingTimeInterval(-86400))

        // 3 days ago (completed)
        let threeDaysStart = iso.string(from: now.addingTimeInterval(-259200))
        let threeDaysEnd = iso.string(from: now.addingTimeInterval(-258000))

        // 2 months ago (cancelled)
        let twoMonthsStart = iso.string(from: now.addingTimeInterval(-5184000))
        let twoMonthsEnd = iso.string(from: now.addingTimeInterval(-5180000))

        vm.fullHistory = [
            HistoryEntry(id: "1", task: "fix the login bug", started_at: todayStart, ended_at: todayEnd, status: "completed", lines_added: 10, lines_removed: 3),
            HistoryEntry(id: "2", task: "update the UI components", started_at: yesterdayStart, ended_at: yesterdayEnd, status: "completed", lines_added: 42, lines_removed: 15),
            HistoryEntry(id: "3", task: "refactor the auth module", started_at: threeDaysStart, ended_at: threeDaysEnd, status: "completed", lines_added: 100, lines_removed: 80),
            HistoryEntry(id: "4", task: "add dark mode support", started_at: twoMonthsStart, ended_at: twoMonthsEnd, status: "cancelled", lines_added: nil, lines_removed: nil),
        ]
        return vm
    }
}

// MARK: - Test helper to expose private static method

extension StatusViewModel {
    /// Expose the private static parseGitShortstat for testing
    static func parseGitShortstatTestHelper(_ output: String) -> (added: Int, removed: Int)? {
        return parseGitShortstat(output)
    }
}
