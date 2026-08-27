import SwiftUI
import KomgaStore

// MARK: - Series detail (Metadata / Tags / Genres / Status / Books)

struct SeriesDetailView: View {
    let seriesID: String
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail = model.seriesDetail {
                    header(detail)
                    metadataSections(detail)
                    booksSection
                } else {
                    ProgressView("加载详情…")
                }
            }
            .padding()
        }
        .navigationTitle(model.seriesDetail?.name ?? "Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if let record = model.series.first(where: { $0.remoteID == seriesID }) {
                model.openSeries(record)
            } else {
                // Opened from a shelf: resolve via the store directly.
                model.openSeries(seriesID: seriesID)
            }
        }
    }

    private func header(_ detail: SeriesDetailRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let cover = model.covers[detail.remoteID] {
                platformImage(cover)?
                    .resizable()
                    .scaledToFill()
                    .frame(width: 110, height: 165)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name).font(.title2.bold())
                if let status = detail.status {
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.18))
                        )
                }
                Text("共 \(detail.booksCount ?? 0) 册 · 已读 \(detail.booksReadCount ?? 0) · 未读 \(detail.booksUnreadCount ?? 0) · 阅读中 \(detail.booksInProgressCount ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func metadataSections(_ detail: SeriesDetailRecord) -> some View {
        if let summary = detail.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("简介").font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        if !detail.authors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("作者").font(.headline)
                Text(detail.authors.map { $0.role.isEmpty ? $0.name : "\($0.name)（\($0.role)）" }.joined(separator: "、"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 16) {
            if let publisher = detail.publisher {
                infoCell("出版社", publisher)
            }
            if let language = detail.language {
                infoCell("语言", language)
            }
            if let direction = detail.readingDirection {
                infoCell("阅读方向", direction)
            }
            if let rating = detail.ageRating {
                infoCell("分级", rating)
            }
        }
        if !detail.tags.isEmpty {
            chipRow("标签", detail.tags)
        }
        if !detail.genres.isEmpty {
            chipRow("题材", detail.genres)
        }
        if !detail.collections.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("所属合集").font(.headline)
                HStack(spacing: 8) {
                    ForEach(detail.collections, id: \.remoteID) { ref in
                        NavigationLink(destination: CollectionDetailView(collectionID: ref.remoteID, name: ref.name, model: model)) {
                            Text(ref.name)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }

    private func chipRow(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.gray.opacity(0.18))
                            )
                    }
                }
            }
        }
    }

    // MARK: Books

    private var booksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Books · \(model.booksTotal)").font(.headline)
            HStack {
                Picker("阅读状态", selection: $model.bookReadFilter) {
                    Text("全部").tag(String?.none)
                    Text("未读").tag(String?.some("unread"))
                    Text("进行中").tag(String?.some("in_progress"))
                    Text("已读").tag(String?.some("read"))
                }
                .pickerStyle(.menu)
                .onChange(of: model.bookReadFilter) { _, _ in
                    reloadBooks()
                }
                Spacer()
                Picker("排序", selection: $model.bookSort) {
                    Text("册数").tag("number")
                    Text("标题").tag("title")
                }
                .pickerStyle(.menu)
                .onChange(of: model.bookSort) { _, _ in
                    reloadBooks()
                }
            }
            ForEach(model.books) { book in
                BookRowView(book: book, model: model)
                    .task { await model.refreshBookCover(book) }
                    .onAppear {
                        if book.id == model.books.last?.id {
                            loadMoreBooks()
                        }
                    }
            }
        }
    }

    private func reloadBooks() {
        model.loadBooks(seriesID: seriesID, reset: true)
    }

    private func loadMoreBooks() {
        if model.books.count < model.booksTotal {
            model.loadBooks(seriesID: seriesID, reset: false)
        }
    }
}

// MARK: - Book row + detail sheet

private struct BookRowView: View {
    let book: BookRecord
    @ObservedObject var model: LibraryViewModel
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail = true
        } label: {
            HStack(spacing: 10) {
                if let cover = model.bookCovers[book.remoteID], let image = platformImage(cover) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 42, height: 63)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 42, height: 63)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        readStatusIcon
                        Text(book.title).font(.subheadline).lineLimit(2)
                    }
                    if let number = book.number {
                        Text("第 \(number) 册").font(.caption).foregroundStyle(.secondary)
                    }
                    if let page = book.progressPage, !book.progressCompleted {
                        Text("读到 \(page) / \(book.pagesCount ?? 0) 页")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            BookDetailView(book: book, model: model)
        }
    }

    @ViewBuilder
    private var readStatusIcon: some View {
        if book.progressCompleted {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else if let page = book.progressPage, page > 0 {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange).font(.caption)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Book metadata + 阅读状态 actions (本地优先).
private struct BookDetailView: View {
    let book: BookRecord
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(book.title).font(.title3.bold())
                    if let seriesTitle = book.seriesTitle {
                        Text(seriesTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(spacing: 16) {
                        if let number = book.number {
                            infoCell("册数", number)
                        }
                        if let pages = book.pagesCount {
                            infoCell("页数", String(pages))
                        }
                        if let mediaType = book.mediaType {
                            infoCell("类型", mediaType)
                        }
                    }
                    if book.progressCompleted {
                        Text("阅读状态：已读").font(.subheadline).foregroundStyle(.green)
                    } else if let page = book.progressPage, page > 0, let total = book.pagesCount {
                        Text("阅读状态：读到 \(page) / \(total) 页（\(page * 100 / max(total, 1))%）")
                            .font(.subheadline).foregroundStyle(.orange)
                    } else {
                        Text("阅读状态：未读").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("标记已读") {
                            model.markRead(book)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("标记未读") {
                            model.markUnread(book)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider()
                    if let detail = try? model.bookDetail(for: book) {
                        if let summary = detail.summary, !summary.isEmpty {
                            Text("简介").font(.headline)
                            Text(summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !detail.tags.isEmpty {
                            Text("标签").font(.headline)
                            Text(detail.tags.joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Book")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }
}

// MARK: - Collections (合集)

struct CollectionsView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        List {
            ForEach(model.collections, id: \.remoteID) { collection in
                NavigationLink {
                    CollectionDetailView(collectionID: collection.remoteID, name: collection.name, model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name).font(.subheadline)
                        if collection.ordered {
                            Text("手动排序").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.collections.isEmpty {
                ContentUnavailableView("暂无合集", systemImage: "square.stack.3d.up")
            }
        }
    }
}

struct CollectionDetailView: View {
    let collectionID: String
    let name: String
    @ObservedObject var model: LibraryViewModel
    @State private var members: [SeriesRecord] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
                spacing: 12
            ) {
                ForEach(members) { item in
                    NavigationLink {
                        SeriesDetailView(seriesID: item.remoteID, model: model)
                    } label: {
                        SeriesCell(record: item, data: model.covers[item.remoteID])
                            .task { await model.refreshCover(item) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(name)
        .task {
            guard !loaded else { return }
            loaded = true
            guard let server = model.server else { return }
            do {
                guard let detail = try model.store.collectionDetail(
                    serverID: server.id, collectionID: collectionID, limit: 200, offset: 0
                ) else { return }
                members = detail.members.items
            } catch {}
        }
    }
}

// MARK: - Readlists (书单)

struct ReadlistsView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        List {
            ForEach(model.readlists, id: \.remoteID) { readlist in
                NavigationLink {
                    ReadlistDetailView(readlistID: readlist.remoteID, name: readlist.name, model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(readlist.name).font(.subheadline)
                        if let summary = readlist.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.readlists.isEmpty {
                ContentUnavailableView("暂无书单", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

struct ReadlistDetailView: View {
    let readlistID: String
    let name: String
    @ObservedObject var model: LibraryViewModel
    @State private var books: [BookRecord] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(books) { book in
                BookListRow(book: book, model: model)
                    .task { await model.refreshBookCover(book) }
            }
        }
        .navigationTitle(name)
        .task {
            guard !loaded else { return }
            loaded = true
            guard let server = model.server else { return }
            do {
                guard let detail = try model.store.readlistDetail(
                    serverID: server.id, readlistID: readlistID, limit: 500, offset: 0
                ) else { return }
                books = detail.books.items
            } catch {}
        }
    }
}

private struct BookListRow: View {
    let book: BookRecord
    @ObservedObject var model: LibraryViewModel
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail = true
        } label: {
            HStack(spacing: 10) {
                if let cover = model.bookCovers[book.remoteID], let image = platformImage(cover) {
                    image.resizable().scaledToFill()
                        .frame(width: 36, height: 54)
                        .clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 36, height: 54)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline)
                    if let series = book.seriesTitle {
                        Text(series).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if book.progressCompleted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let page = book.progressPage, page > 0 {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            BookDetailView(book: book, model: model)
        }
    }
}

// MARK: - Library list (Library 列表 / 切换)

struct LibrariesListView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        List {
            Button {
                model.selectLibrary(id: nil)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全部 Series").font(.headline)
                        Text(
                            "共 \(model.libraries.reduce(0) { $0 + $1.seriesCount }) 个 Series · \(model.libraries.reduce(0) { $0 + $1.bookCount }) 本书"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.selectedLibraryID == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(model.libraries, id: \.remoteID) { lib in
                NavigationLink {
                    LibraryDetailView(libraryID: lib.remoteID, model: model)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lib.name).font(.headline)
                            Text("\(lib.seriesCount) Series · \(lib.bookCount) Books · 已读 \(lib.readCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let root = lib.root, !root.isEmpty {
                                Text(root)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if lib.unavailable {
                                Text("不可用").font(.caption2).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if model.selectedLibraryID == lib.remoteID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("图书馆")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if model.libraries.isEmpty {
                Text("尚未同步任何 Library").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Library detail (Library 详情)

struct LibraryDetailView: View {
    let libraryID: String
    @ObservedObject var model: LibraryViewModel

    @State private var detail: LibraryCountRecord?
    @State private var items: [SeriesRecord] = []
    @State private var total = 0
    @State private var search = ""
    @State private var errorMessage: String?

    private let pageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let detail {
                    stats(detail)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                TextField("在此库中搜索（本地 FTS）…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: search) { _, _ in reload() }
                seriesWall
                if items.count < total {
                    Button("加载更多（\(items.count) / \(total)）") { loadNextPage() }
                        .font(.footnote)
                }
            }
            .padding()
        }
        .navigationTitle(detail?.name ?? "Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button("设为书架筛选") { model.selectLibrary(id: libraryID) }
        }
        .task { load() }
    }

    private func stats(_ lib: LibraryCountRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                statTile("Series", lib.seriesCount)
                statTile("Books", lib.bookCount)
                statTile("已读", lib.readCount)
            }
            if lib.bookCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(lib.readCount), total: Double(lib.bookCount))
                    Text("阅读进度 \(lib.readCount) / \(lib.bookCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let root = lib.root, !root.isEmpty {
                Label(root, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if lib.unavailable {
                Label("服务端标记为不可用", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
        }
    }

    private func statTile(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var seriesWall: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
            spacing: 12
        ) {
            ForEach(items) { item in
                NavigationLink {
                    SeriesDetailView(seriesID: item.remoteID, model: model)
                } label: {
                    SeriesCell(record: item, data: model.covers[item.remoteID])
                        .task { await model.refreshCover(item) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() {
        do {
            detail = try model.libraryDetail(id: libraryID)
        } catch {
            errorMessage = "读取 Library 失败：\(error.localizedDescription)"
        }
        reload()
    }

    private func reload() {
        do {
            let page = try model.librarySeries(
                id: libraryID,
                search: search.isEmpty ? nil : search,
                limit: pageSize,
                offset: 0
            )
            items = page.items
            total = page.total
            errorMessage = nil
        } catch {
            errorMessage = "查询失败：\(error.localizedDescription)"
        }
    }

    private func loadNextPage() {
        do {
            let page = try model.librarySeries(
                id: libraryID,
                search: search.isEmpty ? nil : search,
                limit: pageSize,
                offset: items.count
            )
            items += page.items
            total = page.total
        } catch {
            errorMessage = "分页失败：\(error.localizedDescription)"
        }
    }
}

#if canImport(UIKit)
import UIKit
private func platformImage(_ data: Data?) -> Image? {
    guard let data, let ui = UIImage(data: data) else { return nil }
    return Image(uiImage: ui)
}
#else
import AppKit
private func platformImage(_ data: Data?) -> Image? {
    guard let data, let ns = NSImage(data: data) else { return nil }
    return Image(nsImage: ns)
}
#endif
