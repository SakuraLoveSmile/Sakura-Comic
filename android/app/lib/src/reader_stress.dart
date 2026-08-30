import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_api.dart';
import 'reader_controller.dart';
import 'reader_device.dart';
import 'reader_screen.dart';
import 'reader_system_controls.dart';

/// Stage 8 device acceptance entry: route `/reader-stress`.
///
/// The loopback harness (`scripts/e2e_stage8.sh`) can prove request counts and
/// cache behaviour, but it cannot see what a real frame costs, what the process
/// costs in memory, or what happens when the radio actually goes away. Those
/// acceptance lines only have a device to be measured on.
///
/// So this is not a feature: it opens the real reader — same [ReaderScreen],
/// same [ReaderController], same [FrbReaderApi], same [ReaderDevice] report — and
/// drives it on a fixed cadence, reporting what the acceptance script needs
/// through `debugPrint`. Everything it takes comes from the route string, which
/// `am start --es route …` supplies: no taps, no coordinates, no test-only copy
/// of the reading path.
class ReaderStressParams {
  const ReaderStressParams({
    required this.baseUrl,
    required this.apiKey,
    required this.bookId,
    this.serverId = 'stress',
    this.pages = 120,
    this.turnDelayMs = 120,
    this.mode = 'single',
    this.warmupMs = 3000,
    this.deviceMemoryBytes = 0,
    this.back = 1,
  });

  final String baseUrl;
  final String apiKey;
  final String bookId;
  final String serverId;

  /// How many page turns to make in total.
  final int pages;

  /// The cadence a thumb manages — deliberately faster than comfortable reading,
  /// since the window is supposed to narrow under it.
  final int turnDelayMs;
  final String mode;

  /// Headroom for the initial open (manifest plus first page over the network).
  final int warmupMs;

  /// Report this much RAM instead of what the device says. A measurement
  /// instrument, not a product path: it is how a low-end phone gets measured on
  /// hardware that is not one, so the plan's response to device class is observed
  /// rather than assumed. `0` means ask the platform.
  final int deviceMemoryBytes;

  /// How the turn budget splits. 1 (the default) reads out and back over the same
  /// pages, which is what a cache measurement wants. 0 reads forward only — the
  /// only way to reach pages the prefetch never warmed, and therefore the only way
  /// for the reader to have to notice that the network is gone.
  final int back;

  static const String routePrefix = '/reader-stress';

  /// Null for any route that is not ours, so the app launches normally unless
  /// specifically asked to run the stress.
  static ReaderStressParams? parse(String route) {
    if (!route.startsWith(routePrefix)) return null;
    final query = route.substring(routePrefix.length).replaceFirst('?', '');
    final values = <String, String>{};
    for (final pair in query.split('&')) {
      final split = pair.indexOf('=');
      if (split > 0) {
        values[pair.substring(0, split)] = Uri.decodeComponent(pair.substring(split + 1));
      }
    }
    final base = values['base'];
    final book = values['book'];
    if (base == null || book == null) return null;
    return ReaderStressParams(
      baseUrl: base,
      apiKey: values['key'] ?? '',
      bookId: book,
      serverId: values['server'] ?? 'stress',
      pages: int.tryParse(values['pages'] ?? '') ?? 120,
      turnDelayMs: int.tryParse(values['delay'] ?? '') ?? 120,
      mode: values['mode'] ?? 'single',
      warmupMs: int.tryParse(values['warmup'] ?? '') ?? 3000,
      deviceMemoryBytes: int.tryParse(values['ram'] ?? '') ?? 0,
      back: int.tryParse(values['back'] ?? '') ?? 1,
    );
  }
}

class ReaderStressScreen extends StatefulWidget {
  const ReaderStressScreen({super.key, required this.params});

  final ReaderStressParams params;

  @override
  State<ReaderStressScreen> createState() => _ReaderStressScreenState();
}

class _ReaderStressScreenState extends State<ReaderStressScreen> {
  ReaderController? _controller;
  final List<int> _coldMs = <int>[];
  final List<int> _warmMs = <int>[];
  int _turned = 0;
  int _seenPressureEvents = 0;
  int _seenCycles = -1;
  String _seenNetwork = '';
  String? _seenReportError;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _controller?.removeListener(_reportState);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}/comic.sqlite';
    final params = widget.params;
    final api = FrbReaderApi(
      dbPath: dbPath,
      serverId: params.serverId,
      bookId: params.bookId,
      baseUrl: params.baseUrl,
      apiKey: params.apiKey,
    );
    final device = params.deviceMemoryBytes > 0
        ? ReaderDevice(memoryProbe: () async => params.deviceMemoryBytes)
        : ReaderDevice();
    final controller = ReaderController(
      api: api,
      device: device,
      systemControls: ReaderSystemControls(),
      // A driven run must not throttle its uploads into a queue that looks live.
      tickInterval: const Duration(hours: 1),
    );
    _controller = controller;
    // The lifecycle hooks that answer `onTrimMemory` live in [ReaderScreen]'s own
    // observer, deliberately not here: a second observer would count one platform
    // signal as two and report a response that never happened twice.
    controller.addListener(_reportState);
    await controller.start();
    if (!mounted) return;
    setState(() {});
    if (controller.error != null) {
      _report('open-failed', {'error': controller.error!});
      return;
    }
    if (controller.mode != params.mode) {
      await controller.setMode(params.mode);
    }
    await _reportWindow(controller, device);
    await _drive(controller);
  }

  /// What the core derived for this device, and what Flutter then applied.
  /// Printed because the whole point of the plan is that the UI acts on it: a
  /// device run is the only place that proves the report reached the platform.
  Future<void> _reportWindow(ReaderController controller, ReaderDevice device) async {
    final window = controller.window;
    final cache = PaintingBinding.instance.imageCache;
    _report('window', {
      'pages': controller.pageCount,
      'forward': window?.forward.toString() ?? '-',
      'back': window?.back.toString() ?? '-',
      'cap': window?.cap.toString() ?? '-',
      'inFlight': window?.inFlight.toString() ?? '-',
      'memoryBudget': window?.memoryBudgetBytes.toString() ?? '-',
      'decodeSlots': window?.decodeSlots.toString() ?? '-',
      'avgPageBytes': window?.avgPageBytes.toString() ?? '-',
      'cacheMaxBytes': cache.maximumSizeBytes.toString(),
      'cacheMaxCount': cache.maximumSize.toString(),
      'deviceRam': await device.totalMemoryBytes(),
    });
  }

  /// One pass of `steps` turns, each timed the way a reader feels it: the position
  /// write, the page resolution, **and a painted frame**. Without the frame
  /// barrier this measures only the SQLite write and reports a fantasy — a first
  /// attempt did exactly that, and "turned" 120 pages a second without decoding
  /// one of them.
  Future<void> _pass(
    ReaderController controller,
    int steps,
    bool forward,
    List<int> samples,
  ) async {
    final cadence = Duration(milliseconds: widget.params.turnDelayMs);
    final stopwatch = Stopwatch();
    for (var step = 0; step < steps; step++) {
      if (!mounted || controller.pageCount == 0) return;
      if (controller.error != null) {
        // Reported and then continued with, exactly as a reader tapping the retry
        // affordance would: stopping here would mean the outage was only ever
        // observed once, and one observation is below the inference threshold.
        _report('error', {'step': '$step', 'page': controller.page, 'error': controller.error!});
      }
      stopwatch
        ..reset()
        ..start();
      if (forward) {
        await controller.next();
      } else {
        await controller.previous();
      }
      await controller.imageFor(controller.page);
      await WidgetsBinding.instance.endOfFrame;
      stopwatch.stop();
      samples.add(stopwatch.elapsedMilliseconds);
      _turned += 1;
      // Every turn, not every twentieth: the acceptance script times its radio cut
      // against a specific turn, and a sparse log makes it cut after the read has
      // already finished — which proves nothing about outage detection.
      _report('turn', {
        'at': '$_turned',
        'page': controller.page,
        'ms': stopwatch.elapsedMilliseconds,
        // The window the core is using right now. A driven read turns faster than
        // the settle window, so this must fall to the visible spread; that shrink
        // is the "快翻时窗口自动收窄" requirement, observable only here.
        'cap': controller.window?.cap.toString() ?? '-',
        'inFlight': controller.window?.inFlight.toString() ?? '-',
        'flipping': controller.isFlipping,
        'network': controller.reportedNetwork,
        'memo': controller.memoSize,
        'cacheCount': PaintingBinding.instance.imageCache.currentSize,
        'cacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      });
      final remaining = cadence - stopwatch.elapsed;
      await Future<void>.delayed(remaining.isNegative ? Duration.zero : remaining);
    }
  }

  Future<void> _drive(ReaderController controller) async {
    await Future<void>.delayed(Duration(milliseconds: widget.params.warmupMs));
    final params = widget.params;
    final forward = params.back == 0 ? params.pages : (params.pages / 2).floor();
    final last = (controller.pageCount - 1).clamp(1, 1 << 30);
    final steps = forward.clamp(1, last).toInt();
    // Out and back over the same pages: the outbound half pays the download and
    // the first decode, the return half is what scrolling back through a cached
    // book actually costs.
    await _pass(controller, steps, true, _coldMs);
    if (params.back != 0) {
      await _pass(controller, steps, false, _warmMs);
    }
    if (!mounted) return;
    setState(() => _finished = true);
    _report('done', {
      'turns': _turned,
      'coldP50ms': _percentile(_coldMs, 0.5),
      'coldP95ms': _percentile(_coldMs, 0.95),
      'coldMaxms': _max(_coldMs),
      'warmP50ms': _percentile(_warmMs, 0.5),
      'warmP95ms': _percentile(_warmMs, 0.95),
      'warmMaxms': _max(_warmMs),
      'page': controller.page,
      'cacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'cacheCount': PaintingBinding.instance.imageCache.currentSize,
      'memo': controller.memoSize,
    });
  }

  /// Everything the controller decides that the driver cannot see from outside:
  /// the link it now believes it is on, and the memory pressure the platform
  /// asked about.
  void _reportState() {
    final controller = _controller;
    if (controller == null) return;
    final link = controller.reportedNetwork;
    if (link != _seenNetwork) {
      _seenNetwork = link;
      _report('link', {
        'network': link,
        'page': controller.page,
        'flipping': controller.isFlipping,
        'cap': controller.window?.cap.toString() ?? '-',
        'inFlight': controller.window?.inFlight.toString() ?? '-',
      });
    }
    final failure = controller.deviceReportError;
    if (failure != _seenReportError) {
      _seenReportError = failure;
      if (failure != null) {
        _report('report-error', {'error': failure, 'network': controller.reportedNetwork});
      }
    }
    // Background / foreground, as the platform delivered it. Reported here rather
    // than asserted from source text, because the hooks existing in the widget
    // tree is not evidence that a resume actually re-described the device and
    // re-warmed the window.
    final cycles = controller.lifecyclePauses + controller.lifecycleResumes;
    if (cycles != _seenCycles) {
      _seenCycles = cycles;
      _report('lifecycle', {
        'pauses': controller.lifecyclePauses,
        'resumes': controller.lifecycleResumes,
        'page': controller.page,
        'cacheCount': PaintingBinding.instance.imageCache.currentSize,
        'cacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
        'network': controller.reportedNetwork,
      });
    }
    final events = controller.memoryPressureEvents;
    if (events == _seenPressureEvents) return;
    _seenPressureEvents = events;
    // Read the response's own record of the cache, and read it now: after an await
    // the framework may have dropped those entries by itself, and a 0-against-0
    // comparison would read as "nothing to release" when everything was released.
    unawaited(_describePressure(
      controller,
      events,
      controller.lastPressureCacheBytesBefore,
      controller.lastPressureCacheBytesAfter,
    ));
  }

  Future<void> _describePressure(
    ReaderController controller,
    int events,
    int before,
    int after,
  ) async {
    final page = controller.page;
    // The property under test: a pressure response that cost the reader the page
    // on screen would be worse than doing nothing at all.
    final path = await controller.imageFor(page);
    _report('pressure', {
      'events': events,
      'cacheBytesBefore': before,
      'cacheBytesAfter': after,
      'cacheBytesGivenBack': before - after,
      'page': page,
      'stillReadable': path != null,
      'memo': controller.memoSize,
    });
  }

  void _report(String kind, Map<String, Object?> fields) {
    final joined = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    debugPrint('STRESS $kind $joined');
  }

  static int _percentile(List<int> samples, double basis) {
    if (samples.isEmpty) return 0;
    final sorted = [...samples]..sort();
    return sorted[((sorted.length - 1) * basis).round()];
  }

  static int _max(List<int> samples) =>
      samples.isEmpty ? 0 : samples.reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Stack(
      children: [
        ReaderScreen(controller: controller),
        Positioned(
          left: 8,
          top: MediaQuery.of(context).padding.top + 8,
          child: Material(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                _finished
                    ? 'stress done: $_turned turns'
                    : 'stress $_turned/${widget.params.pages}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
