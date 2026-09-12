import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, PaintingBinding;

import 'reader_api.dart';
import 'reader_device.dart';
import 'reader_system_controls.dart';
import 'rust/ffi/application.dart';

/// The reader screen's whole state: where the reader is, which pages are on
/// disk, and when a progress write is owed.
///
/// It talks to [ReaderApi] only. It never constructs a URL, never decides a
/// cache path and never sequences a download — those are the core's, which is
/// what makes "reading a cached page while offline" the same code path as
/// reading one online.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.api,
    this.systemControls,
    this.device,
    this.tickInterval = const Duration(seconds: 2),
    this.settleWindow = const Duration(milliseconds: 400),
    this.slowResponseThreshold = const Duration(milliseconds: 1500),
    this.seriesId,
    this.onSeriesLayoutChanged,
  });

  final ReaderApi api;
  final ReaderSystemControls? systemControls;

  /// What this device actually is. Null in tests and on a shell that has no
  /// channel: the core then keeps its conservative defaults.
  final ReaderDevice? device;

  /// How long a page turn is still considered "mid-flip". Inside it the reader
  /// reports itself unstable, which is what stops a burst of turns from queuing
  /// a full prefetch window per frame.
  final Duration settleWindow;

  /// A response slower than this counts towards the "weak link" verdict.
  final Duration slowResponseThreshold;

  /// How often the reader asks the core whether the queue may go out. The
  /// cadence lives here rather than in the core because this is the only place
  /// that knows whether anyone is still reading.
  final Duration tickInterval;

  /// The series this book belongs to, so a mode or direction chosen inside the
  /// reader can be recorded against the series.
  final String? seriesId;

  /// Called when the reader's page mode or direction changes.
  ///
  /// The controller deliberately does not write this itself: "what this series
  /// reads like" is a preference store the controller has no business owning,
  /// and the bug this replaces was exactly a controller writing a per-book
  /// gesture into the global preference. The screen owns the write and the
  /// message that explains it.
  final void Function(String mode, String direction)? onSeriesLayoutChanged;

  ReaderBookDto? book;
  ReaderSettingsDto? settings;
  String? error;
  bool busy = true;

  /// How far into the opening page the core restored this reader, 0..1, or
  /// `null` for "top of the page". The screen reads it once to place a webtoon
  /// where the user left off; the controller does not act on it itself.
  double? get startPageOffsetRatio => book?.startPageOffsetRatio;

  /// Where the reader is right now, as of the last scroll notification. This is
  /// the value the closing flush writes, which is why it is tracked separately
  /// from what has already been sent: the whole point of the flush is to write
  /// the position the throttle skipped.
  double? _pendingOffset;

  /// What the core was last told, so a scroll that has not moved meaningfully
  /// does not become a write. `null` means "the core has been told there is no
  /// offset" — which is a different state from "we have not told it yet".
  double? _reportedOffset;
  bool _offsetNeverSent = true;
  DateTime? _lastOffsetWrite;

  /// The in-flight closing write, if the screen asked for one. `dispose` awaits
  /// it before closing the reader, because closing is what commits the session's
  /// offset to SQLite — closing first would write the old position over the new
  /// one and the reader would come back to where they were two scrolls ago.
  Future<void>? _offsetFlush;
  Future<void> _offsetWriteChain = Future<void>.value();
  bool _offsetWriteFailed = false;
  double? _queuedOffset;
  bool _offsetWriteInFlight = false;
  int _offsetWriteSequence = 0;

  /// A scroll burst reports at most this often. A user dragging through a long
  /// strip emits a notification per frame, and a SQLite write per frame would
  /// make the reader the slowest thing on the screen it is trying to draw.
  static const Duration offsetWriteInterval = Duration(milliseconds: 600);

  bool _isClosed = false;
  bool get isClosed => _isClosed;
  Future<void>? _closedFuture;
  Future<void> get closed => _closedFuture ?? Future<void>.value();

  int _turnGeneration = 0;
  int get turnGeneration => _turnGeneration;

  /// Stage 8: bounded. A path string is cheap, but so is the discipline of never
  /// letting a map grow with the length of a session — on a 500-page book the
  /// unbounded version quietly kept every path the reader had ever looked at.
  /// Insertion order doubles as recency here: a hit re-inserts, so the head of
  /// the map is always the entry that went unused longest.
  final Map<int, String> _paths = <int, String>{};
  int _memoLimit = 64;
  final Map<int, Completer<String?>> _inFlight = {};

  /// The numbers the core derived from the last device report.
  ReaderWindowDto? window;
  DateTime? _lastMove;
  int _recentFailures = 0;
  int _recentSlowResponses = 0;
  String _networkWords = NetworkWords.wifi;
  Timer? _ticker;
  bool _uploadPending = false;
  double _brightness = 1.0;
  bool _keepAwakeApplied = false;

  int get pageCount => book?.pageCount.toInt() ?? 0;
  int get page => layout?.page.toInt() ?? 1;
  int get spread => layout?.spread.toInt() ?? 0;
  List<Uint32List> get rawSpreads => layout?.spreads ?? const <Uint32List>[];

  List<List<int>> get spreads => spreadRows(rawSpreads);
  ReaderLayoutDto? get layout => book?.layout;
  String get mode => layout?.mode ?? 'single';
  String get direction => layout?.direction ?? 'ltr';
  bool get isVertical => (layout?.axis ?? 'horizontal') == 'vertical';

  /// Double-page mode draws two images side by side; everything else one.
  bool get isDouble => mode == 'double';
  bool get isWebtoon => mode == 'webtoon';

  /// The spread's pages in on-screen order. The core reports reading order and
  /// says whether this layout is reversed; that split is what keeps pairing,
  /// direction and gestures from being re-derived (and re-guessed) in Dart.
  List<int> get visiblePages {
    final current = layout;
    if (current == null || spreads.isEmpty) return const <int>[];
    final index = spread.clamp(0, spreads.length - 1);
    final ordered = List<int>.from(spreads[index]);
    return current.reversed ? ordered.reversed.toList() : ordered;
  }

  int get spreadCount => spreads.length;

  /// Gap between pages, in logical pixels (the core stores it that way, and the
  /// paged view splits it between the two halves of a spread).
  double get pageGap => (layout?.pageGap.toInt() ?? 8).toDouble();
  String get backgroundName => layout?.background ?? 'black';

  Color get background => switch (backgroundName) {
        'white' => const Color(0xFFFFFFFF),
        'gray' => const Color(0xFF2A2A2A),
        _ => const Color(0xFF000000),
      };

  Future<void> start() async {
    if (_isClosed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final loadedSettings = await api.settings();
      if (_isClosed) return;
      settings = loadedSettings;
      final openedBook = await api.open();
      if (_isClosed) return;
      book = openedBook;
      // Closing before image layout must preserve the position read from disk.
      _pendingOffset = openedBook.startPageOffsetRatio;
      await _applySystemSettings();
      if (_isClosed) return;
      // The plan has to exist before the first prefetch, or the very first window
      // is the one sized for a device we do have information about — too late.
      await _reportDevice();
      if (_isClosed) return;
      _startTicker();
      await _warmWindow();
    } catch (exception) {
      if (_isClosed) return;
      error = '$exception';
    } finally {
      if (!_isClosed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// Record where inside the current page the reader is, 0..1, or `null` for
  /// the top of the page.
  ///
  /// Called from a scroll handler, so it is deliberately cheap and drop-tolerant:
  /// a report inside [offsetWriteInterval] of the last one, or one that barely
  /// moved, is skipped rather than queued. The write that matters — the one when
  /// the reader leaves — goes through [flushPageOffset].
  Future<void> reportPageOffset(double? ratio) async {
    if (_isClosed) return;
    final normalized = ratio?.clamp(0.0, 1.0);
    _pendingOffset = normalized;
    if (!_offsetMovedEnough(normalized)) return;
    final now = DateTime.now();
    final last = _lastOffsetWrite;
    if (last != null && now.difference(last) < offsetWriteInterval) return;
    await _writeOffset(normalized, now);
  }

  /// Send the current offset regardless of throttling. Called when the reader
  /// closes: this is the write that makes "stop halfway, come back halfway" true
  /// even when the last scroll frame was a moment ago and was therefore skipped.
  Future<void> flushPageOffset() {
    if (_isClosed) return _offsetFlush ?? Future<void>.value();
    if (_offsetWriteInFlight && _pendingOffset == _queuedOffset) {
      return _offsetWriteChain;
    }
    if (!_offsetNeverSent &&
        _pendingOffset == _reportedOffset &&
        !_offsetWriteFailed) {
      return _offsetWriteChain;
    }
    final pending = _writeOffset(_pendingOffset, DateTime.now());
    _offsetFlush = pending;
    return pending;
  }

  Future<void> _writeOffset(double? ratio, DateTime now) async {
    _lastOffsetWrite = now;
    _queuedOffset = ratio;
    _offsetWriteInFlight = true;
    final sequence = ++_offsetWriteSequence;
    final write = _offsetWriteChain.then((_) async {
      try {
        await api.setPageOffset(ratio);
        _reportedOffset = ratio;
        _offsetNeverSent = false;
        _offsetWriteFailed = false;
      } catch (exception) {
        _offsetWriteFailed = true;
        // Losing a scroll position costs the reader one re-scroll next time.
        // Surfacing it as a reader error would cost them the page they are on.
        debugPrint('[Reader] page offset not saved: $exception');
      } finally {
        if (sequence == _offsetWriteSequence) _offsetWriteInFlight = false;
      }
    });
    _offsetWriteChain = write;
    _offsetFlush = write;
    await write;
  }

  /// A scroll within the same page is not a reason to write: below this much
  /// movement the reader is where they were, and a 5000px strip crossed at a
  /// hundredth of a page is a rounding error nobody can see.
  bool _offsetMovedEnough(double? next) {
    if (_offsetNeverSent) return true;
    final previous = _reportedOffset;
    if (next == null || previous == null) return next != previous;
    return (next - previous).abs() > 0.005;
  }

  Future<void> turnTo(int target) async {
    if (_isClosed || pageCount == 0) return;
    final generation = ++_turnGeneration;
    _noteMove();
    try {
      final turn = await api.turn(target);
      if (_isClosed || generation != _turnGeneration) return;
      if (turn.page != page && _offsetNeverSent == false) {
        // A different page means the old offset described a page we are no
        // longer on, and the *stored* one has to go with it: page 40's "60%
        // down" must not be applied to page 41 on the next open.
        //
        // Written unconditionally rather than only for a vertical reader. That
        // was the tempting optimisation and it is wrong: whether this book is a
        // webtoon *now* says nothing about how it will render next time (mode is
        // per-series and switchable), and a ratio left behind would spring back
        // then. The row is already being touched by this turn, so the extra cost
        // is one column in a write that was happening anyway.
        _reportedOffset = null;
        _pendingOffset = null;
        await _writeOffset(null, DateTime.now());
        if (_isClosed || generation != _turnGeneration) return;
      }
      _moveTo(turn);
      await _warmWindow();
    } catch (exception) {
      if (_isClosed || generation != _turnGeneration) return;
      error = '$exception';
      notifyListeners();
    }
  }

  /// Forward one spread. `advanceSwipe` in the layout is the gesture that means
  /// this; the reading order itself never flips with direction.
  Future<void> next() => _step(1);

  Future<void> previous() => _step(-1);

  Future<void> _step(int delta) async {
    if (_isClosed || pageCount == 0) return;
    final generation = ++_turnGeneration;
    _noteMove();
    try {
      final turn = await api.step(delta);
      if (_isClosed || generation != _turnGeneration) return;
      _moveTo(turn);
      await _warmWindow();
    } catch (exception) {
      if (_isClosed || generation != _turnGeneration) return;
      error = '$exception';
      notifyListeners();
    }
  }

  void _moveTo(ReaderTurnDto turn) {
    if (_isClosed) return;
    final current = layout;
    if (current == null) return;
    book = book?.copyWith(layout: current.copyWithTurn(turn));
    notifyListeners();
  }

  Future<void> setMode(String wanted) => _setLayout(mode: wanted);

  Future<void> setDirection(String wanted) => _setLayout(direction: wanted);

  Future<void> _setLayout({String? mode, String? direction}) async {
    if (_isClosed) return;
    try {
      final next = await api.setLayout(
        mode: mode ?? this.mode,
        direction: direction ?? this.direction,
      );
      if (_isClosed) return;
      book = book?.copyWith(layout: next);
      if (next.axis != 'vertical' && !_offsetNeverSent) {
        // Leaving a scrolling layout: the stored ratio described a scroll inside
        // a page that no longer scrolls. Left alone it would sit in the database
        // and spring back the next time this book opened as a webtoon.
        _reportedOffset = null;
        _pendingOffset = null;
        await _writeOffset(null, DateTime.now());
      }
      if (_isClosed) return;
      // Only the two dimensions this gesture changed: a tap on 双页 says nothing
      // about the background colour, and re-persisting everything would fight
      // whatever else is writing the global document.
      onSeriesLayoutChanged?.call(next.mode, next.direction);
      if (_isClosed) return;
      await _warmWindow();
    } catch (exception) {
      if (_isClosed) return;
      error = '$exception';
      notifyListeners();
    }
  }

  Future<void> setPageGap(int logicalPixels) =>
      _updateSettings((current) => current.copyWith(pageGap: logicalPixels));

  Future<void> setBackground(String name) =>
      _updateSettings((current) => current.copyWith(background: name));

  Future<void> setKeepScreenAwake(bool enabled) =>
      _updateSettings((current) => current.copyWith(keepScreenAwake: enabled));

  Future<void> setRestorePosition(bool enabled) =>
      _updateSettings((current) => current.copyWith(restorePosition: enabled));

  /// Brightness is a device state, not a stored preference: it resets when the
  /// reader closes, and the slider only ever moves between 5% and 100%.
  Future<void> setBrightness(double level) async {
    _brightness = level.clamp(0.05, 1.0);
    notifyListeners();
    await systemControls?.setBrightness(_brightness);
  }

  double get brightness => _brightness;

  Future<void> _updateSettings(
    ReaderSettingsDto Function(ReaderSettingsDto) change,
  ) async {
    if (_isClosed) return;
    final current = settings;
    if (current == null) return;
    try {
      final updated = await api.setSettings(change(current));
      if (_isClosed) return;
      settings = updated;
      final next = await api.setLayout(
        mode: settings!.mode,
        direction: settings!.direction,
      );
      if (_isClosed) return;
      book = book?.copyWith(layout: next);
      await _applySystemSettings();
      if (_isClosed) return;
      notifyListeners();
    } catch (exception) {
      if (_isClosed) return;
      error = '$exception';
      notifyListeners();
    }
  }

  Future<void> _applySystemSettings() async {
    if (_isClosed) return;
    final applied = settings;
    if (applied == null || systemControls == null) return;
    if (applied.keepScreenAwake && !_keepAwakeApplied) {
      await systemControls!.setKeepScreenAwake(true);
      if (_isClosed) return;
      _keepAwakeApplied = true;
    } else if (!applied.keepScreenAwake && _keepAwakeApplied) {
      await systemControls!.setKeepScreenAwake(false);
      if (_isClosed) return;
      _keepAwakeApplied = false;
    }
  }

  /// Local first: ask where the page is, and only fetch when the answer is no.
  Future<String?> imageFor(int number) async {
    if (_isClosed) return null;
    final known = _remembered(number);
    if (known != null) return known;
    try {
      final path = await api.pagePath(number);
      if (_isClosed) return path;
      if (path != null) {
        _remember(number, path);
        notifyListeners();
        return path;
      }
    } catch (_) {
      // A missing local path is not an error state; the fetch below may still
      // succeed, and if it cannot the page reports itself as unavailable.
    }
    if (_isClosed) return null;
    final existing = _inFlight[number];
    if (existing != null) return existing.future;
    final completion = Completer<String?>();
    _inFlight[number] = completion;
    String? resolvedPath;
    // The fetch is the only place the reader can see the link's real behaviour.
    // There is no connectivity permission here, and none is needed: two failures
    // say "offline" more honestly than any broadcast listener.
    final clock = Stopwatch()..start();
    try {
      final path = await api.page(number);
      resolvedPath = path;
      clock.stop();
      if (_isClosed) return path;
      if (clock.elapsed >= slowResponseThreshold) _recentSlowResponses += 1;
      // A page that arrived is evidence the link works — and it is the only thing
      // that clears the banner. Leaving a stale error up after a successful turn is
      // what made a retry indistinguishable from a fresh failure.
      _recentFailures = 0;
      error = null;
      _remember(number, path);
      notifyListeners();
      return path;
    } catch (exception) {
      clock.stop();
      if (_isClosed) return null;
      _recentFailures += 1;
      // Offline over an uncached page: the surrounding spread still reads, and
      // the tile shows a retry affordance instead of a broken image.
      error = 'page $number unavailable: $exception';
      unawaited(_reReportIfLinkChanged());
      notifyListeners();
      return null;
    } finally {
      _inFlight.remove(number);
      completion.complete(resolvedPath);
    }
  }

  /// A memo hit must bump recency, or the eviction order is insertion order and
  /// the pages actually being looked at are the ones dropped.
  String? _remembered(int number) {
    final known = _paths.remove(number);
    if (known == null) return null;
    _paths[number] = known;
    return known;
  }

  void _remember(int number, String path) {
    _paths
      ..remove(number)
      ..[number] = path;
    while (_paths.length > _memoLimit) {
      _paths.remove(_paths.keys.first);
    }
  }

  /// The link state the reader last reported to the core. On-device acceptance
  /// reads this to prove a real radio loss reached the prefetch planner.
  String get reportedNetwork => _networkWords;

  /// Entries the reader holds paths for. Read by the acceptance test that proves
  /// a long session does not grow.
  int get memoSize => _paths.length;

  /// A move happened; the window shrinks to the visible spread while these are
  /// close together, and the core decides what "close" costs.
  void _noteMove() {
    final now = DateTime.now();
    final flipping =
        _lastMove != null && now.difference(_lastMove!) < settleWindow;
    _lastMove = now;
    if (flipping && window != null) {
      unawaited(_reReportDeviceNow(stable: false));
    }
  }

  /// The core's answer to the last report, or null when no device was described.
  bool get isFlipping {
    final last = _lastMove;
    return last != null && DateTime.now().difference(last) < settleWindow;
  }

  Future<void> _reportDevice() => _reReportDeviceNow(stable: !isFlipping);

  Future<void> _reReportDeviceNow({required bool stable}) async {
    if (_isClosed) return;
    final probe = device;
    if (probe == null) return;
    try {
      final profile = await probe.profile(
        network: _networkWords,
        stable: stable,
      );
      if (_isClosed) return;
      final plan = await api.configureDevice(profile);
      if (_isClosed) return;
      window = plan;
      // Keep enough paths for the whole window plus what is on screen, and no
      // more: this is the number that used to be "forever".
      final span = (plan.forward + plan.back + 1).toInt() *
          plan.pagesPerSpread.toInt() *
          2;
      _memoLimit = span < 32 ? 32 : (span > 256 ? 256 : span);
      while (_paths.length > _memoLimit) {
        _paths.remove(_paths.keys.first);
      }
      ImageCacheBudget.apply(plan);
      notifyListeners();
    } catch (exception) {
      if (_isClosed) return;
      _deviceReportError = '$exception';
      notifyListeners();
    }
  }

  /// The last failure to report the device profile, if any. `null` means the
  /// reports are landing.
  String? get deviceReportError => _deviceReportError;
  String? _deviceReportError;

  /// Re-plan only when the inferred link state actually moved: re-reporting on
  /// every failure would turn an outage into a request storm of a different kind.
  Future<void> _reReportIfLinkChanged() async {
    if (_isClosed) return;
    final before = _networkWords;
    _networkWords = NetworkWords.infer(
      recentFailures: _recentFailures,
      recentSlowResponses: _recentSlowResponses,
    );
    if (_networkWords == before || _isClosed) return;
    await _reReportDeviceNow(stable: !isFlipping);
    if (_isClosed) return;
    await _warmWindow();
  }

  /// The OS is squeezing memory. Release RAM — Flutter's decoded bitmaps and the
  /// core's mirror of the prefetched bytes — and keep what is on screen *and* on
  /// disk. Deleting the prefetch tier here was the original response and it was
  /// wrong twice over: a stored file costs no RAM, and Android signals pressure on
  /// every backgrounding, so each trip through HOME came back with the whole window
  /// to re-download. This is the response, not a log line.
  ///
  /// Counted, because "we handle onTrimMemory" is otherwise unverifiable: the
  /// acceptance driver watches this counter to know the platform actually called
  /// us, and then checks that the page on screen survived it.
  int get memoryPressureEvents => _memoryPressureEvents;
  int _memoryPressureEvents = 0;

  /// What the decoded-image cache held the instant pressure arrived, and what it
  /// holds now. Read at that instant on purpose: a caller that asks afterwards
  /// measures an empty cache against an empty one and concludes nothing happened.
  int get lastPressureCacheBytesBefore => _pressureBefore;
  int get lastPressureCacheBytesAfter => _pressureAfter;
  int _pressureBefore = 0;
  int _pressureAfter = 0;

  Future<void> onMemoryPressure() async {
    if (_isClosed) return;
    _memoryPressureEvents += 1;
    _pressureBefore = PaintingBinding.instance.imageCache.currentSizeBytes;
    PaintingBinding.instance.imageCache.clear();
    _pressureAfter = PaintingBinding.instance.imageCache.currentSizeBytes;
    _recentSlowResponses = 0;
    try {
      await api.releasePrefetch();
    } catch (_) {
      // Nothing to free, or nothing reachable; either way the pages on screen
      // are unaffected, which is the property that matters.
    }
    if (_isClosed) return;
    await _reReportDeviceNow(stable: true);
  }

  bool get isWaitingForPage => _inFlight.isNotEmpty;

  /// Prefetch the window around the current spread. The core decides which
  /// pages are worth pulling (current, then ahead, then behind) and skips
  /// whatever is already on disk.
  ///
  /// One pass at a time. Every turn used to fire another, and each pass can hold
  /// the platform thread for a whole window of downloads — so a fast reader
  /// turned ten pages into ten queued windows, measured on the emulator as
  /// 118 ms p95 per turn against 32 ms for this guard. Skipping is free: the
  /// next turn re-plans from wherever the reader has actually got to.
  Future<void> _warmWindow() async {
    if (_isClosed || pageCount == 0 || _prefetchInFlight) return;
    _prefetchInFlight = true;
    try {
      // `inFlight` from the plan is the concurrency the link can take; the core
      // enforces it, the UI only passes the spread index.
      final landed = await api.prefetch(spread);
      if (_isClosed) return;
      // Only a prefetch that actually pulled something is evidence about the
      // link. A pass that found nothing to fetch returns 0 in perfect health *and*
      // returns 0 through a dead radio, so treating it as proof of life cleared the
      // outage tally on every turn and the link was never learned to be gone.
      if (landed > 0 && _recentFailures > 0) _recentFailures = 0;
      unawaited(_reReportIfLinkChanged());
    } catch (_) {
      if (_isClosed) return;
      // Prefetch stays advisory — a cold neighbour must never surface as a
      // failure. But it is also the only thing that keeps asking when the reader
      // has stopped asking, so it is what the link verdict has to be built on:
      // counting failures only in the display path made the two-failure threshold
      // unreachable, because after one failed page the reader waits for a tap and
      // the outage was never inferred.
      _recentFailures += 1;
      unawaited(_reReportIfLinkChanged());
    } finally {
      _prefetchInFlight = false;
    }
  }

  bool _prefetchInFlight = false;

  /// How many times the platform has moved this reader out of and back into the
  /// foreground. Counted because "background restore works" is otherwise a claim
  /// about code that exists rather than about behaviour that happened, and a device
  /// run is the only place that can tell those apart.
  int get lifecyclePauses => _pauses;
  int get lifecycleResumes => _resumes;
  int _pauses = 0;
  int _resumes = 0;

  /// Whether a prefetch pass is currently holding the platform thread. Read by
  /// the acceptance driver, which needs to know that "no duplicates" was not
  /// simply "prefetch never ran".
  bool get prefetchInFlight => _prefetchInFlight;

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (_) async {
      if (_isClosed) return;
      try {
        if (await api.tick()) {
          if (_isClosed) return;
          _uploadPending = true;
        }
        if (_uploadPending && !_isClosed) {
          await api.flushOutbox();
          _uploadPending = false;
        }
      } catch (_) {
        // Offline: the queue is durable, so the next beat tries again.
      }
    });
  }

  Future<void> markRead() async {
    if (_isClosed) return;
    try {
      if (await api.markRead()) {
        if (_isClosed) return;
        await api.flushOutbox();
      }
      if (_isClosed) return;
      notifyListeners();
    } catch (exception) {
      if (_isClosed) return;
      error = '$exception';
      notifyListeners();
    }
  }

  Future<void> markUnread() async {
    if (_isClosed) return;
    try {
      if (await api.markUnread()) {
        if (_isClosed) return;
        await api.flushOutbox();
      }
      if (_isClosed) return;
      notifyListeners();
    } catch (exception) {
      if (_isClosed) return;
      error = '$exception';
      notifyListeners();
    }
  }

  /// Home / app switch: pay the queue before the process may be suspended, and
  /// hand back the decoded bitmaps — a backgrounded reader has no business
  /// holding a screenful of 4K images against a system that may reclaim them.
  Future<void> paused() async {
    if (_isClosed) return;
    _pauses += 1;
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await flushPageOffset();
      if (_isClosed) return;
      if (await api.background()) {
        if (_isClosed) return;
        await api.flushOutbox();
      }
    } catch (_) {
      // Durable in SQLite; retried on resume or on the next beat.
    }
  }

  /// Coming back: the link may have changed (Wi-Fi dropped to cellular while the
  /// phone slept), the window may have to shrink, and the pages on screen have to
  /// be re-resolved. Nothing here re-downloads what the cache still holds.
  Future<void> resumed() async {
    if (_isClosed) return;
    _resumes += 1;
    _recentFailures = 0;
    _recentSlowResponses = 0;
    _networkWords = NetworkWords.wifi;
    _lastMove = null;
    await _reportDevice();
    if (_isClosed) return;
    await _warmWindow();
    if (_isClosed) return;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_isClosed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_isClosed) return;
    _ticker?.cancel();
    _ticker = null;
    // The reader's limits belong to the reader. Leaving them in place would make
    // the library screens cache like a comic viewer.
    ImageCacheBudget.restore();
    // Fire-and-forget: the write itself is already durable, and a closing
    // screen must not wait on a network round-trip.
    final closing = flushPageOffset();
    _isClosed = true;
    _closedFuture = () async {
      try {
        // Order matters: the scroll position lives in the session, and closing
        // the session is what writes it down. Close first and the last position
        // is the one from the previous write.
        await closing;
        if (await api.close()) await api.flushOutbox();
      } catch (_) {
        // The queue outlives this screen either way.
      }
    }();
    if (_keepAwakeApplied) {
      unawaited(systemControls?.setKeepScreenAwake(false) ??
          Future<bool>.value(false));
    }
    unawaited(systemControls?.setBrightness(null) ?? Future<bool>.value(false));
    super.dispose();
  }
}

// flutter_rust_bridge generates plain data classes, so the copy helpers the
// controller needs live here rather than in the generated tree (which is
// rewritten by scripts/frb_wire.sh on every change to the Rust surface).
extension ReaderLayoutDtoX on ReaderLayoutDto {
  ReaderLayoutDto copyWithTurn(ReaderTurnDto turn) => ReaderLayoutDto(
        spreads: spreads,
        spread: turn.spread,
        page: turn.page,
        axis: axis,
        reversed: reversed,
        advanceSwipe: advanceSwipe,
        retreatSwipe: retreatSwipe,
        tapNext: tapNext,
        tapPrev: tapPrev,
        mode: mode,
        direction: direction,
        pageGap: pageGap,
        background: background,
      );
}

extension ReaderBookDtoX on ReaderBookDto {
  ReaderBookDto copyWith({ReaderLayoutDto? layout}) => ReaderBookDto(
        serverId: serverId,
        bookId: bookId,
        pageCount: pageCount,
        paged: paged,
        reflowable: reflowable,
        fallback: fallback,
        fromMirror: fromMirror,
        startPage: startPage,
        layout: layout ?? this.layout,
      );
}

extension ReaderSettingsDtoX on ReaderSettingsDto {
  ReaderSettingsDto copyWith({
    String? mode,
    String? direction,
    bool? firstPageSingle,
    int? pageGap,
    String? background,
    bool? keepScreenAwake,
    double? brightness,
    bool? restorePosition,
    int? prefetchForward,
    int? prefetchBack,
    int? prefetchCap,
    bool? volumeKeysEnabled,
  }) =>
      ReaderSettingsDto(
        mode: mode ?? this.mode,
        direction: direction ?? this.direction,
        firstPageSingle: firstPageSingle ?? this.firstPageSingle,
        pageGap: pageGap ?? this.pageGap,
        background: background ?? this.background,
        keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
        brightness: brightness ?? this.brightness,
        restorePosition: restorePosition ?? this.restorePosition,
        prefetchForward: prefetchForward ?? this.prefetchForward,
        prefetchBack: prefetchBack ?? this.prefetchBack,
        prefetchCap: prefetchCap ?? this.prefetchCap,
        volumeKeysEnabled: volumeKeysEnabled ?? this.volumeKeysEnabled,
      );
}
