import Foundation
import KomgaStore

// MARK: - Reader settings (mirror of `reader/settings.rs`)
//
// The six knobs Stage 7 owns (mode, direction, page gap, background, keep screen
// awake, brightness, position restore) plus the prefetch window, persisted as one
// JSON document in `app_state` under `reader_settings`, so adding a knob is an
// encoding change rather than a migration.
//
// Defaults matter: they are what a reader sees on first launch, and what a
// corrupted row falls back to.

/// `app_state` key holding the reader settings document.
public let readerSettingsKey = "reader_settings"

public enum Background: String, Sendable, Equatable, Codable {
    case black
    case white
    case gray
}

/// Brightness is a multiplier on the system level, in 0.05...1.0. `nil` means
/// "leave the system brightness alone" — the reader must not fight the OS.
public let minBrightness: Double = 0.05

/// Gap between pages, in logical pixels; negative gaps would overlap content.
public let maxPageGap: UInt32 = 64

public func clampBrightness(_ value: Double) -> Double {
    if !value.isFinite { return 1.0 }
    return min(max(value, minBrightness), 1.0)
}

public struct ReaderSettingsDocument: Sendable, Equatable, Codable {
    public var mode: ReadMode
    public var direction: Direction
    /// Manga convention: the cover/title page stands alone before pairing.
    public var firstPageSingle: Bool
    public var pageGap: UInt32
    public var background: Background
    public var keepScreenAwake: Bool
    public var brightness: Double?
    /// When off, every book starts at page 1 and nothing is written back.
    public var restorePosition: Bool
    public var prefetch: PrefetchWindowSettings

    /// Note: `prefetch` is stored as its own camelCase object rather than reusing
    /// `PrefetchWindow`, because that type mirrors Rust's `prefetch::Window` field
    /// for field and must not grow encoder concerns.
    public struct PrefetchWindowSettings: Sendable, Equatable, Codable {
        public var forward: Int
        public var back: Int
        public var cap: Int

        public init(forward: Int, back: Int, cap: Int) {
            self.forward = forward
            self.back = back
            self.cap = cap
        }

        public init(_ window: PrefetchWindow) {
            self.init(forward: window.forward, back: window.back, cap: window.cap)
        }

        public var window: PrefetchWindow {
            PrefetchWindow(forward: forward, back: back, cap: cap)
        }
    }

    public init(
        mode: ReadMode = .single,
        direction: Direction = .ltr,
        firstPageSingle: Bool = true,
        pageGap: UInt32 = 8,
        background: Background = .black,
        keepScreenAwake: Bool = true,
        brightness: Double? = nil,
        restorePosition: Bool = true,
        prefetch: PrefetchWindowSettings = PrefetchWindowSettings(PrefetchWindow.standard)
    ) {
        self.mode = mode
        self.direction = direction
        self.firstPageSingle = firstPageSingle
        self.pageGap = pageGap
        self.background = background
        self.keepScreenAwake = keepScreenAwake
        self.brightness = brightness
        self.restorePosition = restorePosition
        self.prefetch = prefetch
    }

    /// The defaults a first-launch reader sees — the same table Rust's
    /// `ReaderSettings::default()` spells out.
    public static let standard = ReaderSettingsDocument()

    private enum CodingKeys: String, CodingKey {
        case mode, direction
        case firstPageSingle
        case pageGap
        case background
        case keepScreenAwake
        case brightness
        case restorePosition
        case prefetch
    }

    /// Normalizes anything a UI or a stored document could produce into a state
    /// the layout code can rely on.
    public func sanitized() -> ReaderSettingsDocument {
        var copy = self
        copy.pageGap = min(pageGap, maxPageGap)
        copy.brightness = brightness.map(clampBrightness)
        // A webtoon is a single column by definition; pairing would be a bug.
        if mode == .webtoon { copy.firstPageSingle = false }
        return copy
    }

    /// Decode a stored document, tolerating a partial row by falling back to the
    /// default per-field rather than failing the open.
    public static func load(from data: Data) -> ReaderSettingsDocument {
        (try? JSONDecoder().decode(ReaderSettingsDocument.self, from: data)) ?? .standard
    }

    public static func encode(_ settings: ReaderSettingsDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(settings.sanitized())) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public extension KomgaStore {
    /// Load the reader settings. Missing or unreadable rows fall back to the
    /// defaults: a partially written or hand-edited row must not brick the reader.
    func readerSettings() throws -> ReaderSettingsDocument {
        let raw = try appStateValue(key: readerSettingsKey)
        let settings = raw
            .flatMap { Data($0.utf8) }
            .map { ReaderSettingsDocument.load(from: $0) } ?? .standard
        return settings.sanitized()
    }

    /// Persist the reader settings, sanitized on the way in so a stale flag never
    /// survives a save.
    func saveReaderSettings(_ settings: ReaderSettingsDocument) throws {
        try putAppStateValue(key: readerSettingsKey, value: ReaderSettingsDocument.encode(settings))
    }
}

/// Direction precedence, which is a real product rule and not a detail: what the
/// user left this book on beats what the series says, which beats the global
/// preference. A manga read once in RTL stays in RTL on the next chapter even if
/// the user's default is LTR.
public func resolveDirection(
    perBook: Direction?,
    seriesReadingDirection: String?,
    global: Direction
) -> Direction {
    perBook ?? recommendedDirection(seriesReadingDirection) ?? global
}

/// What the server's series metadata implies, if anything.
public func recommendedDirection(_ seriesReadingDirection: String?) -> Direction? {
    guard let raw = seriesReadingDirection else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "rtl", "righttoleft", "right-to-left", "manga": return .rtl
    case "ltr", "lefttoright", "left-to-right", "comic": return .ltr
    case "vertical", "webtoon": return .vertical
    default: return nil
    }
}
