import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'download_controller.dart';
import 'downloads_api.dart';
import 'reader_api.dart';
import 'reader_device.dart';
import 'rust/ffi/bridge.dart' as frb;

/// Stage 9 device acceptance entry: route `/download-stress`.
///
/// The loopback gate can prove that a book reads with the server unreachable, but
/// `http://127.0.0.1:1` is not the same event as the radio going off in a pocket: it
/// cannot see Android tearing down a live socket, cannot observe the process surviving
/// it, and cannot prove that a queued write made during the outage leaves the device
/// once connectivity returns. Those lines only have a device to be measured on.
///
/// So this is not a feature. It drives the same [FrbDownloadsApi], the same
/// [DownloadController], the same [FrbReaderApi] and the same [ReaderDevice] report the
/// screens use, and reports through `debugPrint` what the acceptance script asserts on.
/// Every parameter comes from the route string, which `am start --es route …` supplies:
/// no taps, no coordinates, no test-only copy of the download path.
///
/// Modes, in the order a real evening would visit them:
///
///   download  mirror the manifest, queue the book, pump it to completion.
///   offline   read the whole book with the route dead, saving progress as it goes.
///             Where each page came from is classified against the real download
///             directory rather than believed on report.
///   upload    drain the outbox and say what the queue holds afterwards.
///   resume    pump without enqueueing: the path a relaunch actually takes.
class DownloadStressParams {
  const DownloadStressParams({
    required this.baseUrl,
    required this.apiKey,
    required this.bookId,
    required this.mode,
    this.deadUrl = 'http://127.0.0.1:1',
    this.serverId = 'stress',
    this.pages = 0,
    this.maxPages = 4,
    this.turnDelayMs = 30,
    this.cellular = false,
  });

  final String baseUrl;
  final String apiKey;
  final String bookId;
  final String mode;

  /// The route used for the offline leg. Port 1 in the emulator's own loopback is
  /// unreachable the same way a powered-off radio is: a failed connect, not a mock.
  final String deadUrl;
  final String serverId;

  /// How many pages to read in `offline`. 0 means "as many as the book has".
  final int pages;

  /// Pages per pass, so the pass bound is visible on a device too.
  final int maxPages;
  final int turnDelayMs;

  /// Grant the per-book "spend my data" consent before pumping. An emulator's active
  /// network is metered (`isActiveNetworkMetered()` answers true), so without this the
  /// queue correctly refuses — and the leg would measure nothing.
  final bool cellular;

  static const String routePrefix = '/download-stress';

  /// Null for any route that is not ours, so the app launches normally unless the
  /// harness asks for exactly this.
  static DownloadStressParams? parse(String route) {
    if (!route.startsWith(routePrefix)) return null;
    final query = route.substring(routePrefix.length).replaceFirst('?', '');
    final values = <String, String>{};
    for (final pair in query.split('&')) {
      final split = pair.indexOf('=');
      if (split > 0) {
        values[pair.substring(0, split)] =
            Uri.decodeComponent(pair.substring(split + 1));
      }
    }
    final base = values['base'];
    final book = values['book'];
    final mode = values['mode'];
    if (base == null || book == null || mode == null) return null;
    return DownloadStressParams(
      baseUrl: base,
      apiKey: values['key'] ?? '',
      bookId: book,
      mode: mode,
      deadUrl: values['dead'] ?? 'http://127.0.0.1:1',
      serverId: values['server'] ?? 'stress',
      pages: int.tryParse(values['pages'] ?? '') ?? 0,
      maxPages: int.tryParse(values['max'] ?? '') ?? 4,
      turnDelayMs: int.tryParse(values['delay'] ?? '') ?? 30,
      cellular: (values['cellular'] ?? '') == '1',
    );
  }
}

class DownloadStressScreen extends StatefulWidget {
  const DownloadStressScreen({super.key, required this.params});

  final DownloadStressParams params;

  @override
  State<DownloadStressScreen> createState() => _DownloadStressScreenState();
}

class _DownloadStressScreenState extends State<DownloadStressScreen> {
  String _dbPath = '';
  String _status = 'preparing';
  bool _finished = false;

  /// One device handle for the whole run: it is how the free-space and link answers
  /// reach the core, and asking the platform twice for the same fact is how a
  /// measurement starts describing the instrument rather than the device.
  final ReaderDevice _device = ReaderDevice();

  void _metric(String name, Object value) => debugPrint('DL $name=$value');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final params = widget.params;
    final docs = await getApplicationDocumentsDirectory();
    _dbPath = '${docs.path}/comic.sqlite';
    final downloads = FrbDownloadsApi(
      dbPath: _dbPath,
      serverId: params.serverId,
      baseUrl: params.baseUrl,
      apiKey: params.apiKey,
    );
    final reader = FrbReaderApi(
      dbPath: _dbPath,
      serverId: params.serverId,
      bookId: params.bookId,
      baseUrl: params.baseUrl,
      apiKey: params.apiKey,
    );
    final controller = DownloadController(
      downloads,
      link: _device.linkClass,
      freeBytes: _device.freeDiskBytes,
    );
    setState(() => _status = params.mode);
    try {
      switch (params.mode) {
        case 'download':
          await _pumpToCompletion(params, downloads, reader, enqueue: true);
          break;
        case 'resume':
          await _pumpToCompletion(params, downloads, reader);
          break;
        case 'offline':
          await _offline(params, downloads, docs.path);
          break;
        case 'upload':
          await _upload(params);
          break;
        case 'link':
          // Report only: what the platform says about the link and the volume, under
          // whatever radio state the script just put the device in.
          _metric('linkClass', await _device.linkClass());
          _metric('freeBytes', await _device.freeDiskBytes());
          _metric('meteredAllowed', 'n/a');
          break;
        default:
          debugPrint('DL error=unknown mode ${params.mode}');
      }
    } catch (error) {
      debugPrint('DL failed=$error');
      _status = 'failed: $error';
    } finally {
      controller.stop();
    }
    setState(() {
      _finished = true;
      _status = '${params.mode} done';
    });
    debugPrint('DL done mode=${params.mode}');
  }

  /// The offline copy of the tree, as the platform computes it. Pages are classified
  /// against this path, so `servedFromDownloads` is a fact about where the bytes came
  /// from rather than about what the core believes it has.
  String _treePath(String docsPath, String serverId, String bookId) =>
      '$docsPath/downloads/${_safe(serverId)}/${_safe(bookId)}';

  String _safe(String key) => key
      .split('')
      .map((c) => RegExp(r'[A-Za-z0-9._-]').hasMatch(c) ? c : '_')
      .join();

  /// Drive the queue to the end of this book, reporting the shape of the run.
  ///
  /// `enqueue: false` is the relaunch path: the queue is already in SQLite, so nothing
  /// is created and the pump picks the book up where the rows say it stopped. A harness
  /// that always enqueued could not tell a resume from a restart — re-enqueueing also
  /// rebuilds the page rows, which the sweep then adopts back from disk, so the two
  /// paths reach the same end by different amounts of work and only one of them is what
  /// a user who force-stopped the app would see.
  Future<void> _pumpToCompletion(
    DownloadStressParams params,
    FrbDownloadsApi downloads,
    FrbReaderApi reader, {
    bool enqueue = false,
  }) async {
    final docs = (await getApplicationDocumentsDirectory()).path;
    var total = 0;
    if (enqueue) {
      // Mirror the manifest first: a book that was never opened cannot be queued, and
      // that is the rule rather than a limitation of this harness.
      final opened = await reader.open();
      _metric('seedPages', opened.pageCount);
      final queued = await downloads.enqueue(params.bookId);
      _metric('queuedPages', queued.pagesTotal);
      _metric('queuedBytes', queued.bytesTotal);
      total = queued.pagesTotal;
    }
    if (params.cellular) {
      await downloads.setAllowCellular(params.bookId, true);
      _metric('consentGranted', 1);
    }
    final start = (await downloads.list())
        .firstWhere((book) => book.bookId == params.bookId);
    total = start.pagesTotal;
    _metric('startPages', start.pagesDone);
    _metric('startState', start.state);
    final startedAt = DateTime.now();
    var passes = 0;
    var served = 0;
    var lastStop = '';
    while (passes < total * 2) {
      final report = await downloads.pump(
        maxPages: params.maxPages,
        freeBytes: await _device.freeDiskBytes(),
        link: await _device.linkClass(),
      );
      if (report == null) continue;
      passes += 1;
      served += report.served;
      lastStop = report.stopReason;
      _metric('sweepRepairs', report.repairs);
      _metric('sweepParts', report.partsSwept);
      _metric('sweepAdopted', report.adopted);
      final mine = (await downloads.list())
          .firstWhere((book) => book.bookId == params.bookId);
      if (mine.state == 'completed' || mine.state == 'failed') break;
      if (report.served == 0) {
        // Every pass that landed nothing is reported, with the reason the core gave.
        // A stuck loop is otherwise invisible from the outside, and "why did the
        // device download nothing" has exactly one useful answer: the stop reason.
        debugPrint('DL pass=$passes served=0 stop=${report.stopReason} '
            'nextInMs=${report.nextInMs} state=${mine.state}');
        // A pass that landed nothing is parked, idle, or waiting on a link that has to
        // be given a moment — the same distinction the ticker draws from nextInMs.
        if (report.stopReason == 'idle' ||
            report.stopReason == 'parked' ||
            report.stopReason == 'lowSpace' ||
            report.stopReason == 'linkBlocked') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!report.queueActive) break;
      }
    }
    final finalRow = (await downloads.list())
        .firstWhere((book) => book.bookId == params.bookId);
    final storage = await downloads.storage(await _device.freeDiskBytes());
    // Counted by the driver from the filesystem, not from the core's report: the
    // storage figures are per app (every book in the queue), and this claim is about
    // one book. An independent witness is the point.
    final tree = _treePath(docs, params.serverId, params.bookId);
    var pageFiles = 0;
    var parts = 0;
    if (Directory(tree).existsSync()) {
      for (final entity in Directory(tree).listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == 'manifest.json') continue;
        if (name.endsWith('.part')) {
          parts += 1;
        } else {
          pageFiles += 1;
        }
      }
    }
    _metric('treeFiles', pageFiles);
    _metric('treeParts', parts);
    final seconds = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    _metric('passes', passes);
    _metric('served', served);
    // The reason the last pass stopped, which is the difference between a queue that
    // finished, one that was refused a link, and one that is merely parked.
    _metric('lastStop', lastStop);
    _metric('state', finalRow.state);
    _metric('pagesDone', finalRow.pagesDone);
    _metric('pagesTotal', finalRow.pagesTotal);
    _metric('bytesDb', finalRow.bytesDone);
    _metric('diskBytes', storage.downloadDiskBytes);
    _metric('diskFiles', storage.downloadDiskFiles);
    _metric('freeBytes', storage.freeVolumeBytes);
    _metric('linkAtStart', await _device.linkClass());
    _metric('seconds', seconds.toStringAsFixed(1));
    _metric(
      'pagesPerSecond',
      (served / (seconds == 0 ? 1 : seconds)).toStringAsFixed(1),
    );
  }

  Future<void> _offline(
    DownloadStressParams params,
    FrbDownloadsApi downloads,
    String docsPath,
  ) async {
    final tree = _treePath(docsPath, params.serverId, params.bookId);
    _metric('treeExists', Directory(tree).existsSync() ? 1 : 0);
    // A reader pointed at a dead route: every page that resolves has to have come from
    // the device.
    final dead = FrbReaderApi(
      dbPath: _dbPath,
      serverId: params.serverId,
      bookId: params.bookId,
      baseUrl: params.deadUrl,
      apiKey: 'dead-key',
    );
    final opened = await dead.open();
    _metric('openedFromMirror', opened.fromMirror ? 1 : 0);
    final want = params.pages == 0 ? opened.pageCount : params.pages;
    var served = 0;
    var fromDownloads = 0;
    var missing = 0;
    for (var page = 1; page <= want; page++) {
      try {
        final path = await dead.page(page);
        served += 1;
        if (path.startsWith(tree)) fromDownloads += 1;
      } catch (error) {
        missing += 1;
        debugPrint('DL pageFail=$page error=$error');
      }
      if (page % 10 == 0) {
        await Future<void>.delayed(Duration(milliseconds: params.turnDelayMs));
      }
    }
    _metric('pagesWanted', want);
    _metric('pagesServed', served);
    _metric('servedFromDownloads', fromDownloads);
    _metric('pagesFailed', missing);
    // Reading is only half of the claim: turning a page has to write progress, and it
    // has to survive having nowhere to send it.
    final before =
        await frb.outboxStatus(dbPath: _dbPath, serverId: params.serverId);
    final turn = await dead.turn(want < 3 ? want : 3);
    final after =
        await frb.outboxStatus(dbPath: _dbPath, serverId: params.serverId);
    _metric('positionPage', turn.page);
    _metric('pendingBefore', before.pending);
    _metric('pendingAfter', after.pending);
    final position = await dead.pagePath(3);
    _metric('positionStillReads', position == null ? 0 : 1);
    await dead.close();
  }

  Future<void> _upload(DownloadStressParams params) async {
    final before =
        await frb.outboxStatus(dbPath: _dbPath, serverId: params.serverId);
    _metric('pendingBefore', before.pending);
    final outcome = await frb.uploadOutbox(
      dbPath: _dbPath,
      serverId: params.serverId,
      baseUrl: params.baseUrl,
      apiKey: params.apiKey,
    );
    final after =
        await frb.outboxStatus(dbPath: _dbPath, serverId: params.serverId);
    _metric('uploaded', outcome.uploaded);
    _metric('considered', outcome.considered);
    _metric('pendingAfter', after.pending);
    _metric('failedAfter', after.failed);
  }

  @override
  Widget build(BuildContext context) {
    // The harness reads logcat. The screen exists so there is something real to mount
    // and so a person watching the device can see what is running.
    return Scaffold(
      appBar: AppBar(title: const Text('下载验收')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _finished ? '完成：$_status' : '$_status\n\n${widget.params.bookId}',
          ),
        ),
      ),
    );
  }
}
