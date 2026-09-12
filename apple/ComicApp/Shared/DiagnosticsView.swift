import SwiftUI
import KomgaStore
import KomgaDiagnostics

struct DiagnosticsView: View {
    @ObservedObject var model: LibraryViewModel

    @State private var snapshot: DiagnosticsSnapshot?
    @State private var logs: [CoreLog.Record] = []
    @State private var selectedLevelFilter: String = "all"
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copiedAlert = false

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("读取诊断快照...")
                        Spacer()
                    }
                }
            } else if let error = errorMessage {
                Section {
                    Text("读取诊断快照失败：\(error)")
                        .foregroundStyle(.red)
                }
            } else if let snap = snapshot {
                databaseSection(snap)
                authAndSyncSection(snap)
                outboxSection(snap)
                storageSection(snap)
                logStatsSection(snap)
                logsSection
                exportSection(snap)
            }
        }
        .navigationTitle("系统诊断与日志")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    loadData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            loadData()
        }
        .alert("已复制脱敏诊断快照到剪贴板", isPresented: $copiedAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private func databaseSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("本地数据库健康 (SQLite)") {
            row("数据库模式", snap.db.journalMode.uppercased())
            row("完整性校验", snap.db.integrity)
            ForEach(snap.db.tables.sorted(by: { $0.table < $1.table }), id: \.table) { table in
                row("\(table.table) 表行数", "\(table.rows)")
            }
        }
    }

    private func authAndSyncSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("认证与同步状态") {
            row("服务器 ID", snap.serverId)
            row("凭据状态", snap.auth.state == "valid" ? "有效" : (snap.auth.state == "expired" ? "已失效" : "未确定"))
            if !snap.auth.at.isEmpty {
                row("凭据更新时间", snap.auth.at)
            }
            ForEach(snap.sync, id: \.entityType) { item in
                row("\(humanEntityType(item.entityType)) 游标", item.syncCursor ?? "无 (全量完成)")
                if let lastSync = item.lastSyncAt {
                    row("\(humanEntityType(item.entityType)) 最后同步", lastSync)
                }
                if let err = item.lastError {
                    row("\(humanEntityType(item.entityType)) 错误", err)
                }
            }
        }
    }

    private func outboxSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("写操作队列 (Outbox)") {
            row("待上传操作数", "\(snap.outbox.pending)")
            row("退避重试操作数", "\(snap.outbox.waiting)")
            row("已放弃/失败数", "\(snap.outbox.failed)")
            row("总积压行数 (SQL)", "\(snap.outboxQueuedRows)")
        }
    }

    private func storageSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("存储与缓存占用") {
            let cacheBytes = model.diskCacheSizeBytes()
            row("磁盘缓存总计", formatBytes(cacheBytes))
            row("已读页面缓存", formatBytes(Int64(snap.cache.pageBytes)))
            row("预拉取缓存", formatBytes(Int64(snap.cache.prefetchBytes)))
            row("账本记录总大小", formatBytes(Int64(snap.cache.ledgerBytes)))
            if !snap.cache.kinds.isEmpty {
                row("缓存分类", snap.cache.kinds.joined(separator: ", "))
            }

            if !snap.queue.isEmpty {
                ForEach(snap.queue, id: \.state) { queue in
                    row("离线下载 [\(queue.state)]", "\(queue.books) 本 · \(formatBytes(Int64(queue.bytesDone)))")
                }
            }
        }
    }

    private func logStatsSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("日志环统计 (CoreLog)") {
            row("缓冲区容量", "\(snap.log.capacity) 行")
            row("当前保留", "\(snap.log.retained) 行")
            row("已轮转丢弃", "\(snap.log.dropped) 行")
            row("错误数", "\(snap.log.errors)")
            row("警告数", "\(snap.log.warnings)")
            row("信息数", "\(snap.log.info)")
            if !snap.log.lastError.isEmpty {
                row("最新错误", snap.log.lastError)
            }
        }
    }

    private var logsSection: some View {
        Section("近期运行日志") {
            Picker("日志级别", selection: $selectedLevelFilter) {
                Text("全部").tag("all")
                Text("错误").tag("error")
                Text("警告").tag("warn")
                Text("信息").tag("info")
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedLevelFilter) { _, _ in
                loadLogs()
            }

            if logs.isEmpty {
                Text("暂无符合条件的日志记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logs.indices, id: \.self) { idx in
                    let record = logs[idx]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("[\(record.level.uppercased())]")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(colorForLevel(record.level))
                            Text(record.target)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(record.at)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(record.message)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func exportSection(_ snap: DiagnosticsSnapshot) -> some View {
        Section("脱敏诊断导出") {
            Button {
                let sanitized = generateRedactedReport(snap)
                #if os(iOS)
                UIPasteboard.general.string = sanitized
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sanitized, forType: .string)
                #endif
                copiedAlert = true
            } label: {
                Label("复制脱敏诊断报告", systemImage: "doc.on.doc")
            }

            ShareLink(
                item: generateRedactedReport(snap),
                subject: Text("Comic 诊断报告"),
                message: Text("包含数据库统计与运行日志环（已自动剔除密钥等机密信息）")
            ) {
                Label("导出并分享诊断报告", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadData() {
        isLoading = true
        errorMessage = nil
        guard let store = model.store, let server = model.server else {
            errorMessage = "未选择有效服务器或数据库未就绪"
            isLoading = false
            return
        }

        do {
            snapshot = try store.diagnosticsSnapshot(serverID: server.id)
            loadLogs()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadLogs() {
        let filter: String? = selectedLevelFilter == "all" ? nil : selectedLevelFilter
        logs = DiagnosticsSanitizer.redactedLogs(limit: 100, minLevel: filter)
    }

    private func colorForLevel(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": return .red
        case "warn", "warning": return .orange
        case "info": return .blue
        default: return .secondary
        }
    }

    private func humanEntityType(_ type: String) -> String {
        switch type {
        case "series": return "系列"
        case "books": return "书籍"
        case "collections": return "合集"
        case "readlists": return "书单"
        case "full": return "全量汇总"
        default: return type
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func generateRedactedReport(_ snap: DiagnosticsSnapshot) -> String {
        var copy = snap
        // Redact any identifiers or URLs that might leak private keys or network locations
        copy.serverId = DiagnosticsSanitizer.redactServerID(copy.serverId)
        copy.auth.serverId = copy.serverId
        copy.sync = copy.sync.map { row in
            var r = row
            if let err = r.lastError {
                r.lastError = DiagnosticsSanitizer.redact(err)
            }
            return r
        }
        if !copy.log.lastError.isEmpty {
            copy.log.lastError = DiagnosticsSanitizer.redact(copy.log.lastError)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        // Add recent logs tail (sanitized)
        var report = "=== COMIC DIAGNOSTICS REPORT ===\n"
        report += "Generated: \(Date().description)\n\n"
        report += "--- SNAPSHOT JSON ---\n"
        report += jsonStr + "\n\n"
        report += "--- RECENT LOGS (TAIL 50) ---\n"
        for log in DiagnosticsSanitizer.redactedLogs(limit: 50) {
            report += "[\(log.at)] [\(log.level.uppercased())] [\(log.target)] \(log.message)\n"
        }
        return report
    }
}
