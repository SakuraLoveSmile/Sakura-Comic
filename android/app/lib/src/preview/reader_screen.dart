import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components.dart';
import 'models.dart';
import 'preview_data.dart';
import 'theme.dart';

/// The reader: paging, zoom, toolbars, mode/direction, and the end-of-book
/// next-volume panel.
///
/// The three things the milestone cares about are visible here on purpose:
///   * a single tap in the middle shows and hides the toolbars and never turns
///     a page, while taps on the left/right thirds do turn one;
///   * double-tap zooms to the tap point and restoring the full page returns
///     paging to the parent;
///   * the end of a book offers the next volume as a discoverable entry and
///     never jumps to it by itself.
class PreviewReaderScreen extends StatefulWidget {
  const PreviewReaderScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.onExit,
    required this.onOpenNext,
    this.onModeChanged,
  });

  final PreviewReaderSession session;
  final PreviewGlobalSettings settings;

  /// Closing the reader: the prototype returns to wherever it was opened from.
  final void Function(PreviewReaderSession session) onExit;

  /// Opening the next volume. The session that produced this call is already
  /// closed (the prototype models the real ordering: save, close, then open).
  final void Function(PreviewReaderSession next) onOpenNext;

  final void Function(PreviewReaderSession session)? onModeChanged;

  @override
  State<PreviewReaderScreen> createState() => _PreviewReaderScreenState();
}

class _PreviewReaderScreenState extends State<PreviewReaderScreen> {
  late final PreviewReaderSession _session = widget.session;
  late PageController _pageController =
      PageController(initialPage: _state.groupIndex);
  final ScrollController _webtoonController = ScrollController();
  final TransformationController _zoomController = TransformationController();

  late final ReaderViewState _state = ReaderViewState(
    mode: _session.mode,
    direction: _session.direction,
    initialPage: _session.initialPage,
  );

  bool _toolbarsVisible = false;
  bool _settingsPanelOpen = false;
  bool _nextPanelOpen = false;
  bool _cropToWidth = false;
  bool _nextChosen = false;

  /// Pages whose images will report as failed, so the page-level failure UI is
  /// reachable in the prototype without a network.
  final Set<int> _failedPages = {};

  /// The printed page number range as it is rendered (1-based, inclusive).
  int get _firstPrintedPage => _session.mode == 'double'
      ? (_state.currentPage.isOdd ? _state.currentPage : _state.currentPage - 1)
      : _state.currentPage;

  int get _lastPrintedPage => _session.mode == 'double'
      ? (_firstPrintedPage + 1).clamp(1, _session.book.pages)
      : _state.currentPage;

  bool get _atEnd => _session.mode == 'double'
      ? _lastPrintedPage >= _session.book.pages
      : _state.currentPage >= _session.book.pages;

  @override
  void dispose() {
    _pageController.dispose();
    _webtoonController.dispose();
    _zoomController.dispose();
    super.dispose();
  }

  // MARK: navigation

  void _goToPage(int page, {bool fromUser = true}) {
    final clamped = page.clamp(1, _session.book.pages);
    if (clamped == _state.currentPage) return;
    setState(() {
      _state.currentPage = clamped;
      _state.resetZoom();
      _zoomController.value = Matrix4.identity();
      _nextChosen = false;
      // A page change always collapses the end panel: leaving it up while the
      // user pages backwards reads as a stuck overlay.
      _nextPanelOpen = false;
    });
    _syncControllers(fromUser: fromUser);
  }

  void _syncControllers({required bool fromUser}) {
    if (!_pageController.hasClients) return;
    final target = _state.groupIndex;
    if (_pageController.page?.round() != target) {
      _pageController.jumpToPage(target);
    }
  }

  void _advance() {
    if (_atEnd) {
      if (_session.mode == 'webtoon') return;
      _openNextPanel(bySwipe: true);
      return;
    }
    _goToPage(_session.mode == 'double'
        ? _firstPrintedPage + 2
        : _state.currentPage + 1);
  }

  void _retreat() {
    _goToPage(_session.mode == 'double'
        ? _firstPrintedPage - 2
        : _state.currentPage - 1);
  }

  // MARK: gestures

  bool get _zoomPanActive => _state.isZoomed;

  void _onTapUp(TapUpDetails details, double width) {
    final x = details.localPosition.dx;
    // The middle band is the toolbar toggle; the outer quarters page. The
    // milestone's rule is that the centre tap never also turns a page.
    if (x > width * 0.28 && x < width * 0.72) {
      setState(() => _toolbarsVisible = !_toolbarsVisible);
      return;
    }
    if (_zoomPanActive) return;
    final forwardSide =
        _session.direction == 'rtl' ? x < width / 2 : x > width / 2;
    if (forwardSide) {
      _advance();
    } else {
      _retreat();
    }
  }

  void _onDoubleTap(TapDownDetails details) {
    if (_state.isZoomed) {
      setState(() {
        _state.resetZoom();
        _zoomController.value = Matrix4.identity();
      });
      return;
    }
    final position = details.localPosition;
    const scale = 2.0;
    // Scale about the tapped point: translate inward by the focal point's own
    // growth, then scale. Built as a product rather than as a cascade, because
    // the order of the two is the whole point.
    final zoomed = Matrix4.identity()
      ..translateByDouble(
          -position.dx * (scale - 1), -position.dy * (scale - 1), 0, 1);
    setState(() {
      _state.scale = scale;
      _zoomController.value = zoomed.scaledByDouble(scale, scale, 1, 1);
    });
  }

  // MARK: panels and toolbar

  void _showModePanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ReaderSettingsPanel(
        session: _session,
        settings: widget.settings,
        cropToWidth: _cropToWidth,
        onModeChanged: (mode) {
          setState(() {
            _session.mode = mode;
            _state.mode = mode;
            _state.resetZoom();
            _zoomController.value = Matrix4.identity();
            _session.seriesOverride = mode != widget.settings.mode ||
                _session.direction != widget.settings.direction;
          });
          _rebuildPageController();
          widget.onModeChanged?.call(_session);
        },
        onDirectionChanged: (direction) {
          setState(() {
            _session.direction = direction;
            _state.direction = direction;
            _session.seriesOverride = direction != widget.settings.direction ||
                _session.mode != widget.settings.mode;
          });
          _rebuildPageController();
          widget.onModeChanged?.call(_session);
        },
        onResetToGlobal: () {
          setState(() {
            _session.mode = widget.settings.mode;
            _session.direction = widget.settings.direction;
            _state.mode = widget.settings.mode;
            _state.direction = widget.settings.direction;
            _session.seriesOverride = false;
            _state.resetZoom();
            _zoomController.value = Matrix4.identity();
          });
          _rebuildPageController();
          widget.onModeChanged?.call(_session);
        },
        onCropChanged: (value) => setState(() => _cropToWidth = value),
      ),
    );
  }

  /// Mode and direction changes move the page group, so the controller has to be
  /// rebuilt around the *current* page rather than kept: a stale group index is
  /// how a reader lands on the wrong spread after switching modes.
  void _rebuildPageController() {
    _pageController.dispose();
    _pageController = PageController(initialPage: _state.groupIndex);
    setState(() {});
  }

  void _openNextPanel({bool bySwipe = false}) {
    if (_hasNext == null) {
      setState(() => _toolbarsVisible = true);
      _snack(_seriesEnded ? '已到系列末尾' : '本地目录尚未完整同步，无法确定下一册');
      return;
    }
    setState(() {
      _nextPanelOpen = true;
      _toolbarsVisible = bySwipe ? _toolbarsVisible : true;
    });
  }

  bool get _seriesEnded => _session.series.isProvenLast(_session.book);

  PreviewBook? get _hasNext =>
      _nextChosen ? null : _session.series.nextAfter(_session.book);

  void _openNext() {
    final next = _session.series.nextAfter(_session.book);
    if (next == null) return;
    // Real ordering, in the prototype too: the current session is closed (its
    // position committed) before the next one is created. The screen is then
    // replaced rather than mutated, so a stale page group cannot survive into
    // the next volume.
    final messenger = ScaffoldMessenger.of(context);
    final closed = _session;
    final opened = PreviewReaderSession(
      series: _session.series,
      book: next,
      initialPage: 1,
      mode: _session.mode,
      direction: _session.direction,
      globalMode: widget.settings.mode,
      globalDirection: widget.settings.direction,
      seriesOverride: _session.seriesOverride,
    );
    widget.onOpenNext(opened);
    messenger.showSnackBar(
      SnackBar(content: Text('已保存 ${closed.book.title} 的位置，打开 ${next.title}')),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // MARK: volume keys

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.settings.volumeKeysEnabled) return KeyEventResult.ignored;
    if (_settingsPanelOpen || _nextPanelOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) {
      // KeyRepeatEvent lands here: one press is one page, and a held rocker is
      // not a page-flip machine.
      return event is KeyRepeatEvent
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _advance();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _retreat();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // MARK: build

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor:
            ComicTokens.pageBackground(widget.settings.pageBackground),
        body: Stack(
          children: [
            Positioned.fill(child: _viewer()),
            if (_toolbarsVisible) ...[
              Positioned(top: 0, left: 0, right: 0, child: _topToolbar()),
              Positioned(bottom: 0, left: 0, right: 0, child: _bottomToolbar()),
            ],
            if (_nextPanelOpen) Positioned.fill(child: _nextPanel()),
          ],
        ),
      ),
    );
  }

  Widget _viewer() {
    if (_session.mode == 'webtoon') {
      return _webtoonViewer();
    }
    return PageView.builder(
      controller: _pageController,
      reverse: _session.direction == 'rtl',
      physics: _zoomPanActive
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _groupCount,
      onPageChanged: (index) {
        setState(() {
          _state.currentPage =
              _session.mode == 'double' ? index * 2 + 1 : index + 1;
          _state.resetZoom();
          _zoomController.value = Matrix4.identity();
          _nextChosen = false;
        });
      },
      itemBuilder: (context, index) => _pageGroup(index),
    );
  }

  int get _groupCount => _session.mode == 'double'
      ? (_session.book.pages + 1) ~/ 2
      : _session.book.pages;

  Widget _pageGroup(int index) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final pages = _session.mode == 'double'
            ? [_firstPrintedPage, _lastPrintedPage]
            : [_state.currentPage];
        final spread = Row(
          children: [
            for (final page in pages)
              Expanded(child: _singlePage(page, constraints.maxHeight)),
          ],
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onTapUp(details, width),
          onDoubleTapDown: _onDoubleTap,
          onDoubleTap: () {},
          onHorizontalDragUpdate: _zoomPanActive
              ? null
              : (details) {
                  // Left-to-right mode: a leftward swipe moves forward.
                  if (details.delta.dx < -6) {
                    _advance();
                  } else if (details.delta.dx > 6) {
                    _retreat();
                  }
                },
          child: InteractiveViewer(
            transformationController: _zoomController,
            minScale: 1,
            maxScale: 4,
            panEnabled: _zoomPanActive,
            scaleEnabled: true,
            clipBehavior: Clip.none,
            onInteractionUpdate: (details) {
              final scale = details.scale.clamp(1.0, 4.0);
              if ((scale - _state.scale).abs() > 0.01) {
                setState(() => _state.scale = scale);
              }
            },
            onInteractionEnd: (details) {
              if (!_state.isZoomed) {
                // Pinching back to the full page hands paging back to the
                // parent gesture immediately, without a second tap.
                setState(() {
                  _state.resetZoom();
                  _zoomController.value = Matrix4.identity();
                });
              }
            },
            child: spread,
          ),
        );
      },
    );
  }

  Widget _singlePage(int page, double height) {
    final failed = _failedPages.contains(page);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: failed
          ? _pageFailure(page)
          : _cropToWidth
              // 铺满宽度: the page fills the screen width and its top/bottom are
              // cropped. 完整显示 is the default the milestone asks for.
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: 900,
                      height: 1400 * (height / (height + 1)),
                      child: DrawnPage(
                          pageNumber: page, totalPages: _session.book.pages),
                    ),
                  ),
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: DrawnPage(
                        pageNumber: page, totalPages: _session.book.pages),
                  ),
                ),
    );
  }

  /// The page-level failure surface: one page fails, the rest of the book is
  /// still readable, and the retry is scoped to this page alone.
  Widget _pageFailure(int page) {
    return Container(
      margin: const EdgeInsets.all(ComicTokens.spaceSm),
      padding: const EdgeInsets.all(ComicTokens.spaceMd),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image_outlined,
              size: 40, color: Color(0xFFFFB74D)),
          const SizedBox(height: ComicTokens.spaceSm),
          Text(
            '第 $page 页没有加载成功',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '其他页面不受影响，可以继续往后读。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: ComicTokens.spaceMd),
          FilledButton.tonal(
            key: Key('retry-page-$page'),
            onPressed: () => setState(() => _failedPages.remove(page)),
            child: const Text('重试这一页'),
          ),
        ],
      ),
    );
  }

  Widget _webtoonViewer() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          final metrics = notification.metrics;
          // The anchor is the viewport top: page = which laid-out page it is on,
          // and the ratio is how far into that page it sits. This is the same
          // shape the milestone stores in `page_offset_ratio`, minus the
          // persistence — the prototype only has to show the behaviour.
          final pageHeight = MediaQuery.sizeOf(context).width * 1.42 + 6;
          final rawIndex = (metrics.pixels / pageHeight).floor();
          final clamped = (rawIndex + 1).clamp(1, _session.book.pages);
          final ratio =
              ((metrics.pixels % pageHeight) / pageHeight).clamp(0.0, 1.0);
          if (clamped != _state.currentPage) {
            setState(() => _state.currentPage = clamped);
          }
          _session.pageOffsetRatio = ratio;
          if (metrics.extentAfter < 8 && !_nextChosen) {
            setState(() => _nextPanelOpen = true);
          }
        }
        return false;
      },
      child: ListView.builder(
        controller: _webtoonController,
        physics: _zoomPanActive
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        itemCount: _session.book.pages,
        itemBuilder: (context, index) {
          final page = index + 1;
          return GestureDetector(
            onTapUp: (details) {
              setState(() => _toolbarsVisible = !_toolbarsVisible);
            },
            onDoubleTapDown: _onDoubleTap,
            onDoubleTap: () {},
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _failedPages.contains(page)
                  ? SizedBox(
                      height: 420,
                      child: _pageFailure(page),
                    )
                  : SizedBox(
                      height: MediaQuery.sizeOf(context).width * 1.42,
                      child: _cropToWidth
                          ? DrawnPage(
                              pageNumber: page, totalPages: _session.book.pages)
                          : FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: MediaQuery.sizeOf(context).width,
                                height: MediaQuery.sizeOf(context).width * 1.42,
                                child: DrawnPage(
                                  pageNumber: page,
                                  totalPages: _session.book.pages,
                                ),
                              ),
                            ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _topToolbar() {
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Row(
        children: [
          IconButton(
            key: const Key('reader-back'),
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              // Back order: panels first, then zoom, then leave.
              if (_nextPanelOpen) {
                setState(() => _nextPanelOpen = false);
                return;
              }
              if (_settingsPanelOpen) {
                setState(() => _settingsPanelOpen = false);
                return;
              }
              if (_state.isZoomed) {
                setState(() {
                  _state.resetZoom();
                  _zoomController.value = Matrix4.identity();
                });
                return;
              }
              widget.onExit(_session);
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _session.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${_session.series.name} · 第 $_firstPrintedPage'
                  '${_lastPrintedPage != _firstPrintedPage ? '–$_lastPrintedPage' : ''} 页'
                  ' · ${readModeLabel(_session.mode)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '标为已读',
            icon: const Icon(Icons.done_all, color: Colors.white),
            onPressed: () => _snack('已标记为已读'),
          ),
          IconButton(
            key: const Key('reader-settings'),
            tooltip: '阅读设置',
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: _showModePanel,
          ),
        ],
      ),
    );
  }

  Widget _bottomToolbar() {
    final total = _session.book.pages;
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: ComicTokens.spaceSm),
              Expanded(
                child: Slider(
                  value:
                      _state.currentPage.toDouble().clamp(1, total.toDouble()),
                  min: 1,
                  max: total.toDouble(),
                  divisions: total > 1 ? total - 1 : null,
                  label: '${_state.currentPage}',
                  onChanged: (value) {
                    final page = value.round();
                    if (_session.mode == 'double') {
                      _goToPage(page.isOdd ? page : page - 1);
                    } else {
                      _goToPage(page);
                    }
                  },
                ),
              ),
              Text(
                '${_state.currentPage} / $total',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: ComicTokens.spaceSm),
            ],
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _showModePanel,
                icon: const Icon(Icons.view_agenda_outlined, size: 18),
                label: Text(
                    '${readModeLabel(_session.mode)} · ${directionLabel(_session.direction)}'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '上一页',
                icon: const Icon(Icons.chevron_left, color: Colors.white),
                onPressed: _retreat,
              ),
              IconButton(
                tooltip: '下一页',
                icon: const Icon(Icons.chevron_right, color: Colors.white),
                onPressed: _advance,
              ),
              IconButton(
                key: const Key('reader-next-volume'),
                tooltip: '下一册',
                icon: const Icon(Icons.menu_book_outlined, color: Colors.white),
                onPressed: () => _openNextPanel(),
              ),
              IconButton(
                tooltip: _failedPages.isEmpty ? '模拟本页加载失败' : '清除模拟失败',
                icon: Icon(
                  _failedPages.isEmpty
                      ? Icons.report_gmailerrorred
                      : Icons.restore,
                  color: Colors.white70,
                ),
                onPressed: () {
                  setState(() {
                    if (_failedPages.isEmpty) {
                      _failedPages.add(_state.currentPage);
                    } else {
                      _failedPages.clear();
                    }
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The end-of-book panel: a discoverable next-volume entry, not an automatic
  /// jump. It also has to be able to say "this is the end of the series" and
  /// "the local directory cannot prove there is a next one".
  Widget _nextPanel() {
    final next = _session.series.nextAfter(_session.book);
    final ended = _seriesEnded;
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      alignment: Alignment.bottomCenter,
      child: GestureDetector(
        onTap: () => setState(() => _nextPanelOpen = false),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(
            ComicTokens.spaceMd,
            ComicTokens.spaceMd,
            ComicTokens.spaceMd,
            ComicTokens.spaceLg,
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(ComicTokens.radiusSheet),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ended ? '已到系列末尾' : '下一册',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: ComicTokens.spaceXs),
              if (next != null)
                Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: AspectRatio(
                        aspectRatio: ComicTokens.coverAspectRatio,
                        child: SeriesCover(
                          series: _session.series,
                          showTitle: false,
                          borderRadius: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: ComicTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(next.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            _session.series.name,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          StatusChip(
                            label: next.downloadState == DownloadState.complete
                                ? '已下载 · 可离线阅读'
                                : '未下载 · 需要网络',
                            icon: next.downloadState == DownloadState.complete
                                ? Icons.download_done
                                : Icons.cloud_download_outlined,
                            tone: next.downloadState == DownloadState.complete
                                ? StateTone.success
                                : StateTone.neutral,
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                Text(
                  ended
                      ? '这个系列已经读完，没有下一册了。'
                      : '本地目录尚未完整同步，暂时无法确定下一册。同步后这里会显示下一册。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              const SizedBox(height: ComicTokens.spaceMd),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('reader-open-next'),
                      onPressed: next == null ? null : _openNext,
                      child: Text(next == null ? '没有下一册' : '打开下一册'),
                    ),
                  ),
                  const SizedBox(width: ComicTokens.spaceSm),
                  OutlinedButton(
                    onPressed: () => setState(() => _nextPanelOpen = false),
                    child: const Text('留在本册'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mode / direction / background / crop, edited for the *current series*.
class _ReaderSettingsPanel extends StatelessWidget {
  const _ReaderSettingsPanel({
    required this.session,
    required this.settings,
    required this.cropToWidth,
    required this.onModeChanged,
    required this.onDirectionChanged,
    required this.onResetToGlobal,
    required this.onCropChanged,
  });

  final PreviewReaderSession session;
  final PreviewGlobalSettings settings;
  final bool cropToWidth;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<String> onDirectionChanged;
  final VoidCallback onResetToGlobal;
  final ValueChanged<bool> onCropChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('阅读设置',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                StatusChip(
                  label: session.followsGlobal ? '跟随全局' : '此系列单独设置',
                  icon: session.followsGlobal
                      ? Icons.link
                      : Icons.push_pin_outlined,
                  tone: session.followsGlobal
                      ? StateTone.neutral
                      : StateTone.warning,
                ),
              ],
            ),
            const SizedBox(height: ComicTokens.spaceSm),
            Text('每页显示', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'single',
                    label: Text('单页'),
                    icon: Icon(Icons.crop_portrait)),
                ButtonSegment(
                    value: 'double',
                    label: Text('双页'),
                    icon: Icon(Icons.auto_stories)),
                ButtonSegment(
                    value: 'webtoon',
                    label: Text('条漫'),
                    icon: Icon(Icons.swap_vert)),
              ],
              selected: {session.mode},
              onSelectionChanged: (values) => onModeChanged(values.first),
            ),
            const SizedBox(height: ComicTokens.spaceSm),
            Text('翻页方向', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ltr', label: Text('左 → 右')),
                ButtonSegment(value: 'rtl', label: Text('右 → 左')),
                ButtonSegment(value: 'vertical', label: Text('上下')),
              ],
              selected: {session.direction},
              onSelectionChanged: (values) => onDirectionChanged(values.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('铺满宽度'),
              subtitle: const Text('关闭时为完整显示，不裁切页面'),
              value: cropToWidth,
              onChanged: onCropChanged,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('reader-follow-global'),
                onPressed: session.followsGlobal ? null : onResetToGlobal,
                icon: const Icon(Icons.settings_backup_restore, size: 18),
                label: Text(
                  session.followsGlobal
                      ? '当前跟随全局（${readModeLabel(settings.mode)} · ${directionLabel(settings.direction)}）'
                      : '恢复跟随全局（${readModeLabel(settings.mode)} · ${directionLabel(settings.direction)}）',
                ),
              ),
            ),
            Text(
              '阅读器里改的是这个系列；「设置」里改的是全局默认。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: ComicTokens.spaceSm),
          ],
        ),
      ),
    );
  }
}
