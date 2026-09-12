import SwiftUI
import KomgaStore
import KomgaDiagnostics

/// The media library browser. Reads series / books / collections /
/// readlists / progress from `LibraryViewModel`, which only ever reads the
/// local store (本地数据库负责展示); network is confined to sync/demo/cover
/// actions. Everything works with the network disconnected.
struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var showAdd = false
    @State private var showServers = false
    @State private var showSettings = false
    @State private var showOutbox = false
    @State private var showDownloads = false
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Stage 5 sync state (`sync_state`) shown where the shelf is read. The
    /// library stays browsable through every one of these states.
    private var syncStatusLine: some View {
        HStack(spacing: 6) {
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Text(model.syncStatusLabel)
                .font(.caption)
                .foregroundStyle(model.syncError == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            // Stage 6: queued client writes and what the event stream proved.
            if model.outboxPending > 0 || model.outboxCounts.failed > 0 {
                Button {
                    showOutbox = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: model.outboxCounts.failed > 0 ? "exclamationmark.icloud" : "arrow.up.icloud")
                            .font(.caption2)
                        Text(model.outboxCounts.failed > 0 ? "\(model.outboxCounts.failed) 项失败" : "待上传 \(model.outboxPending)")
                            .font(.caption)
                    }
                    .foregroundStyle(model.outboxCounts.failed > 0 ? Color.red : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("outbox-pending")
            }
            if let live = model.liveSyncStatus {
                Text(live)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("live-sync-status")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .accessibilityIdentifier("sync-status")
    }

    var body: some View {
        NavigationStack {
            if let error = model.startupError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("数据库打开失败")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("本地数据库无法初始化或损坏，已禁止操作以避免数据覆盖：\n\(error.localizedDescription)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试打开") {
                        model.retryStartup()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .navigationTitle("启动错误")
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("书架").tag(0)
                        Text("合集").tag(1)
                        Text("书单").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                    syncStatusLine

                    if let syncErr = model.syncError {
                        ErrorBannerView(
                            presentation: AppErrorPresentation.from(CoreError(code: .unknown, message: syncErr)),
                            onRetry: { Task { await model.reconcile(trigger: .manualRefresh) } },
                            onReauth: { showServers = true },
                            onDismiss: { model.syncError = nil }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                    }

                    switch tab {
                    case 1: CollectionsView(model: model)
                    case 2: ReadlistsView(model: model)
                    default: shelfView
                    }
                }
                .navigationTitle(model.server?.displayName ?? "Library")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button("演示") { Task { await model.loadFullDemo() } }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            LibrariesListView(model: model)
                        } label: {
                            Label("图书馆", systemImage: "books.vertical")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showDownloads = true
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .accessibilityIdentifier("downloads-button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("settings-button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        serverMenu
                    }
                    #else
                    ToolbarItem {
                        Button("演示") { Task { await model.loadFullDemo() } }
                    }
                    ToolbarItem {
                        NavigationLink {
                            LibrariesListView(model: model)
                        } label: {
                            Label("图书馆", systemImage: "books.vertical")
                        }
                    }
                    ToolbarItem {
                        Button {
                            showDownloads = true
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                        }
                        .accessibilityIdentifier("downloads-button")
                    }
                    ToolbarItem {
                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .keyboardShortcut(",", modifiers: .command)
                        .accessibilityIdentifier("settings-button")
                    }
                    ToolbarItem {
                        Button {
                            Task { await model.reconcile(trigger: .manualRefresh) }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .accessibilityIdentifier("refresh-button")
                    }
                    ToolbarItem {
                        serverMenu
                    }
                    #endif
                }
                .refreshable { await model.reconcile(trigger: .manualRefresh) }
            }
        }
        .task { await initialLoad() }
        .onChange(of: scenePhase) { _, phase in
            // Stage 6: the event stream and the Outbox uploader belong to the
            // foreground only. Backgrounding drops the socket without a sweep;
            // coming back reconnects and reconciles what the gap may have missed.
            switch phase {
            case .active:
                Task { await model.enterForeground() }
            case .background:
                model.enterBackground()
            default:
                break
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServerView(model: model, existing: nil)
        }
        .sheet(isPresented: $showServers) {
            ServersView(model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showOutbox) {
            OutboxSheet(model: model)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView(model: model)
        }
        .preferredColorScheme(model.colorScheme)
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                Banner(text: banner)
            }
        }
    }

    /// 当前服务器快速切换 + 管理入口.
    private var serverMenu: some View {
        Menu {
            if model.servers.isEmpty {
                Text("暂无服务器")
            } else {
                ForEach(model.servers) { profile in
                    Button {
                        Task { await model.switchServer(to: profile) }
                    } label: {
                        if profile.id == model.server?.id {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                }
            }
            Divider()
            Button {
                showAdd = true
            } label: {
                Label("添加服务器…", systemImage: "plus")
            }
            Button {
                showServers = true
            } label: {
                Label("管理服务器…", systemImage: "server.rack")
            }
        } label: {
            if let server = model.server {
                Label(server.displayName, systemImage: "server.rack")
            } else {
                Image(systemName: "server.rack")
            }
        }
    }

    // MARK: - Shelf tab (书架)

    private var shelfView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                searchField
                libraryChips
                shelfControls
                if !model.continueReading.isEmpty {
                    continueReadingShelf
                }
                if model.series.isEmpty {
                    emptyShelfView
                } else {
                    seriesGrid
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var emptyShelfView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 32)
            if model.server == nil {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("未配置服务器")
                    .font(.headline)
                Text("请添加 Komga 服务器或加载演示媒体库以浏览漫画。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                HStack(spacing: 12) {
                    Button("添加服务器") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                    Button("加载演示媒体库") {
                        Task { await model.loadFullDemo() }
                    }
                    .buttonStyle(.bordered)
                }
            } else if !model.searchText.isEmpty || model.selectedLibraryID != nil || model.selectedStatus != nil || model.selectedTag != nil || model.selectedGenre != nil {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("未找到匹配的漫画系列")
                    .font(.headline)
                Text("尝试更改搜索词或清除筛选条件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if model.server?.id == "demo" {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("演示媒体库为空")
                    .font(.headline)
                Button("重新加载演示内容") {
                    Task { await model.loadFullDemo() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("媒体库暂无系列")
                    .font(.headline)
                Text("已连接服务器「\(model.server?.displayName ?? "")」，但本地尚未同步或服务器为空。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("立即手动同步") {
                    Task { await model.reconcile(trigger: .manualRefresh) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshing)
            }
            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var searchField: some View {
        TextField("搜索 Series（本地 FTS）…", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .onChange(of: model.searchText) { _, _ in
                scheduleSeriesReload()
            }
    }

    /// Debounced reload: local queries are fast, but keystrokes are not
    /// worth a query each.
    private func scheduleSeriesReload() {
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            model.loadSeriesWall(reset: true)
        }
    }

    private var libraryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部 \(model.seriesTotal)", selected: model.selectedLibraryID == nil) {
                    model.selectedLibraryID = nil
                    model.loadSeriesWall(reset: true)
                }
                ForEach(model.libraries, id: \.remoteID) { lib in
                    chip(title: "\(lib.name) \(lib.seriesCount)", selected: model.selectedLibraryID == lib.remoteID) {
                        model.selectedLibraryID = lib.remoteID
                        model.loadSeriesWall(reset: true)
                    }
                }
            }
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(selected ? Color.accentColor : Color.gray.opacity(0.22))
                )
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var shelfControls: some View {
        HStack {
            Menu {
                Button("全部状态") { model.selectedStatus = nil; model.loadSeriesWall(reset: true) }
                ForEach(model.filterOptions.statuses, id: \.self) { status in
                    Button(status) { model.selectedStatus = status; model.loadSeriesWall(reset: true) }
                }
            } label: {
                Label(model.selectedStatus ?? "状态", systemImage: "line.3.horizontal.decrease.circle")
            }
            Menu {
                Button("全部标签") { model.selectedTag = nil; model.loadSeriesWall(reset: true) }
                ForEach(model.filterOptions.tags, id: \.self) { tag in
                    Button(tag) { model.selectedTag = tag; model.loadSeriesWall(reset: true) }
                }
            } label: {
                Label(model.selectedTag ?? "标签", systemImage: "tag")
            }
            Menu {
                Button("全部题材") { model.selectedGenre = nil; model.loadSeriesWall(reset: true) }
                ForEach(model.filterOptions.genres, id: \.self) { genre in
                    Button(genre) { model.selectedGenre = genre; model.loadSeriesWall(reset: true) }
                }
            } label: {
                Label(model.selectedGenre ?? "题材", systemImage: "theatermasks")
            }
            Spacer()
            Menu {
                Picker("排序", selection: $model.seriesSort) {
                    Text("名称").tag("name")
                    Text("排序名").tag("sortName")
                    Text("加入日期").tag("dateAdded")
                    Text("最近更新").tag("dateUpdated")
                    Text("册数").tag("booksCount")
                }
            } label: {
                Label(sortLabel, systemImage: "arrow.up.arrow.down")
            }
            Button {
                model.seriesAscending.toggle()
                model.loadSeriesWall(reset: true)
            } label: {
                Image(systemName: model.seriesAscending ? "arrow.up" : "arrow.down")
            }
        }
        .font(.footnote)
        .onChange(of: model.seriesSort) { _, _ in
            model.loadSeriesWall(reset: true)
        }
    }

    private var sortLabel: String {
        switch model.seriesSort {
        case "sortName": return "排序名"
        case "dateAdded": return "加入日期"
        case "dateUpdated": return "最近更新"
        case "booksCount": return "册数"
        default: return "名称"
        }
    }

    private var continueReadingShelf: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("继续阅读").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.continueReading) { row in
                        NavigationLink {
                            SeriesDetailView(seriesID: row.seriesID, model: model)
                        } label: {
                            ContinueReadingCard(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var seriesGrid: some View {
        LazyVGrid(
            columns: model.gridColumns,
            spacing: model.gridSpacing
        ) {
            ForEach(model.series) { item in
                NavigationLink {
                    SeriesDetailView(seriesID: item.remoteID, model: model)
                } label: {
                    SeriesCell(record: item, data: model.covers[item.remoteID])
                        .task { await model.refreshCover(item) }
                }
                .buttonStyle(.plain)
                .onAppear {
                    // Infinite scroll: load the next page near the end.
                    if item.remoteID == model.series.last?.remoteID {
                        model.loadMoreSeries()
                    }
                }
            }
        }
    }

    private func initialLoad() async {
        model.refreshSyncState()
        if model.server != nil {
            model.startSyncTriggers()
            await model.syncLibrary(trigger: .appLaunch)
        } else {
            try? model.syncMediaState()
            model.loadSeriesWall(reset: true)
        }
    }
}

// MARK: - Continue reading card

private struct ContinueReadingCard: View {
    let row: ContinueReadingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.seriesName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(row.bookTitle)
                .font(.caption)
                .lineLimit(2)
            ProgressView(value: Double(row.progressPercent ?? 0), total: 100)
                .tint(.accentColor)
            Text("第 \(row.page.map(String.init) ?? "?") / \(row.totalPages.map(String.init) ?? "?") 页")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 170)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Transient status banner.
private struct Banner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom))
    }
}