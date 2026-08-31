import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/services.dart' show MethodChannel;

import 'rust/ffi/application.dart' show CacheStatsDto, DeviceProfileDto, ReaderWindowDto;

/// Stage 8 device facts, and the memory bounds the reader applies from them.
///
/// The Rust core cannot probe RAM, screen geometry or link quality — and it must
/// not guess generously, because a window that does not fit the device is how a
/// long reading session dies. So this is the only party allowed to answer those
/// three questions, and the only place that writes to Flutter's decoded-image
/// cache limits.
///
/// Anything the platform will not say is reported as `0`, which the core treats
/// as "unknown" and resolves to its conservative floor. An unanswered question
/// shrinks the reader; it never enlarges it.
class ReaderDevice {
  ReaderDevice({
    ui.PlatformDispatcher? dispatcher,
    MethodChannel? channel,
    Future<int> Function()? memoryProbe,
  })  : _dispatcher = dispatcher ?? ui.PlatformDispatcher.instance,
        _channel = channel ?? const MethodChannel('comic/reader'),
        _memoryProbe = memoryProbe;

  final ui.PlatformDispatcher _dispatcher;
  final MethodChannel _channel;
  final Future<int> Function()? _memoryProbe;

  /// How long a platform probe may take before it counts as unanswered.
  static const Duration _probeDeadline = Duration(seconds: 5);

  /// Physical RAM, in bytes, or 0 when the platform will not say.
  ///
  /// Android answers this from `ActivityManager.MemoryInfo.totalMem` over the
  /// same channel the keep-awake and brightness controls use. Anywhere the
  /// channel is missing — a unit test, a desktop shell, an older APK — the
  /// answer is 0 and the core falls back to its default tier.
  Future<int> totalMemoryBytes() async {
    if (_memoryProbe != null) return _memoryProbe();
    try {
      // The channel answers with a Kotlin Long; asking for `int` directly would
      // throw on some codecs, and a thrown answer silently becomes "unknown".
      final reported = await _invoke('totalMemory');
      return (reported as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Pixels one page is decoded at: the view's physical size, not the source
  /// image's. The reader never draws wider than the screen, and `Image.file` is
  /// given a matching `cacheWidth`, so this is the real cost of a decoded page.
  int decodedPageBytes({ui.FlutterView? view}) {
    final target = view ?? _dispatcher.views.first;
    final size = target.physicalSize;
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return 0;
    // RGBA8: four bytes per pixel, and the width is already physical here.
    final pixels = (size.width * size.height).round();
    return pixels * 4;
  }

  /// Device pixel ratio, exposed because the view multiplies by it when it picks
  /// a `cacheWidth` and the two numbers have to agree.
  double get devicePixelRatio => _dispatcher.views.first.devicePixelRatio;

  /// Free bytes on the volume holding the app's files, or 0 when the platform
  /// will not say.
  ///
  /// The core never probes this itself: it has no dep on `statvfs`, and on Android
  /// the answer has to come from the volume the app is actually allowed to write to.
  /// 0 is not "no space" and not "infinite space" — it is "unknown", and the download
  /// planner resolves unknown to "may continue what is running, may not start more".
  Future<int> freeDiskBytes() => _invokeInt('freeDisk');

  /// The link class as the platform reports it: `unmetered`, `metered`, or
  /// `unknown` when the channel is missing or the answer is not readable.
  ///
  /// `ConnectivityManager.isActiveNetworkMetered()` on the Kotlin side, deliberately
  /// not `transport == WIFI`: an emulator answers ETHERNET, and a transport test
  /// there would leave every download permanently blocked and look like a core bug.
  Future<String> linkClass() async {
    try {
      final answer = await _invoke('linkClass');
      final text = (answer as String?) ?? '';
      return const ['unmetered', 'metered'].contains(text) ? text : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<int> _invokeInt(String method) async {
    try {
      final answer = await _invoke(method);
      return (answer as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// One channel call, with a deadline.
  ///
  /// A handler that computes a value but forgets `result.success(...)` never replies,
  /// and the Dart future simply never completes: on a device that is a download that
  /// stalls forever rather than an answered question. "The platform did not answer" is
  /// already a case this class handles — it is reported as 0 / unknown — so it must
  /// also be *reached*, and a hang is the one outcome no caller can degrade. This was
  /// found by exactly that bug in the `freeDisk` handler.
  Future<Object?> _invoke(String method) {
    final completer = Completer<Object?>();
    late Timer watchdog;
    watchdog = Timer(_probeDeadline, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    // Raced rather than chained with `.timeout()`: that leaves its own timer pending
    // until the deadline whenever the platform never answers, and the test binding
    // rightly fails a run for a timer that outlives the widget tree. Cancelling on
    // both settlements is what makes the guard free; the abandoned call is the point,
    // because an unanswered probe must become `unknown` instead of a stall.
    _channel.invokeMethod<Object?>(method).then(
      (answer) {
        watchdog.cancel();
        if (!completer.isCompleted) completer.complete(answer);
      },
      onError: (Object error) {
        watchdog.cancel();
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return completer.future;
  }

  /// The facts to hand the core. `network` and `stable` are the controller's
  /// knowledge, not the platform's, so they are passed in.
  Future<DeviceProfileDto> profile({
    required String network,
    required bool stable,
    int cacheBudgetBytes = 0,
    int avgPageBytesHint = 0,
  }) async =>
      DeviceProfileDto(
        deviceMemoryBytes: await totalMemoryBytes(),
        cacheBudgetBytes: cacheBudgetBytes,
        avgPageBytesHint: avgPageBytesHint,
        decodedPageBytes: decodedPageBytes(),
        network: network,
        stable: stable,
      );
}

/// The numbers the reader applies to Flutter's own decoded-image cache.
///
/// Default `ImageCache` limits are 1000 entries and 100 MB, which is roughly
/// three 4K bitmaps' worth of headroom before the eviction pressure arrives all
/// at once. The core's plan is the only authority on what this device can hold,
/// so both limits come from it.
class ImageCacheBudget {
  const ImageCacheBudget._();

  /// Returns the applied (maximumSizeBytes, maximumSize) pair. Exposed for
  /// tests and for the debug HUD; it never reads anything but the plan.
  static ({int bytes, int slots}) apply(ReaderWindowDto window) {
    final bytes = window.memoryBudgetBytes.toInt();
    final slots = window.decodeSlots.toInt();
    final cache = PaintingBinding.instance.imageCache;
    if (bytes > 0) cache.maximumSizeBytes = bytes;
    if (slots > 0) cache.maximumSize = slots;
    return (bytes: bytes, slots: slots);
  }

  /// Restore Flutter's own defaults, for whoever opens a reader after this one
  /// closes: a bounded reader cache must not become a bounded app cache.
  static void restore() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = _defaultMaximumSize;
    cache.maximumSizeBytes = _defaultMaximumSizeBytes;
  }

  /// 0 when the platform gave no answer, meaning the tier stays whatever the
  /// core decided is safe.
  static int currentBytes() => PaintingBinding.instance.imageCache.maximumSizeBytes;
  static int currentSlots() => PaintingBinding.instance.imageCache.maximumSize;

  /// Flutter's documented defaults, from ` PaintingBinding`.
  static const int _defaultMaximumSize = 1000;
  static const int _defaultMaximumSizeBytes = 100 * 1024 * 1024;
}

/// The three link states the reader distinguishes. Anything else the core maps
/// to `unknown`, which it treats as constrained rather than free.
abstract final class NetworkWords {
  static const String wifi = 'wifi';
  static const String cellular = 'cellular';
  static const String weak = 'weak';
  static const String offline = 'offline';

  /// The state inferred from what requests actually did. The reader has no
  /// connectivity permission and needs none: a page that failed to arrive twice
  /// says the link is down better than any broadcast listener could.
  static String infer({required int recentFailures, required int recentSlowResponses}) {
    if (recentFailures >= 2) return offline;
    if (recentSlowResponses >= 3) return weak;
    return wifi;
  }
}

/// A cache report, formatted the way the debug HUD and the acceptance log want it.
String describeCacheStats(CacheStatsDto stats) => 'pages=${stats.pageBytes} '
    'prefetch=${stats.prefetchBytes} '
    'downloads=${stats.downloadBytes} '
    'ram=${stats.memoryBytes}/${stats.memoryBudgetCeiling()} '
    'hits=${stats.memoryHits} misses=${stats.memoryMisses} '
    'evictions=${stats.memoryEvictions}';

/// Small helper so the report above does not reach into field names twice.
extension CacheStatsCeiling on CacheStatsDto {
  int memoryBudgetCeiling() => poolBudgetBytes.toInt();
}
