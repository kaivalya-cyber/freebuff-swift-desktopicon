import SwiftUI

/// A single row in the history list
struct HistoryRowView: View {
    let entry: HistoryEntry
    let onCopy: (() -> Void)?

    init(entry: HistoryEntry, onCopy: (() -> Void)? = nil) {
        self.entry = entry
        self.onCopy = onCopy
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status badge
            statusBadge

            // Task name + diff stats
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.task)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    Text(entry.durationString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let added = entry.lines_added, added > 0 {
                        Text("·").foregroundColor(.secondary.opacity(0.5)).font(.system(size: 9))
                        Text("+\(added)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                    if let removed = entry.lines_removed, removed > 0 {
                        Text("·").foregroundColor(.secondary.opacity(0.5)).font(.system(size: 9))
                        Text("-\(removed)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
            }

            Spacer()

            // Copy task button
            if let onCopy = onCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Copy task name")
            }

            // Time ago
            Text(entry.relativeTimeString)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var statusBadge: some View {
        Group {
            if entry.status == "running" {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
            } else if entry.status == "completed" {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }
}
