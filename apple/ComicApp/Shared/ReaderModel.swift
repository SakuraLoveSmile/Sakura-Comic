import Foundation
import Combine
import KomgaStore
import KomgaAPI
import KomgaReader
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Drives the Stage 7 reader screen on Apple platforms.
///
/// It is the mirror of Android's `ReaderController`: same `ReaderApi`-shaped
/// surface, same rule that the widget tree never sees a URL. Everything here
/// forwards to `KomgaReader`, which is contract-tested against
/// `specs/contracts/fixtures/reader/*.json` — the same files the Rust core
/// asserts, so the two platforms cannot disagree about what a spread is.
@MainActor
final class ReaderModel: ObservableObject {
    /// Page bytes, in a byte-budget LRU tier rather than a dictionary.
    ///
    /// Stage 7 kept `[UInt32: Data]` and never dropped an entry, so a long strip
    /// was not a cache that grows but a leak with a nice name: the process gets
    /// jetsam-killed holding page 400 of a book it stopped looking at on page 12.
    /// The tier holds at most the bytes the window plan says the device can spare
    /// (`applyWindow`), so memory is flat by construction. It is deliberately not
    /// `@Published`: `PageTile` already owns its own `@State` and loads through
    /// `image(for:)`, and publishing a dictionary would redraw the whole spread on
    /// every prefetch.
    private let memory = ByteBudgetCache<Data>(budgetBytes: Int(WindowConstants.memoryDefaultBytes))
    /// This session's computed window, or nil before the book is open — in which
    /// case the stored settings' placeholder window is still what runs.
    private var window: WindowPlan?
    /// What the open-time cache sweep repaired, or nil before a book is open. Not
    /// published: it is diagnostics, and a clean sweep is the normal case.
    private(set) var lastSweep: ReconcileReport?
    /// What the app believes about the link. `unknown` is the honest default and
    /// resolves to the conservative plan, matching Rust's `parse_network("")`.
    var reportedNetwork: NetworkMode = .unknown
    @Published private(set) var layout: Layout?
    @Published private(set) var settings: ReaderSettingsDocument = .standard
    @Published private(set) var pageCount: UInt32 = 0
    @Published private(set) var current: UInt32 = 1
    @Published private(set) var spread: Int = 0
    @Published var banner: String?
    @Published private(set) var isBusy = true
    /// `reflowable` books (EPUB/PDF) are not image-paged and must not be driven
    /// by this screen at all (Stage 6 rule R8).
    @Published private(set) var isPaged = false
    @Published private(set) var fallback: Fallback?
    private(set) var isClosed = false

    let bookID: String
    let title: String

    private let store: KomgaStore
    let serverID: String
    private var loader: PageLoader?
    private var session: ReaderSession?
    private var ticker: Task<Void, Never>?
    /// Draining the queue is Stage 6's job (`OutboxUpload.run`); the app already
    /// runs a background ticker, so the reader only *nudges* it. Injectable so a
    /// preview or a test can watch the intent without a network.
    private let flush: () async -> Void

    init(
        store: KomgaStore,
        serverID: String,
        bookID: String,
        title: String,
        bookMediaType: String?,
        baseURL: String,
        auth: AuthMethod,
        disk: DiskImageCache,
        cacheBudgetBytes: Int64? = nil,
        flush: @escaping () async -> Void = {}
    ) {
        self.store = store
        self.serverID = serverID
        self.bookID = bookID
        self.title = title
        self.flush = flush
        self.pendingMediaType = bookMediaType
        self.pendingSource = RemotePageSource(baseURL: baseURL, auth: auth)
        let cache = PageCache(store: store, disk: disk)
        if let cacheBudgetBytes, cacheBudgetBytes > 0 {
            cache.budgetBytes = cacheBudgetBytes
        }
        self.pendingCache = cache
    }

    private let pendingMediaType: String?
    private let pendingSource: RemotePageSource
    private let pendingCache: PageCache

    // MARK: - Open

    func open() async {
        isClosed = false
        isBusy = true
        defer { isBusy = false }
        do {
            let stored = try store.readerSettings()
            settings = stored
            let loaded = try await PageLoader.open(
                store: store,
                serverID: serverID,
                bookID: bookID,
                bookMediaType: pendingMediaType,
                source: pendingSource,
                cache: pendingCache,
                now: ReaderClock.now().rfc3339
            )
            // A sweep belongs here and not on the hot path: this is the one moment
            // per open where walking every cached file is affordable, and it is
            // what turns a permanently-broken cache into a page that simply
            // reloads. Everything already resident in the ledger converges before
            // the first byte is served.
            lastSweep = try pendingCache.reconcile(now: ReaderClock.now().rfc3339)
            let reader = try ReaderSession(
                store: store,
                serverID: serverID,
                bookID: bookID,
                pageCount: loaded.pageCount,
                writesProgress: loaded.manifest.writesPageProgress,
                settings: stored,
                clock: ReaderClock.now()
            )
            self.loader = loaded
            self.session = reader
            self.layout = reader.layout
            self.pageCount = loaded.pageCount
            self.isPaged = loaded.manifest.writesPageProgress
            self.fallback = loaded.manifest.fallback
            self.current = reader.current
            self.spread = reader.spread
            applySystemSettings()
            startTicker()
            applyWindow()
            await warmWindow()
        } catch {
            banner = "打不开这本书：\(error.localizedDescription)"
        }
    }

    func close() async {
        isClosed = true
        ticker?.cancel()
        ticker = nil
        guard let session else { return }
        do {
            if try session.close(clock: .now()) == .now { await flush() }
        } catch {
            banner = "进度没能收尾：\(error.localizedDescription)"
        }
        restoreSystem()
        self.session = nil
    }

    /// The reader's own beat. The interval rule itself lives in
    /// `ProgressThrottle`; here we only ask "is anything due?" and hand the queue
    /// to Stage 6's uploader when it is.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.session?.tick(clock: .now()) == .now { await self.flush() }
            }
        }
    }

    // MARK: - Navigation

    var spreads: [[UInt32]] { layout?.spreads ?? [] }
    var spreadCount: Int { layout?.spreadCount ?? 0 }
    var isWebtoon: Bool { settings.mode == .webtoon }
    var isVertical: Bool { layout?.axis == .vertical }
    var reversed: Bool { layout?.reversed ?? false }

    /// On-screen order of the current spread.
    var visiblePages: [UInt32] { layout?.visual(spread) ?? [] }

    func turn(to page: UInt32) async {
        guard let session else { return }
        do {
            let upload = try session.turnTo(page: page, clock: .now())
            adopt(session)
            if upload == .now { await flush() }
            await warmWindow()
        } catch {
            banner = "翻页失败：\(error.localizedDescription)"
        }
    }

    func next() async { await step(forward: true) }
    func previous() async { await step(forward: false) }

    private func step(forward: Bool) async {
        guard let session else { return }
        do {
            let upload = forward
                ? try session.next(clock: .now())
                : try session.previous(clock: .now())
            adopt(session)
            if upload == .now { await flush() }
            await warmWindow()
        } catch {
            banner = "翻页失败：\(error.localizedDescription)"
        }
    }

    func setMode(_ mode: ReadMode) async { await relayout(mode: mode, direction: nil) }
    func setDirection(_ direction: Direction) async { await relayout(mode: nil, direction: direction) }

    /// Re-pair the book. `ReaderSession.relayout` keeps the reader on the spread
    /// it was on rather than jumping to page 1, which is what makes switching
    /// between 单页 and 双页 mid-chapter survivable.
    private func relayout(mode: ReadMode?, direction: Direction?) async {
        guard let session else { return }
        var updated = settings
        if let mode { updated.mode = mode }
        if let direction { updated.direction = direction }
        do {
            try store.saveReaderSettings(updated)
            settings = try store.readerSettings()
            try session.relayout(
                mode: settings.mode,
                direction: settings.direction,
                clock: .now()
            )
            adopt(session)
            // The pairing changed, so re-plan first and then free what the new
            // window does not cover: resident bytes outside it are dead weight,
            // still on disk, and cost a file read rather than a request.
            applyWindow()
            memory.retainKeys(liveWindowKeys())
            await warmWindow()
        } catch {
            banner = "设置没能保存：\(error.localizedDescription)"
        }
    }

    func setPageGap(_ pixels: UInt32) async { await update { $0.withPageGap(pixels) } }
    func setBackground(_ background: Background) async { await update { $0.withBackground(background) } }
    func setKeepScreenAwake(_ enabled: Bool) async { await update { $0.withKeepScreenAwake(enabled) } }
    func setRestorePosition(_ enabled: Bool) async { await update { $0.withRestorePosition(enabled) } }

    /// Brightness is a device state, not a preference: it is applied now and
    /// handed back to the system when the reader closes.
    func setBrightness(_ level: Double?) {
        applyBrightness(level)
    }

    private func update(_ change: (inout ReaderSettingsDocument) -> Void) async {
        var draft = settings
        change(&draft)
        do {
            try store.saveReaderSettings(draft)
            // A webtoon drops firstPageSingle during sanitize, so read back what
            // was actually stored instead of trusting the request.
            settings = try store.readerSettings()
            applySystemSettings()
        } catch {
            banner = "设置没能保存：" + error.localizedDescription
        }
    }

    private func adopt(_ session: ReaderSession) {
        layout = session.layout
        current = session.current
        spread = session.spread
    }

    // MARK: - Pages

    /// Local first: the tier answers without a file read, `cachedPage` answers
    /// without a request, and only a real miss reaches the network. This is why an
    /// offline reader keeps working.
    func image(for page: UInt32) async -> Data? {
        if let cached = imageData(for: page) { return cached }
        guard let loader else { return nil }
        do {
            let reference = try await loader.page(number: page, now: ReaderClock.now().rfc3339)
            guard let data = try? Data(contentsOf: reference.url), !data.isEmpty else {
                banner = "第 \(page) 页解码失败"
                return nil
            }
            hold(data, for: page)
            return data
        } catch {
            // An uncached page during an outage is a per-page problem: the rest
            // of the spread keeps rendering and the queue keeps accumulating.
            banner = "第 \(page) 页暂不可用：\(error.localizedDescription)"
            return nil
        }
    }

    /// What the tier holds right now, without loading anything. A view that can
    /// draw a warm page synchronously should not have to await one.
    func imageData(for page: UInt32) -> Data? {
        memory.value(for: page)
    }

    /// Put bytes in the tier, which may refuse them.
    ///
    /// A refusal is not a failure to report: the page is already on disk, so the
    /// next read just goes to disk again. That is the whole reason a bounded tier
    /// is safe to put in front of a reader — the worst case is a file read, never
    /// a missing page.
    private func hold(_ data: Data, for page: UInt32) {
        memory.insert(data, for: page)
    }

    // MARK: - Window

    /// What this device and this book look like to the contract.
    ///
    /// The inputs are the five the objective names, and each is taken from the
    /// party that can actually answer: RAM from the process, page size from the
    /// mirrored manifest, layout from the settings, the link from the app. Nothing
    /// here is guessed — an unknown arrives as 0 or `.unknown`, which the planner
    /// resolves to the smaller window.
    private var windowProfile: WindowProfile {
        let sizes = (loader?.manifest.pages ?? []).map(\.sizeBytes).filter { $0 > 0 }
        let measured = sizes.isEmpty
            ? 0
            : sizes.reduce(Int64(0), +) / Int64(sizes.count)
        return WindowProfile(
            deviceMemoryBytes: WindowPlanner.reportedDeviceMemoryBytes(),
            cacheBudgetBytes: defaultCacheBudgetBytes,
            avgPageBytes: measured,
            pagesPerSpread: spreads.map(\.count).max() ?? 1,
            mode: settings.mode,
            direction: settings.direction,
            network: reportedNetwork,
            stable: true
        )
    }

    /// Compute the plan and size the memory tier from it — the same moment Rust's
    /// reader-open does `set_memory_budget(plan.memory_budget_bytes)`.
    private func applyWindow() {
        let plan = planWindow(windowProfile)
        window = plan
        memory.budgetBytes = Int(clamping: plan.memoryBudgetBytes)
    }

    /// The visible spread plus the spreads the current window reaches: everything
    /// still worth keeping in RAM after the layout changes.
    private func liveWindowKeys() -> Set<UInt32> {
        guard let window, !spreads.isEmpty else { return Set(visiblePages) }
        var keep = Set(visiblePages)
        let last = spreads.count - 1
        for offset in -window.back...window.forward {
            let index = min(max(spread + offset, 0), last)
            keep.formUnion(spreads[index])
        }
        return keep
    }

    /// Prefetch the window around the current spread (current, ahead, behind).
    func warmWindow() async {
        guard let loader, let session else { return }
        // A computed plan outranks the stored placeholder: that is the point of
        // Stage 8. Offline therefore prefetches nothing, and a mid-flip reader asks
        // for the spread it is landing on rather than 26 pages.
        do {
            _ = try await loader.prefetch(
                spreads: session.layout.spreads,
                center: session.spread,
                window: window?.prefetchWindow ?? settings.prefetch.window,
                now: ReaderClock.now().rfc3339
            )
        } catch {
            // Prefetch is advisory; a cold neighbour is never an error to show.
        }
    }

    // MARK: - Explicit statements

    func markRead() async {
        guard let session else { return }
        do {
            if try session.markRead(clock: .now()) == .now { await flush() }
        } catch {
            banner = "标为已读失败：\(error.localizedDescription)"
        }
    }

    func markUnread() async {
        guard let session else { return }
        do {
            if try session.markUnread(clock: .now()) == .now { await flush() }
            adopt(session)
        } catch {
            banner = "标为未读失败：\(error.localizedDescription)"
        }
    }

    /// Called when the app backgrounds: the last reliable moment to get a
    /// request out before the process may be suspended.
    func scenePhaseBackgrounded() async {
        guard let session else { return }
        if session.background(clock: .now()) == .now { await flush() }
    }

    // MARK: - Platform glue

    private func applySystemSettings() {
        #if canImport(UIKit) && !os(macOS)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
        if let brightness = settings.brightness { applyBrightness(brightness) }
        #else
        applyBrightness(settings.brightness)
        #endif
    }

    private func applyBrightness(_ level: Double?) {
        #if canImport(UIKit) && !os(macOS)
        if let level { UIScreen.main.brightness = CGFloat(level) }
        #endif
        // macOS exposes no per-app brightness API; the system control stays in charge.
    }

    private func restoreSystem() {
        #if canImport(UIKit) && !os(macOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}

/// Field setters that keep the stored document as the single source of truth.
extension ReaderSettingsDocument {
    func withPageGap(_ pixels: UInt32) -> ReaderSettingsDocument {
        var copy = self
        copy.pageGap = pixels
        return copy
    }

    func withBackground(_ background: Background) -> ReaderSettingsDocument {
        var copy = self
        copy.background = background
        return copy
    }

    func withKeepScreenAwake(_ enabled: Bool) -> ReaderSettingsDocument {
        var copy = self
        copy.keepScreenAwake = enabled
        return copy
    }

    func withRestorePosition(_ enabled: Bool) -> ReaderSettingsDocument {
        var copy = self
        copy.restorePosition = enabled
        return copy
    }
}

extension ReaderModel: Identifiable {
    public var id: String { "\(serverID)/\(bookID)" }
}
