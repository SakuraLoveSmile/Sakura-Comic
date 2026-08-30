import SwiftUI
import KomgaReader

/// The Stage 7 reader screen.
///
/// 单页 / 双页 / 条漫 over one layout contract. Which pages form a spread, in
/// which on-screen order, and which gesture advances, all come from
/// `KomgaReader.Paging` — the same table the Rust core asserts
/// (`specs/contracts/fixtures/reader/paging.json`), so the two platforms cannot
/// disagree about what "next page" means for a right-to-left manga.
struct ReaderScreen: View {
    @StateObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var showSettings = false
    @State private var scrolledTo: UInt32 = 1
    @State private var scrub: Double = 1

    var body: some View {
        ZStack {
            background
            content
            if let banner = model.banner {
                VStack {
                    Text(banner)
                        .font(.footnote)
                        .padding(8)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("阅读设置")
            }
        }
        .task {
            await model.open()
            selection = order.firstIndex(of: model.spread) ?? 0
            scrolledTo = model.current
        }
        .onDisappear {
            Task { await model.close() }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(model: model)
        }
        .onChange(of: model.spread) { _, spread in
            withAnimation { selection = order.firstIndex(of: spread) ?? 0 }
            scrolledTo = model.spreads[safe: spread]?.first ?? scrolledTo
        }
    }

    private var background: Color {
        switch model.settings.background {
        case .white: return .white
        case .gray: return Color(white: 0.16)
        case .black: return .black
        }
    }

    /// Right-to-left paged reading is expressed as a reversed page order: the
    /// list still runs forward in reading order, and swiping mirrors. A
    /// `PageTabViewStyle` has no `reversed` of its own, and
    /// `layoutDirection` does not flip it either, so the order is the honest way.
    private var order: [Int] {
        let indices = Array(model.spreads.indices)
        return model.reversed ? indices.reversed() : indices
    }

    @ViewBuilder
    private var content: some View {
        if model.isBusy {
            ProgressView().tint(.white)
        } else if model.pageCount == 0 || !model.isPaged {
            unsupported
        } else if model.isVertical {
            verticalColumn
        } else {
            pagedColumn
        }
    }

    private var unsupported: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(model.fallback == .epub
                ? "EPUB 用文本阅读器打开（进度走 progression 接口）"
                : "这本书没有可显示的图像页面")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: - Paged (LTR / RTL, single or double)

    private var pagedColumn: some View {
        pagedTabView
        .onChange(of: selection) { _, chosen in
            guard let spread = order[safe: chosen] else { return }
            guard spread != model.spread, let first = model.spreads[safe: spread]?.first else { return }
            Task { await model.turn(to: first) }
        }
        .overlay(alignment: .bottom) { pageControl }
    }

    /// The paging container. `.page` style is iOS-only; a plain TabView on macOS
    /// still turns one spread at a time, so the reading model is identical and
    /// only the swipe chrome differs.
    @ViewBuilder
    private var pagedTabView: some View {
        #if os(iOS)
        TabView(selection: $selection) { spreadPages }
            .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        TabView(selection: $selection) { spreadPages }
        #endif
    }

    @ViewBuilder
    private var spreadPages: some View {
        ForEach(order, id: \.self) { index in
            SpreadPage(model: model, spread: index)
                .tag(index)
                .padding(.horizontal, CGFloat(model.settings.pageGap) / 2)
        }
    }

    // MARK: - Vertical (条漫 and 纵向翻页)

    /// One continuous column for webtoon; for vertical paged reading the same
    /// column is used, which keeps a single code path for the axis. Pages are
    /// built lazily, so a 500-page strip keeps a bounded number of images alive.
    private var verticalColumn: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: CGFloat(model.settings.pageGap)) {
                ForEach(Array(model.spreads.enumerated()), id: \.offset) { _, spread in
                    ForEach(spread, id: \.self) { page in
                        PageTile(model: model, page: page)
                            .id(page)
                    }
                }
            }
        }
        .scrollPosition(id: .constant(scrolledTo))
        .overlay(alignment: .bottom) { pageControl }
    }

    /// Quick jump. Dragging only moves a local draft; the position is written
    /// once, when the drag ends — otherwise a scrub across 200 pages would be
    /// 200 turns (and, before the throttle existed, 200 PATCHes).
    private var pageControl: some View {
        VStack(spacing: 4) {
            Text("\(model.current) / \(model.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
            Slider(
                value: $scrub,
                in: 1...Double(max(model.pageCount, 1)),
                step: 1
            ) {
                Text("页码")
            } onEditingChanged: { editing in
                guard !editing else { return }
                Task { await model.turn(to: UInt32(scrub.rounded())) }
            }
            .tint(.white)
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear { scrub = Double(model.current) }
        .onChange(of: model.current) { _, page in scrub = Double(page) }
    }
}

/// One spread: a single page, or two side by side in 双页 mode. The order is the
/// layout's `visual()` output, so RTL puts the reading-first page on the right.
private struct SpreadPage: View {
    let model: ReaderModel
    let spread: Int

    var body: some View {
        HStack(spacing: CGFloat(model.settings.pageGap) / 2) {
            ForEach(pages, id: \.self) { page in
                PageTile(model: model, page: page)
            }
        }
        .gesture(swipe)
    }

    private var pages: [UInt32] {
        model.layout?.visual(spread) ?? []
    }

    /// The gesture that means "forward" is `advanceSwipe` in the contract:
    /// left for LTR, right for RTL, up for a vertical axis.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                let forward: Bool
                if horizontal {
                    forward = model.layout?.nav().advance == .left
                        ? value.translation.width < 0
                        : value.translation.width > 0
                } else {
                    forward = value.translation.height < 0
                }
                Task { forward ? await model.next() : await model.previous() }
            }
    }
}

/// A single page, resolved through the model's local-first path.
private struct PageTile: View {
    let model: ReaderModel
    let page: UInt32

    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = pageImage(data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if data == nil {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: page) { data = await model.image(for: page) }
    }
}

/// The reading settings: the six knobs Stage 7 owns, plus the two explicit
/// statements (mark read / mark unread) that bypass the progress throttle.
struct ReaderSettingsSheet: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读模式") {
                    Picker("模式", selection: Binding(
                        get: { model.settings.mode },
                        set: { mode in Task { await model.setMode(mode) } }
                    )) {
                        Text("单页").tag(ReadMode.single)
                        Text("双页").tag(ReadMode.double)
                        Text("条漫").tag(ReadMode.webtoon)
                    }
                    .pickerStyle(.segmented)
                }
                Section("阅读方向") {
                    Picker("方向", selection: Binding(
                        get: { model.settings.direction },
                        set: { direction in Task { await model.setDirection(direction) } }
                    )) {
                        Text("左→右").tag(Direction.ltr)
                        Text("右→左").tag(Direction.rtl)
                        Text("纵向").tag(Direction.vertical)
                    }
                    .pickerStyle(.segmented)
                }
                Section("外观") {
                    Picker("背景", selection: Binding(
                        get: { model.settings.background },
                        set: { background in Task { await model.setBackground(background) } }
                    )) {
                        Text("黑").tag(Background.black)
                        Text("灰").tag(Background.gray)
                        Text("白").tag(Background.white)
                    }
                    LabeledContent("页间距") {
                        Slider(
                            value: Binding(
                                get: { Double(model.settings.pageGap) },
                                set: { gap in Task { await model.setPageGap(UInt32(gap)) } }
                            ),
                            in: 0...64, step: 4
                        )
                        .frame(width: 180)
                    }
                }
                Section("屏幕") {
                    Toggle("屏幕常亮", isOn: Binding(
                        get: { model.settings.keepScreenAwake },
                        set: { enabled in Task { await model.setKeepScreenAwake(enabled) } }
                    ))
                    LabeledContent("亮度") {
                        Slider(
                            value: Binding(
                                get: { model.settings.brightness ?? 1 },
                                set: { model.setBrightness($0) }
                            ),
                            in: 0.05...1
                        )
                        .frame(width: 180)
                    }
                }
                Section("进度") {
                    Toggle("阅读位置恢复", isOn: Binding(
                        get: { model.settings.restorePosition },
                        set: { enabled in Task { await model.setRestorePosition(enabled) } }
                    ))
                    HStack {
                        Button("标为已读") { Task { await model.markRead() } }
                        Spacer()
                        Button("标为未读") { Task { await model.markUnread() } }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// Decode page bytes into a SwiftUI image on either platform. The core hands
/// over a file; decoding is the platform's job, and it happens off the main
/// actor because it is called from `.task`.
@MainActor
private func pageImage(_ data: Data) -> Image? {
    #if canImport(UIKit)
    return UIImage(data: data).map { Image(uiImage: $0) }
    #elseif canImport(AppKit)
    return NSImage(data: data).map { Image(nsImage: $0) }
    #else
    return nil
    #endif
}

private extension Array {
    /// Bounds-safe indexing: a page turn can race a re-layout, and the reader
    /// must degrade to "stay where you are" rather than trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
