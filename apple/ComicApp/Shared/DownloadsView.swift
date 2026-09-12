import SwiftUI
import KomgaDownloads
import KomgaReader

/// The offline downloads queue and storage manager.
struct DownloadsView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var sweepReport: RecoveryReport?
    @State private var showingSweepAlert = false
    @State private var isSweeping = false
    @State private var activeReaderModel: ReaderModel?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useAll]
        return f
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                storageHeader

                if model.downloads.isEmpty {
                    emptyState
                } else {
                    downloadsList
                }
            }
            .navigationTitle("离线下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await runSweep() }
                    } label: {
                        if isSweeping {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("检查修复", systemImage: "wrench.and.screwdriver")
                        }
                    }
                    .disabled(isSweeping)
                }
            }
            .alert("存储一致性检查", isPresented: $showingSweepAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                if let report = sweepReport {
                    if report.totalRepairs == 0 {
                        Text("下载内容完好，未发现不一致。共扫描了 \(report.booksScanned) 本书。")
                    } else {
                        Text("修复完成：清除残余分块 \(report.stalePartsRemoved) 个，修复幽灵记录 \(report.ghostRowsRepaired) 条，收录脱机文件 \(report.filesAdopted) 个，重算计数 \(report.countersRepaired) 项。")
                    }
                }
            }
            .task {
                await model.refreshDownloads()
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $activeReaderModel) { reader in
            NavigationStack {
                ReaderScreen(model: reader)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { activeReaderModel = nil }
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        #else
        .sheet(item: $activeReaderModel) { reader in
            NavigationStack {
                ReaderScreen(model: reader)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { activeReaderModel = nil }
                        }
                    }
            }
        }
        #endif
    }

    private var storageHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("已占用离线空间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.byteFormatter.string(fromByteCount: model.downloadStorageBytes))
                    .font(.title2)
                    .fontWeight(.bold)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("已下载总页数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(model.downloadPageCount) 页")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("还没有下载")
                .font(.headline)
            Text("在漫画详情页面点击「下载」即可离线阅读。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var downloadsList: some View {
        List {
            ForEach(model.downloads, id: \.bookId) { item in
                downloadRow(item)
            }
        }
        .listStyle(.plain)
    }

    private func downloadRow(_ item: DownloadRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.bookTitle ?? item.bookId)
                        .font(.headline)
                        .lineLimit(1)
                    if let series = item.seriesTitle, !series.isEmpty {
                        Text(series)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                statusBadge(item.state)
            }

            if item.pagesTotal > 0 {
                ProgressView(value: Double(item.pagesDone), total: Double(item.pagesTotal))
                    .tint(progressColor(for: item.state))
            }

            HStack {
                Text("\(item.pagesDone) / \(item.pagesTotal) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.bytesDone > 0 {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.byteFormatter.string(fromByteCount: item.bytesDone))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    if item.state == BookState.completed.rawValue {
                        Button {
                            #if os(macOS)
                            openWindow(id: "reader", value: "\(item.serverId):\(item.bookId)")
                            #else
                            activeReaderModel = model.readerModel(serverID: item.serverId, bookID: item.bookId)
                            #endif
                        } label: {
                            Label("阅读", systemImage: "book.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if item.state == BookState.downloading.rawValue || item.state == BookState.waiting.rawValue {
                        Button {
                            Task { await model.pauseDownload(bookID: item.bookId) }
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if item.state == BookState.paused.rawValue {
                        Button {
                            Task { await model.resumeDownload(bookID: item.bookId) }
                        } label: {
                            Label("继续", systemImage: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if item.state == BookState.failed.rawValue {
                        Button {
                            Task { await model.retryDownload(bookID: item.bookId) }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(role: .destructive) {
                        Task { await model.deleteDownload(bookID: item.bookId) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let err = item.lastError, !err.isEmpty && item.state == BookState.failed.rawValue {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private func statusBadge(_ state: String) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case BookState.waiting.rawValue: return ("等待中", .secondary)
            case BookState.downloading.rawValue: return ("下载中", .blue)
            case BookState.paused.rawValue: return ("已暂停", .orange)
            case BookState.completed.rawValue: return ("已完成", .green)
            case BookState.failed.rawValue: return ("失败", .red)
            default: return (state, .secondary)
            }
        }()

        return Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func progressColor(for state: String) -> Color {
        switch state {
        case BookState.downloading.rawValue: return .blue
        case BookState.completed.rawValue: return .green
        case BookState.paused.rawValue: return .orange
        case BookState.failed.rawValue: return .red
        default: return .secondary
        }
    }

    private func runSweep() async {
        isSweeping = true
        defer { isSweeping = false }
        sweepReport = await model.sweepDownloads()
        showingSweepAlert = true
    }
}
