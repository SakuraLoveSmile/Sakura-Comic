import 'package:flutter/material.dart';

import 'downloads_screen.dart';
import 'list_screens.dart';
import 'models.dart';
import 'preview_data.dart';
import 'reader_screen.dart';
import 'series_detail_screen.dart';
import 'settings_screen.dart';
import 'shelf_screen.dart';
import 'shelf_toolbar.dart';
import 'theme.dart';

/// The prototype's shell: real-time navigation, real page state, and a small
/// review toolbar for the things a reviewer needs to *see* rather than use.
///
/// The bottom bar, the tabs and every screen here are the ones the milestone
/// ships; only the review toolbar and the scenario picker are prototype-only.
class PreviewApp extends StatefulWidget {
  const PreviewApp({super.key});

  @override
  State<PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<PreviewApp> {
  late final List<PreviewSeries> _series = previewSeries();
  late final List<PreviewDownload> _downloads = previewDownloads(_series);
  final Map<String, PreviewSeriesOverride> _overrides = {};
  final PreviewGlobalSettings _settings = PreviewGlobalSettings();

  ShelfScenario _scenario = ShelfScenario.normal;

  /// The bottom bar's index. Pages are created once and kept, so switching tabs
  /// never loses a scroll position, a search or a filter.
  int _tab = 0;

  /// Review-only: simulate a narrower device or a larger system text scale.
  double _viewportWidth = 0;
  double _textScale = 1.0;

  late final ShelfToolsState _tools = ShelfToolsState();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: MediaQuery.withClampedTextScaling(
              minScaleFactor: _textScale,
              maxScaleFactor: _textScale,
              child: _widthBox(_tabs()),
            ),
          ),
          _reviewBar(context),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: '合集',
          ),
          NavigationDestination(
            icon: Icon(Icons.playlist_play_outlined),
            selectedIcon: Icon(Icons.playlist_play),
            label: '书单',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '下载',
          ),
        ],
      ),
    );
  }

  Widget _widthBox(Widget child) {
    if (_viewportWidth <= 0) return child;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: _viewportWidth,
          child: child,
        ),
      ),
    );
  }

  Widget _tabs() {
    final selected = _scenario.hasContent ? _series : <PreviewSeries>[];
    return IndexedStack(
      index: _tab,
      children: [
        ShelfScreen(
          series: _scenario == ShelfScenario.emptyQuery ? _series : selected,
          scenario: _scenario,
          tools: _tools,
          settings: _settings,
          onChanged: () => setState(() {}),
          onOpenSeries: _openSeries,
          onContinueReading: (series, book) => _openBook(
            series,
            book,
            fromFirstPage: false,
            viaReread: false,
          ),
          onOpenSettings: _openSettings,
          onOpenServers: _openServers,
          onOpenLibraries: () => _later('媒体库管理'),
        ),
        CollectionsScreen(series: _series, onOpenSeries: _openSeries),
        ReadlistsScreen(
          series: _series,
          onOpenSeries: _openSeries,
          onOpenBook: (series, book) => _openBook(
            series,
            book,
            fromFirstPage: false,
            viaReread: false,
          ),
        ),
        PreviewDownloadsScreen(
          downloads: _downloads,
          onChanged: () => setState(() {}),
          onOpenBook: (download) => _openBook(
            _seriesFor(download.book.seriesId),
            download.book,
            fromFirstPage: false,
            viaReread: false,
          ),
          onOpenSeries: (download) =>
              _openSeries(_seriesFor(download.book.seriesId)),
        ),
      ],
    );
  }

  /// The review toolbar: scenario, simulated viewport, text scale, and a couple
  /// of jumps that would otherwise take a minute of tapping.
  Widget _reviewBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        bottom: false,
        // Scrollable, not fixed: at 2.0 text the four controls do not fit a
        // 412px screen, and a review control that overflows its own bar is a
        // worse answer than one you can scroll to.
        child: SizedBox(
          height: 44,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: ComicTokens.spaceSm),
                const Icon(Icons.science_outlined, size: 16),
                const SizedBox(width: 6),
                PopupMenuButton<ShelfScenario>(
                  key: const Key('preview-scenario'),
                  tooltip: '场景',
                  onSelected: (value) => setState(() {
                    _scenario = value;
                    _tab = 0;
                  }),
                  itemBuilder: (context) => [
                    for (final scenario in ShelfScenario.values)
                      PopupMenuItem(
                          value: scenario, child: Text('场景：${scenario.label}')),
                  ],
                  child: Text(
                    '场景：${_scenario.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(width: ComicTokens.spaceSm),
                PopupMenuButton<double>(
                  tooltip: '宽度',
                  onSelected: (value) => setState(() => _viewportWidth = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 0, child: Text('宽度：设备原始')),
                    PopupMenuItem(value: 360, child: Text('宽度：360')),
                    PopupMenuItem(value: 393, child: Text('宽度：393')),
                    PopupMenuItem(value: 412, child: Text('宽度：412')),
                  ],
                  child: Text(
                    _viewportWidth <= 0
                        ? '宽度：设备原始'
                        : '宽度：${_viewportWidth.round()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(width: ComicTokens.spaceSm),
                PopupMenuButton<double>(
                  tooltip: '文字缩放',
                  onSelected: (value) => setState(() => _textScale = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 1.0, child: Text('文字 1.0')),
                    PopupMenuItem(value: 1.3, child: Text('文字 1.3')),
                    PopupMenuItem(value: 2.0, child: Text('文字 2.0')),
                  ],
                  child: Text(
                    '文字 ${_textScale.toStringAsFixed(1)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(width: ComicTokens.spaceMd),
                TextButton(
                  onPressed: () => _openReaderFor(
                    _series.firstWhere((s) => s.seriesId == 's-aria'),
                    mode: 'single',
                  ),
                  child: const Text('阅读器'),
                ),
                TextButton(
                  onPressed: () => _openReaderFor(
                    _series.firstWhere((s) => s.seriesId == 's-aria'),
                    mode: 'webtoon',
                  ),
                  child: const Text('条漫'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // MARK: navigation

  PreviewSeries _seriesFor(String seriesId) => _series
      .firstWhere((s) => s.seriesId == seriesId, orElse: () => _series.first);

  void _openSeries(PreviewSeries series) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SeriesDetailScreen(
          series: series,
          settings: _settings,
          overrides: _overrides,
          onOpenBook: (book, {required fromFirstPage, required viaReread}) =>
              _openBook(series, book,
                  fromFirstPage: fromFirstPage, viaReread: viaReread),
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// The one reading entry point: the prototype keeps a single function that
  /// captures the identity (series + book), builds the session, and pushes the
  /// reader — the same shape the milestone requires from the production code.
  void _openBook(
    PreviewSeries series,
    PreviewBook book, {
    required bool fromFirstPage,
    required bool viaReread,
  }) {
    final mode = _overrides[series.seriesId]?.mode ?? _settings.mode;
    final direction =
        _overrides[series.seriesId]?.direction ?? _settings.direction;
    _openReaderFor(
      series,
      book: book,
      mode: mode,
      direction: direction,
      fromFirstPage: fromFirstPage,
      viaReread: viaReread,
    );
  }

  void _openReaderFor(
    PreviewSeries series, {
    PreviewBook? book,
    required String mode,
    String? direction,
    bool fromFirstPage = false,
    bool viaReread = false,
  }) {
    final target = book ?? series.primaryBook;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个系列没有可以打开的册')),
      );
      return;
    }
    final session = PreviewReaderSession(
      series: series,
      book: target,
      initialPage: fromFirstPage ? 1 : target.resumePage,
      mode: mode,
      direction: direction ?? _settings.direction,
      globalMode: _settings.mode,
      globalDirection: _settings.direction,
      seriesOverride: _overrides.containsKey(series.seriesId),
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (readerContext) => PreviewReaderScreen(
          session: session,
          settings: _settings,
          onModeChanged: (updated) {
            setState(() {
              if (updated.followsGlobal) {
                _overrides.remove(series.seriesId);
              } else {
                _overrides[series.seriesId] = PreviewSeriesOverride(
                  mode: updated.mode,
                  direction: updated.direction,
                );
              }
            });
          },
          onExit: (closed) {
            // Committing the position is the session's job; the prototype
            // records it so the shelf and detail screens move on.
            _recordPosition(series, closed);
            Navigator.of(readerContext).pop();
          },
          // Push, not replace: leaving the next volume returns to the book that
          // led here, exactly as the real reader will behave.
          onOpenNext: (next) => Navigator.of(readerContext).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (nextContext) => PreviewReaderScreen(
                session: next,
                settings: _settings,
                onExit: (closed) {
                  _recordPosition(series, closed);
                  Navigator.of(nextContext).pop();
                },
                onOpenNext: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The prototype's stand-in for "commit the anchor and refresh the cards".
  void _recordPosition(PreviewSeries series, PreviewReaderSession closed) {
    setState(() {
      final mutable =
          series.books.where((b) => b.bookId == closed.book.bookId).firstOrNull;
      if (mutable != null) {
        mutable.progressPage = closed.currentPage;
      }
    });
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PreviewSettingsScreen(
          servers: previewServers,
          settings: _settings,
          overrides: _overrides,
          onChanged: () => setState(() {}),
          onOpenServers: () => _openServers(sheetContext: context),
          onOpenDiagnostics: () => _openDiagnostics(context),
          onClearOverrides: () {
            setState(_overrides.clear);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('所有系列已恢复跟随全局')),
            );
          },
        ),
      ),
    );
  }

  void _openServers({BuildContext? sheetContext}) {
    final host = sheetContext ?? context;
    showModalBottomSheet<void>(
      context: host,
      showDragHandle: true,
      builder: (modalContext) => ServerSwitcherSheet(
        servers: previewServers,
        onPick: (server) {
          Navigator.of(modalContext).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('切换到「${server.name}」，书架会重新查询并清空旧页面状态')),
          );
        },
      ),
    );
  }

  void _openDiagnostics(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ComicTokens.spaceMd,
            0,
            ComicTokens.spaceMd,
            ComicTokens.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('诊断', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: ComicTokens.spaceSm),
              const _DiagRow(label: '同步状态', value: '已完成 · 5 分钟前'),
              const _DiagRow(label: '本地系列', value: '12'),
              const _DiagRow(label: '本地册数', value: '148'),
              const _DiagRow(label: '待上传进度', value: '3'),
              const _DiagRow(label: '阅读缓存', value: '812 MiB / 512 MiB 上限'),
              const _DiagRow(label: '数据库', value: 'schema v9 · 完整'),
              const SizedBox(height: ComicTokens.spaceSm),
              Text(
                '真实版本会显示当前 schema 版本、最近同步错误和待上传队列；原型不读真实数据库。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _later(String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('原型中「$action」只做占位')),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child:
                  Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
