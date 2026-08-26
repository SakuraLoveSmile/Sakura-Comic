import SwiftUI
import KomgaStore

/// The library cover wall. Reads series + covers from `LibraryViewModel`,
/// which only ever reads the local store; network is confined to sync/cover.
/// Server management (switch / add / manage) lives behind the toolbar.
struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var showAdd = false
    @State private var showServers = false

    var body: some View {
        NavigationStack {
            bodyContent
                .navigationTitle("Library")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button("演示") { Task { await model.loadDemo() } }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        serverMenu
                    }
                    #else
                    ToolbarItem {
                        Button("演示") { Task { await model.loadDemo() } }
                    }
                    ToolbarItem {
                        serverMenu
                    }
                    #endif
                }
                .refreshable { await model.bootstrap() }
        }
        .task { await initialLoad() }
        .sheet(isPresented: $showAdd) {
            AddServerView(model: model, existing: nil)
        }
        .sheet(isPresented: $showServers) {
            ServersView(model: model)
        }
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

    @ViewBuilder
    private var bodyContent: some View {
        if model.series.isEmpty {
            ContentUnavailableView {
                Label("暂无 Series", systemImage: "books.vertical")
            } description: {
                Text("添加 Komga 服务器，或点“演示”加载本地数据")
            } actions: {
                Button("添加服务器") { showAdd = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(model.series) { item in
                        SeriesCell(record: item, data: model.covers[item.remoteID])
                            .task { await model.refreshCover(item) }
                    }
                }
                .padding()
            }
        }
    }

    private func initialLoad() async {
        if model.server != nil {
            await model.bootstrap()
        }
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