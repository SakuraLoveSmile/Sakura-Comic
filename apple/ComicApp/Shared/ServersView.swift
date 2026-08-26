import SwiftUI
import KomgaStore

/// 服务器管理：列表 / 切换 / 编辑 / 删除 / 添加.
///
/// 所有远端实体都以 (serverId, remoteId) 隔离；这里只维护全局的
/// 「当前服务器」状态（app_state.active_server_id）。
struct ServersView: View {
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editTarget: ServerProfile?
    @State private var deleteTarget: ServerProfile?

    var body: some View {
        NavigationStack {
            List {
                if model.servers.isEmpty {
                    ContentUnavailableView {
                        Label("暂无服务器", systemImage: "server.rack")
                    } description: {
                        Text("添加一个 Komga 服务器开始连接")
                    }
                } else {
                    ForEach(model.servers) { profile in
                        ServerRow(
                            profile: profile,
                            isActive: profile.id == model.server?.id,
                            onSwitch: { Task { await model.switchServer(to: profile) } }
                        )
                        .contextMenu {
                            Button("编辑") { editTarget = profile }
                            Button("删除", role: .destructive) { deleteTarget = profile }
                        }
                        #if !os(tvOS)
                        .swipeActions {
                            Button("删除", role: .destructive) { deleteTarget = profile }
                            if profile.id != model.server?.id {
                                Button("切换") { Task { await model.switchServer(to: profile) } }
                                    .tint(.green)
                            }
                        }
                        #endif
                    }
                }
            }
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editTarget = nil
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddServerView(model: model, existing: editTarget)
            }
            .confirmationDialog(
                "删除「\(deleteTarget?.displayName ?? "")」？",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = deleteTarget {
                        deleteTarget = nil
                        Task { await model.deleteServer(target) }
                    }
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            }
        }
    }
}

/// One server row: identity + capabilities + active marker.
private struct ServerRow: View {
    let profile: ServerProfile
    let isActive: Bool
    let onSwitch: () -> Void

    var body: some View {
        Button(action: onSwitch) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.headline)
                        if isActive {
                            Text("当前")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text(profile.baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !profile.capabilities.isEmpty || profile.lastSuccessfulConnection != nil {
                        Text(capabilitySummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var capabilitySummary: String {
        var parts = profile.capabilities
        if let last = profile.lastSuccessfulConnection {
            parts.append("最近连接 \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}