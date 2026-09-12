import SwiftUI
import KomgaStore

struct OutboxSheet: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [OutboxEntry] = []
    @State private var isRetrying = false
    @State private var bannerMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryHeader

                if let banner = bannerMessage {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                }

                if entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
            .navigationTitle("离线写操作队列")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if model.outboxCounts.failed > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await retryFailed() }
                        } label: {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("重试失败项")
                            }
                        }
                        .disabled(isRetrying)
                    }
                }
            }
            .onAppear {
                refresh()
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            statBadge(title: "待上传", count: model.outboxCounts.pending, color: .blue)
            statBadge(title: "等待退避", count: model.outboxCounts.waiting, color: .orange)
            statBadge(title: "已失败", count: model.outboxCounts.failed, color: .red)
        }
        .padding()
        .background(Color.gray.opacity(0.08))
    }

    private func statBadge(title: String, count: Int64, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(count > 0 ? color : .secondary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("没有待上传的离线写操作")
                .font(.headline)
            Text("所有本地阅读进度与标记均已同步至服务器。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryList: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                entryRow(entry)
            }
        }
        .listStyle(.plain)
    }

    private func entryRow(_ entry: OutboxEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(humanMutationType(entry.mutationType))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                statusPill(for: entry)
            }

            Text("实体 ID: \(entry.entityID)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let payloadInfo = humanPayload(entry) {
                Text(payloadInfo)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            HStack {
                Text("记录时间: \(entry.createdAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.retryCount > 0 {
                    Text("重试: \(entry.retryCount)/\(OutboxPolicy.maxAttempts)")
                        .font(.caption2)
                        .foregroundStyle(entry.retryCount >= OutboxPolicy.maxAttempts ? .red : .secondary)
                }
            }

            if let error = entry.lastError, !error.isEmpty {
                Text("失败原因: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }

            if let nextRetry = entry.nextRetryAt {
                Text("下次重试: \(nextRetry)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusPill(for entry: OutboxEntry) -> some View {
        let isFailed = entry.state == OutboxFamily.failed
        let isWaiting = entry.nextRetryAt != nil && entry.nextRetryAt! > outboxSecondText(Date())
        let text = isFailed ? "失败" : (isWaiting ? "等待退避" : "队列中")
        let color: Color = isFailed ? .red : (isWaiting ? .orange : .blue)

        return Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func humanMutationType(_ type: String) -> String {
        switch type {
        case "READ_PROGRESS": return "阅读进度"
        case "MARK_READ": return "标记已读"
        case "MARK_UNREAD": return "标记未读"
        default: return type
        }
    }

    private func humanPayload(_ entry: OutboxEntry) -> String? {
        if entry.mutationType == "READ_PROGRESS" {
            // Parse page and completed from JSON payload
            if let data = entry.payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let page = obj["page"] as? Int ?? 0
                let completed = obj["completed"] as? Bool ?? false
                return "第 \(page) 页" + (completed ? " (已读完)" : "")
            }
        }
        return nil
    }

    private func refresh() {
        entries = model.fetchOutboxEntries()
        if let server = model.server {
            model.refreshOutboxBadge(serverID: server.id)
        }
    }

    private func retryFailed() async {
        isRetrying = true
        defer { isRetrying = false }
        let reset = await model.retryFailedOutbox()
        bannerMessage = reset > 0 ? "已重新排队 \(reset) 项写操作" : "没有可重试的失败项"
        refresh()
    }
}
