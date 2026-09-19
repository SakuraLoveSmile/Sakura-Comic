import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import 'feedback_access.dart';
import 'reader_controller.dart';
import 'reader_offset.dart';

/// The Stage 7 reader.
///
/// Three modes over one layout contract:
///   * 单页 / 双页 — paged, horizontal for LTR / RTL, vertical for Vertical;
///   * 条漫 — one continuous vertical column.
/// Which spread is on screen, in which order its pages sit, and which swipe or
/// tap advances all come from the core's layout, so Android and Apple cannot
/// disagree about what "next page" means.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.controller,
    this.title,
  });

  final ReaderController controller;
  final String? title;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  PageController? _paged;
  final _webtoonKey = GlobalKey<_WebtoonColumnState>();
  Future<void>? _exitCapture;

  /// 反馈作用域与登记状态：阅读中隐藏悬浮球。底部设置页等临时弹层
  /// 不经过这里，计数不受影响；退出阅读器（dispose）后恢复。
  ///
  /// 增减计数都必须推迟到 post-frame：路由推入/弹出帧内对
  /// readerDepth 的通知会落在内层 Navigator 的 buildScope 里被吞掉，
  /// 外层外壳收不到重建信号（真机验证：同步自增后悬浮球不隐藏）。
  FeedbackAccess? _feedbackAccess;
  bool _readerCounted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_feedbackAccess == null) {
      final access = FeedbackAccess.maybeOf(context);
      if (access != null) {
        _feedbackAccess = access;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _readerCounted) return;
          access.readerDepth.value += 1;
          _readerCounted = true;
        });
      }
    }
  }

  @override
  void deactivate() {
    _exitCapture = _webtoonKey.currentState?.captureForClose();
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onController);
    widget.controller.start();
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      final saved = _webtoonKey.currentState?.captureForClose();
      final closing = _closeController(oldWidget.controller, saved);
      _paged?.dispose();
      _paged = null;
      final controller = widget.controller;
      controller.addListener(_onController);
      unawaited(() async {
        await closing;
        if (mounted && controller == widget.controller) {
          await controller.start();
        }
      }());
    }
  }

  @override
  void dispose() {
    if (_readerCounted) {
      _readerCounted = false;
      final access = _feedbackAccess;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        access?.readerDepth.value -= 1;
      });
    }
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    unawaited(_closeController(widget.controller,
        _exitCapture ?? _webtoonKey.currentState?.captureForClose()));
    _paged?.dispose();
    super.dispose();
  }

  Future<void> _closeController(
      ReaderController controller, Future<void>? saved) async {
    try {
      await saved;
    } finally {
      controller.dispose();
      await controller.closed;
    }
  }

  /// Background and memory pressure are the two moments the reader can act on
  /// before the OS acts for it. Pausing releases the decoded bitmaps; coming back
  /// re-describes the device, because the link may have changed while the app
  /// slept and the prefetch window has to follow it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(widget.controller.resumed());
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        final controller = widget.controller;
        final saved = _webtoonKey.currentState?.captureForClose();
        unawaited(() async {
          await saved;
          await controller.paused();
        }());
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (!mounted) return;
    unawaited(widget.controller.onMemoryPressure());
  }

  void _onController() {
    if (!mounted) return;
    setState(() {});
    // The webtoon column owns its scroll offset; paged modes use a PageView.
    if (!widget.controller.isWebtoon) {
      _paged ??= PageController(initialPage: widget.controller.spread);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: controller.background,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.45),
          foregroundColor: Colors.white,
          title: Text(
            widget.title ?? controller.book?.bookId ?? '阅读',
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '阅读设置',
              icon: const Icon(Icons.tune),
              onPressed: () => _showSettings(context, controller),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (controller.error != null)
              Positioned(
                left: 0,
                right: 0,
                top: kToolbarHeight + 8,
                child: Material(
                  color: Colors.black54,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      controller.error!,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              ),
            Center(
              child: switch ((controller.busy, controller.pageCount)) {
                (true, _) => const CircularProgressIndicator(),
                (false, 0) => const _EmptyState(),
                _ => controller.isWebtoon
                    ? _WebtoonColumn(key: _webtoonKey, controller: controller)
                    : _PagedView(
                        controller: controller,
                        pageController: _paged ??= PageController(
                          initialPage: controller.spread,
                        ),
                      ),
              },
            ),
            if (!controller.busy && controller.pageCount > 0)
              Align(
                alignment: Alignment.bottomCenter,
                child: _BottomBar(controller: controller),
              ),
            if (controller.isWaitingForPage)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '这本书没有可显示的页面',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}

/// Paged rendering: single page or double-page spread per screen.
class _PagedView extends StatelessWidget {
  const _PagedView({required this.controller, required this.pageController});

  final ReaderController controller;
  final PageController pageController;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout;
    if (layout == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (detail) => _handleTap(context, detail),
      child: PageView.builder(
        controller: pageController,
        // RTL manga reads right-to-left: the page list still runs forward, the
        // scroll direction is what mirrors. Vertical paging scrolls downward.
        scrollDirection:
            controller.isVertical ? Axis.vertical : Axis.horizontal,
        reverse: !controller.isVertical && layout.reversed,
        itemCount: controller.spreadCount,
        onPageChanged: (index) {
          final spread = controller.spreads[index];
          if (spread.isNotEmpty && spread.first != controller.page) {
            controller.turnTo(spread.first);
          }
        },
        itemBuilder: (context, index) {
          final spread = controller.spreads[index];
          final ordered = layout.reversed ? spread.reversed.toList() : spread;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: controller.isVertical ? 0 : controller.pageGap / 2,
              vertical: controller.isVertical ? controller.pageGap / 2 : 0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final page in ordered)
                  Expanded(
                    child: _PageImage(controller: controller, page: page),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The tap halves come from the contract (`tapNext` / `tapPrev`), so a
  /// right-to-left book advances by tapping the left half of the screen.
  void _handleTap(BuildContext context, TapUpDetails detail) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final local = detail.localPosition;
    final layout = controller.layout!;
    final advance = switch (layout.tapNext) {
      'left' => local.dx < size.width / 2,
      'right' => local.dx > size.width / 2,
      'top' => local.dy < size.height / 2,
      _ => local.dy > size.height / 2,
    };
    final retreat = switch (layout.tapPrev) {
      'left' => local.dx < size.width / 2,
      'right' => local.dx > size.width / 2,
      'top' => local.dy < size.height / 2,
      _ => local.dy > size.height / 2,
    };
    if (advance) {
      controller.next();
    } else if (retreat && !(advance)) {
      controller.previous();
    }
  }
}

/// 条漫: one long vertical column, virtualized so a 500-page webtoon keeps a
/// bounded number of decoded images alive. Tracks visible pages and syncs bi-directionally
/// with the controller and slider.
class _WebtoonColumn extends StatefulWidget {
  const _WebtoonColumn({super.key, required this.controller});

  final ReaderController controller;

  @override
  State<_WebtoonColumn> createState() => _WebtoonColumnState();
}

class _WebtoonColumnState extends State<_WebtoonColumn>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _pageKeys = {};
  final Map<int, double> _pageHeights = {};
  final Set<int> _readyPages = {};
  Timer? _debounceTimer;
  ({int? page, double? ratio})? _latestViewport;
  Timer? _restoreDeadline;
  int _restoreGeneration = 0;
  int _imageAttempt = 0;
  int? _restorePage;
  double? _restoreRatio;
  String? _restoreFailure;
  bool _advanceScheduled = false;
  bool _restoring = false;
  Object? _lastSeek;
  int _stalled = 0;
  int _lastKnownPage = 1;
  double? _lastKnownRatio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_handleControllerChanged);
    _openPosition();
  }

  void _openPosition() {
    _lastKnownPage = widget.controller.page;
    _lastKnownRatio = widget.controller.startPageOffsetRatio;
    if (_lastKnownPage > 1 || _lastKnownRatio != null) {
      _restoreToPage(_lastKnownPage, _lastKnownRatio);
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    // This notification precedes the new layout; retain image-relative position.
    final measured = _restoring ? null : _measureViewport();
    _restoreToPage(
        _restorePage ?? measured?.page ?? _lastKnownPage,
        _restoring
            ? _restoreRatio
            : measured?.page != null
                ? measured!.ratio
                : _lastKnownRatio);
  }

  @override
  void didUpdateWidget(covariant _WebtoonColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cancelRestore();
      _debounceTimer?.cancel();
      _latestViewport = null;
      _readyPages.clear();
      _pageHeights.clear();
      _pageKeys.clear();
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _openPosition();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _cancelRestore();
    unawaited(widget.controller.flushPageOffset());
    widget.controller.removeListener(_handleControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    final page = widget.controller.page;
    if (page != _lastKnownPage) {
      _lastKnownPage = page;
      _lastKnownRatio = null;
      _restoreToPage(page, null);
    }
  }

  RenderBox? _box(int page) {
    final render = _pageKeys[page]?.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize ? render : null;
  }

  void _restoreToPage(int page, double? ratio) {
    _cancelRestore();
    _restorePage = page;
    _restoreRatio = ratio;
    _restoring = true;
    _restoreFailure = null;
    _lastSeek = null;
    _stalled = 0;
    _debounceTimer?.cancel();
    _latestViewport = null;
    final generation = _restoreGeneration;
    _restoreDeadline = Timer(const Duration(seconds: 30), () {
      if (mounted && generation == _restoreGeneration && _restoring) {
        _failRestore('图片尚未就绪，未能恢复阅读位置');
      }
    });
    _scheduleAdvance();
  }

  void _scheduleAdvance() {
    if (!mounted || !_restoring || _advanceScheduled) return;
    _advanceScheduled = true;
    final generation = _restoreGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _restoreGeneration) return;
      _advanceScheduled = false;
      _advanceRestore();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _advanceRestore() {
    if (!_restoring || !_scrollController.hasClients) return;
    final page = _restorePage!;
    final viewport = context.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final box = _box(page);
    final position = _scrollController.position;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    if (box != null) {
      // A spinner has a size too. Only a decoded image supplies valid geometry.
      if (!_readyPages.contains(page) || box.size.height <= 0) return;
      _pageHeights[page] = box.size.height;
      final desired = position.pixels +
          box.localToGlobal(Offset.zero).dy -
          viewportTop +
          (_restoreRatio ?? 0) * box.size.height;
      final target = desired.clamp(0.0, position.maxScrollExtent).toDouble();
      if ((target - position.pixels).abs() <= 1) {
        _finishRestore();
        return;
      }
      _seek(target);
      return;
    }

    // Locate an unmounted page using the current laid-out children, not the
    // original estimate. Every correction re-measures after a real layout.
    final mountedPages = _pageKeys.keys.where((p) => _box(p) != null).toList()
      ..sort();
    if (mountedPages.isEmpty) {
      _scheduleAdvance();
      return;
    }
    if (mountedPages.any((p) => !_readyPages.contains(p))) return;
    final anchor = mountedPages
        .reduce((a, b) => (a - page).abs() < (b - page).abs() ? a : b);
    final anchorBox = _box(anchor)!;
    final decodedHeights = mountedPages
        .where(_readyPages.contains)
        .map((p) => _box(p)!.size.height)
        .toList();
    final average = decodedHeights.isEmpty
        ? viewport.size.height
        : decodedHeights.reduce((a, b) => a + b) / decodedHeights.length;
    final target = position.pixels +
        anchorBox.localToGlobal(Offset.zero).dy -
        viewportTop +
        (page - anchor) * (average + widget.controller.pageGap);
    _seek(target.clamp(0.0, position.maxScrollExtent).toDouble());
  }

  void _seek(double target) {
    final signature = (
      target,
      _scrollController.position.maxScrollExtent,
      _pageKeys.keys.where((p) => _box(p) != null).join(','),
      _readyPages.length
    );
    _stalled = signature == _lastSeek ? _stalled + 1 : 0;
    _lastSeek = signature;
    if (_stalled >= 3) {
      // Pending images can still alter the list extent: let their completion
      // wake us, with the overall deadline as the bounded failure path.
      final pendingImages = _pageKeys.keys
          .any((p) => _box(p) != null && !_readyPages.contains(p));
      if (!pendingImages) _failRestore('无法定位到上次阅读位置');
      return;
    }
    _scrollController.jumpTo(target);
    _scheduleAdvance();
  }

  void _finishRestore() {
    final measured = _measureViewport();
    if (measured.page == null) {
      _failRestore('无法确认阅读位置');
      return;
    }
    _cancelRestore();
    _latestViewport = measured;
    _lastKnownPage = measured.page!;
    _lastKnownRatio = measured.ratio;
    _pageKeys.removeWhere((page, key) =>
        (page - _lastKnownPage).abs() > 20 && key.currentContext == null);
    unawaited(_saveMeasured(measured));
  }

  Future<void> _saveMeasured(({int? page, double? ratio}) measured) async {
    final controller = widget.controller;
    final generation = _restoreGeneration;
    if (measured.page != controller.page) {
      await controller.turnTo(measured.page!);
    }
    if (!mounted ||
        controller != widget.controller ||
        generation != _restoreGeneration) {
      return;
    }
    await controller.reportPageOffset(measured.ratio);
  }

  void _cancelRestore() {
    _restoreDeadline?.cancel();
    _restoreGeneration++;
    _advanceScheduled = false;
    _restoring = false;
    _restorePage = null;
    _restoreRatio = null;
    _restoreFailure = null;
  }

  void _failRestore(String message) {
    _restoreDeadline?.cancel();
    _restoreGeneration++;
    _advanceScheduled = false;
    setState(() {
      _restoring = false;
      _restoreFailure = message;
    });
    // Keep the requested position and suppress writes until retry or user scroll.
  }

  void _retryRestore() {
    final page = _restorePage!;
    final ratio = _restoreRatio;
    setState(() {
      _imageAttempt++;
      _readyPages.clear();
      _restoreToPage(page, ratio);
    });
  }

  void _onImageReady(int page, ReaderController controller) {
    if (!mounted || controller != widget.controller) return;
    _readyPages.add(page);
    final box = _box(page);
    if (box != null) _pageHeights[page] = box.size.height;
    _scheduleAdvance();
  }

  void _onImageFailed(int page, ReaderController controller) {
    if (!mounted || controller != widget.controller) return;
    _readyPages.remove(page);
    if (_restoring && page == _restorePage) _failRestore('图片加载失败，未能恢复阅读位置');
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final userScroll = notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
    if (userScroll && (_restoring || _restoreFailure != null)) {
      setState(_cancelRestore);
    }
    if (_restoring || _restoreFailure != null) return false;
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _latestViewport = _measureViewport();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_restoring && _restoreFailure == null) {
          _latestViewport = _measureViewport();
        }
      });
      _debounceTimer?.cancel();
      _debounceTimer =
          Timer(const Duration(milliseconds: 80), _updateVisiblePage);
    }
    return false;
  }

  ({int? page, double? ratio}) _measureViewport() {
    final viewport = context.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return (page: null, ratio: null);
    final pages = <({int page, double top, double height})>[];
    for (final page in _pageKeys.keys) {
      final box = _box(page);
      if (box == null || !_readyPages.contains(page) || box.size.height <= 0) {
        continue;
      }
      pages.add((
        page: page,
        top: box.localToGlobal(Offset.zero).dy,
        height: box.size.height
      ));
    }
    pages.sort((a, b) => a.top.compareTo(b.top));
    return ReaderOffsetGeometry.measure(
        viewportTop: viewport.localToGlobal(Offset.zero).dy, pages: pages);
  }

  // Capture synchronously before teardown; saving may finish after unmount.
  Future<void> captureForClose() async {
    _debounceTimer?.cancel();
    final measured = _latestViewport;
    final controller = widget.controller;
    if (!_restoring && _restoreFailure == null && measured?.page != null) {
      if (controller.page != measured!.page) {
        await controller.turnTo(measured.page!);
      }
      await controller.reportPageOffset(measured.ratio);
    }
    await controller.flushPageOffset();
  }

  void _updateVisiblePage() {
    if (!mounted || _restoring || _restoreFailure != null) return;
    final measured = _measureViewport();
    if (measured.page == null) return;
    _latestViewport = measured;
    _lastKnownPage = measured.page!;
    _lastKnownRatio = measured.ratio;
    _pageKeys.removeWhere((page, key) =>
        (page - _lastKnownPage).abs() > 20 && key.currentContext == null);
    unawaited(_saveMeasured(measured));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final pages = [for (final spread in controller.rawSpreads) ...spread];
    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: ListView.builder(
          key: const ValueKey('webtoon-scroll'),
          controller: _scrollController,
          itemCount: pages.length,
          itemBuilder: (context, index) {
            final page = pages[index];
            final key = _pageKeys.putIfAbsent(page, () => GlobalKey());
            return Column(children: [
              KeyedSubtree(
                  key: key,
                  child: _PageImage(
                    key: ValueKey((controller, page, _imageAttempt)),
                    controller: controller,
                    page: page,
                    fit: BoxFit.fitWidth,
                    placeholderHeight:
                        _pageHeights[page] ?? MediaQuery.sizeOf(context).height,
                    onReady: () => _onImageReady(page, controller),
                    onFailed: () => _onImageFailed(page, controller),
                    onDisposed: () {
                      if (controller == widget.controller) {
                        _readyPages.remove(page);
                      }
                    },
                  )),
              SizedBox(height: controller.pageGap),
            ]);
          },
        ),
      ),
      if (_restoreFailure != null)
        Positioned(
            top: kToolbarHeight + 12,
            left: 12,
            right: 12,
            child: Material(
                color: Colors.black87,
                child: Column(children: [
                  Text(_restoreFailure!,
                      style: const TextStyle(color: Colors.white)),
                  TextButton(
                      onPressed: _retryRestore, child: const Text('重试恢复位置')),
                ]))),
    ]);
  }
}

class _PageImage extends StatefulWidget {
  const _PageImage(
      {super.key,
      required this.controller,
      required this.page,
      this.fit,
      this.onReady,
      this.onFailed,
      this.onDisposed,
      this.placeholderHeight});

  final ReaderController controller;
  final int page;
  final BoxFit? fit;
  final VoidCallback? onReady;
  final VoidCallback? onFailed;
  final VoidCallback? onDisposed;
  final double? placeholderHeight;

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  late Future<String?> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.controller.imageFor(widget.page);
  }

  @override
  void didUpdateWidget(covariant _PageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.page != widget.page) {
      _image = widget.controller.imageFor(widget.page);
      _failed = false;
      _readyNotified = false;
    }
  }

  void _retryImage() {
    setState(() {
      _failed = false;
      _readyNotified = false;
      _image = widget.controller.imageFor(widget.page);
    });
  }

  String? _notifiedPath;
  int? _notifiedWidth;
  bool _failed = false;
  bool _readyNotified = false;

  @override
  void dispose() {
    widget.onDisposed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: _image,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            if (snapshot.connectionState == ConnectionState.done && !_failed) {
              _failed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onFailed?.call();
              });
            }
            return SizedBox(
                height: widget.placeholderHeight,
                child: Center(
                  child: snapshot.connectionState == ConnectionState.done
                      ? TextButton.icon(
                          onPressed: _retryImage,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试图片'))
                      : const CircularProgressIndicator(strokeWidth: 2),
                ));
          }
          final path = snapshot.data!;
          final decodeWidth = (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round();
          if (_notifiedPath != path || _notifiedWidth != decodeWidth) {
            _notifiedPath = path;
            _notifiedWidth = decodeWidth;
            _failed = false;
            _readyNotified = false;
          }
          // Image.file with cacheWidth: the core hands over a file, and Flutter
          // decodes it at the width it will actually draw at. A 4K page decoded
          // at full size is the surest way to drop frames on a fast flip.
          return InteractiveViewer(
            maxScale: 4,
            child: Image.file(
              File(path),
              fit: widget.fit ?? BoxFit.contain,
              cacheWidth: decodeWidth,
              frameBuilder: (context, child, frame, wasSync) {
                if ((frame != null || wasSync) && !_readyNotified) {
                  _readyNotified = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_failed) widget.onReady?.call();
                  });
                }
                return child;
              },
              errorBuilder: (_, __, ___) {
                if (!_failed) {
                  _failed = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) widget.onFailed?.call();
                  });
                }
                return const Center(
                  child:
                      Icon(Icons.broken_image_outlined, color: Colors.white38),
                );
              },
            ),
          );
        },
      );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout;
    return SafeArea(
      child: Container(
        height: 56,
        color: Colors.black.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                onPressed: controller.previous,
                icon: Icon(
                  controller.isVertical
                      ? Icons.keyboard_arrow_up
                      : (layout?.reversed ?? false)
                          ? Icons.arrow_forward
                          : Icons.arrow_back,
                  color: Colors.white,
                ),
                tooltip: '上一页',
              ),
              Expanded(
                child: Slider(
                  value:
                      controller.page.clamp(1, controller.pageCount).toDouble(),
                  max: controller.pageCount.toDouble(),
                  divisions: controller.pageCount > 1
                      ? controller.pageCount - 1
                      : null,
                  label: '${controller.page}/${controller.pageCount}',
                  onChanged: (value) => controller.turnTo(value.round()),
                ),
              ),
              Text(
                '${controller.page} / ${controller.pageCount}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              IconButton(
                onPressed: controller.next,
                icon: Icon(
                  controller.isVertical
                      ? Icons.keyboard_arrow_down
                      : (layout?.reversed ?? false)
                          ? Icons.arrow_back
                          : Icons.arrow_forward,
                  color: Colors.white,
                ),
                tooltip: '下一页',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showSettings(BuildContext context, ReaderController controller) {
  final feedback = FeedbackAccess.maybeOf(context)?.controller;
  late final Future<void> sheetClosed;
  sheetClosed = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('阅读模式',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'single': '单页',
                    'double': '双页',
                    'webtoon': '条漫',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.mode == entry.key,
                      onSelected: (_) => controller.setMode(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('阅读方向',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'ltr': '左→右',
                    'rtl': '右→左',
                    'vertical': '纵向',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.direction == entry.key,
                      onSelected: (_) => controller.setDirection(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('背景',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'black': '黑',
                    'gray': '灰',
                    'white': '白',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.backgroundName == entry.key,
                      onSelected: (_) => controller.setBackground(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _GapTile(controller: controller),
              _BrightnessTile(controller: controller),
              SwitchListTile(
                value: controller.settings?.keepScreenAwake ?? true,
                onChanged: controller.setKeepScreenAwake,
                title:
                    const Text('屏幕常亮', style: TextStyle(color: Colors.white)),
              ),
              SwitchListTile(
                value: controller.settings?.restorePosition ?? true,
                onChanged: controller.setRestorePosition,
                title:
                    const Text('阅读位置恢复', style: TextStyle(color: Colors.white)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.markUnread,
                      icon: const Icon(Icons.mark_email_unread_outlined),
                      label: const Text('标为未读'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.markRead,
                      icon: const Icon(Icons.mark_email_read_outlined),
                      label: const Text('标为已读'),
                    ),
                  ),
                ],
              ),
              if (feedback != null) ...[
                const Divider(color: Colors.white24, height: 24),
                ListTile(
                  leading: const Icon(Icons.feedback_outlined,
                      color: Colors.white70),
                  title: const Text('反馈当前页面',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('截取当前阅读页并附脱敏诊断日志',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () {
                    Navigator.of(context).pop();
                    // 等底部页收起动画结束再截，不把菜单本身截进反馈图。
                    unawaited(sheetClosed.then((_) async {
                      await WidgetsBinding.instance.endOfFrame;
                      await feedback.captureAndOpen();
                    }));
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  return sheetClosed;
}

class _GapTile extends StatelessWidget {
  const _GapTile({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Slider(
        value: (controller.settings?.pageGap.toInt() ?? 8).toDouble(),
        max: 64,
        divisions: 16,
        label: '页间距 ${controller.settings?.pageGap.toInt() ?? 8}',
        onChanged: (value) => controller.setPageGap(value.round()),
      ),
    );
  }
}

class _BrightnessTile extends StatelessWidget {
  const _BrightnessTile({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Slider(
        value: controller.brightness,
        min: 0.05,
        max: 1,
        label: '亮度 ${(controller.brightness * 100).round()}%',
        onChanged: controller.setBrightness,
      ),
    );
  }
}
