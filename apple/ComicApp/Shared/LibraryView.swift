import SwiftUI
import KomgaStore

/// The Phase 0 cover wall. Reads series + covers from `LibraryViewModel`,
/// which only ever reads the local store; network is confined to sync/cover.
struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var showAdd = false

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
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    #else
                    ToolbarItem {
                        Button("演示") { Task { await model.loadDemo() } }
                    }
                    ToolbarItem {
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    #endif
                }
                .refreshable { await model.bootstrap() }
        }
        .task { await initialLoad() }
        .sheet(isPresented: $showAdd) {
            AddServerView(onSave: { name, url, key in
                showAdd = false
                Task { await model.addServer(displayName: name, baseURL: url, apiKey: key) }
            })
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                Banner(text: banner)
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
