import 'package:flutter/material.dart';

import 'components.dart';
import 'models.dart';
import 'preview_data.dart';
import 'shelf_toolbar.dart';
import 'theme.dart';

/// The shelf: continue-reading rail, tool area, and the cover grid.
///
/// Every scenario the milestone names renders here — including the four that are
/// not about content (no server, sync in flight, empty query, failed load,
/// expired credential) — because "how does the shelf look when something is
/// wrong" is part of the design being reviewed, not an afterthought.
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({
    super.key,
    required this.series,
    required this.scenario,
    required this.tools,
    required this.settings,
    required this.onChanged,
    required this.onOpenSeries,
    required this.onContinueReading,
    required this.onOpenSettings,
    required this.onOpenServers,
    required this.onOpenLibraries,
  });

  final List<PreviewSeries> series;
  final ShelfScenario scenario;
  final ShelfToolsState tools;
  final PreviewGlobalSettings settings;
  final VoidCallback onChanged;
  final void Function(PreviewSeries series) onOpenSeries;
  final void Function(PreviewSeries series, PreviewBook book) onContinueReading;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenLibraries;

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scenario = widget.scenario;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: ComicTokens.spaceMd,
        title: InkWell(
          key: const Key('shelf-server-switch'),
          onTap: widget.onOpenServers,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('书架', style: Theme.of(context).textTheme.titleLarge),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.dns_outlined, size: 13),
                    const SizedBox(width: 4),
                    // The server name is the one part of the title that can be
                    // arbitrarily long, so it is the part that ellipsises; the
                    // row may never push the app bar wider than the screen.
                    Flexible(
                      child: Text(
                        _serverName(scenario),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                    const Icon(Icons.expand_more, size: 14),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            key: const Key('shelf-import'),
            tooltip: '导入本地文件',
            icon: const Icon(Icons.add_to_photos_outlined),
            onPressed: () => _notImplemented('导入'),
          ),
          IconButton(
            key: const Key('shelf-settings'),
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: widget.onOpenSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        },
        child: _body(context, scenario),
      ),
    );
  }

  Widget _body(BuildContext context, ShelfScenario scenario) {
    if (scenario == ShelfScenario.noServer) {
      return ListView(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 64),
        children: [
          PreviewStateView(
            icon: Icons.dns_outlined,
            headline: '还没有添加服务器',
            detail: '添加一台 Komga 服务器后，书架会从本地镜像直接显示内容；离线时也一样。',
            primaryLabel: '添加服务器',
            onPrimary: widget.onOpenServers,
            secondaryLabel: '先看看离线演示',
            onSecondary: () => _notImplemented('离线演示'),
          ),
        ],
      );
    }

    if (scenario == ShelfScenario.loadFailed) {
      return ListView(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 64),
        children: [
          PreviewStateView(
            icon: Icons.cloud_off_outlined,
            headline: '书架加载失败',
            detail: '本地数据库读取没有完成。已下载的内容没有受影响，可以重试。',
            tone: StateTone.error,
            primaryLabel: '重试',
            onPrimary: () => _notImplemented('重试'),
            secondaryLabel: '查看诊断',
            onSecondary: () => _notImplemented('诊断'),
          ),
        ],
      );
    }

    if (scenario == ShelfScenario.authExpired) {
      return ListView(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 64),
        children: [
          PreviewStateView(
            icon: Icons.key_off_outlined,
            headline: '登录已失效，需要重新输入 API Key',
            detail: '服务器拒绝了当前凭据。书架上的缓存内容和已下载的书仍然可以打开。',
            tone: StateTone.error,
            primaryLabel: '重新登录',
            onPrimary: () => _notImplemented('重新登录'),
            secondaryLabel: '先离线阅读',
            onSecondary: () => _notImplemented('离线阅读'),
          ),
        ],
      );
    }

    final visible = _visibleSeries();
    final rail = _railEntries();

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (scenario == ShelfScenario.syncing)
          SliverToBoxAdapter(
            child: PreviewBanner(
              icon: Icons.sync,
              message: '正在同步媒体库 · 已完成 ${widget.series.length} 个系列',
              tone: StateTone.warning,
              actionLabel: '查看',
              onAction: () => _notImplemented('同步详情'),
            ),
          ),
        if (scenario == ShelfScenario.offlineCached)
          SliverToBoxAdapter(
            child: PreviewBanner(
              icon: Icons.cloud_off_outlined,
              message: '离线 · 显示本地缓存内容，阅读进度会在恢复网络后上传',
              tone: StateTone.warning,
              actionLabel: '重试',
              onAction: () => _notImplemented('重试'),
            ),
          ),
        if (scenario == ShelfScenario.normal && _pendingUploads > 0)
          SliverToBoxAdapter(
            child: PreviewBanner(
              icon: Icons.cloud_upload_outlined,
              message: '$_pendingUploads 条阅读进度待上传',
              actionLabel: '查看',
              onAction: () => _notImplemented('待上传'),
            ),
          ),
        if (rail.isNotEmpty)
          SliverToBoxAdapter(
            child: _ContinueRail(
              entries: rail,
              onOpen: widget.onContinueReading,
              onOpenSeries: widget.onOpenSeries,
            ),
          ),
        SliverToBoxAdapter(
          child: ShelfToolbar(
            state: widget.tools,
            onChanged: widget.onChanged,
            tags: _tags(),
            statuses: _statuses(),
            onOpenLibraries: widget.onOpenLibraries,
          ),
        ),
        if (visible.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 48),
              child: PreviewStateView(
                icon: Icons.search_off,
                headline: '没有匹配的系列',
                detail: widget.tools.isFiltered
                    ? '当前筛选条件下没有内容。清除筛选可以看到全部系列。'
                    : '本地镜像是空的。先同步一次媒体库，书架才有内容可显示。',
                primaryLabel: widget.tools.isFiltered ? '清除筛选' : '开始同步',
                onPrimary: () {
                  widget.tools
                    ..query = ''
                    ..libraryId = null
                    ..status = null
                    ..tag = null;
                  widget.onChanged();
                },
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              ComicTokens.spaceMd,
              0,
              ComicTokens.spaceMd,
              ComicTokens.spaceLg,
            ),
            sliver: SliverGrid(
              // The tile height is measured from the card's own text at the
              // current text scale, not from a fixed aspect ratio: at 2.0 the
              // grid keeps the covers readable and gives the text the room it
              // needs instead of overflowing a tile sized for 1.0.
              gridDelegate: GridViewExtentDelegate(
                spec: ComicTokens.densitySpec(widget.settings.gridDensity),
                mainAxisExtent: seriesCardHeight(
                  context,
                  ComicTokens.densitySpec(widget.settings.gridDensity)
                      .maxCrossAxisExtent,
                  _cardLineCounts(visible),
                ),
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: visible.length,
                (context, index) => _SeriesCard(
                  series: visible[index],
                  onTap: () => widget.onOpenSeries(visible[index]),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The prototype's upload counter: it exists so the pending-uploads banner is
  /// visible at all, not to model the Outbox.
  int get _pendingUploads => 3;

  String _serverName(ShelfScenario scenario) {
    if (scenario == ShelfScenario.noServer) return '未添加服务器';
    if (scenario == ShelfScenario.offlineCached) return '家里的 Komga · 离线';
    if (scenario == ShelfScenario.authExpired) return '家里的 Komga · 凭据失效';
    return '家里的 Komga';
  }

  List<ContinueReadingEntry> _railEntries() {
    if (!widget.scenario.hasContent) return const [];
    return previewContinueReading(widget.series).take(6).toList();
  }

  List<String> _tags() {
    final tags = <String>{};
    for (final item in widget.series) {
      tags.addAll(item.genres);
    }
    return tags.take(6).toList();
  }

  List<String> _statuses() => const ['ONGOING', 'ENDED'];

  List<PreviewSeries> _visibleSeries() {
    final tools = widget.tools;
    final query = tools.query.trim().toLowerCase();
    var items = widget.series.where((item) {
      if (tools.libraryId != null && item.libraryId != tools.libraryId) {
        return false;
      }
      if (tools.status != null && item.status != tools.status) return false;
      if (tools.tag != null && !item.genres.contains(tools.tag)) return false;
      if (query.isEmpty) return true;
      return item.name.toLowerCase().contains(query) ||
          (item.summary ?? '').toLowerCase().contains(query) ||
          item.genres.any((g) => g.toLowerCase().contains(query));
    }).toList();

    int byName(PreviewSeries a, PreviewSeries b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    switch (tools.sortKey) {
      case 'booksCount':
        items.sort(
            (a, b) => (a.effectiveBooksCount).compareTo(b.effectiveBooksCount));
        break;
      case 'sortName':
      case 'dateAdded':
      case 'dateUpdated':
        items.sort(byName);
        break;
      default:
        items.sort(byName);
    }
    if (!tools.ascending) {
      items = items.reversed.toList();
    }
    return items;
  }

  void _notImplemented(String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('原型中「$action」只做占位，接入真实业务后才有行为')),
    );
  }
}

/// The compact continue-reading rail: cover, title, progress, download state.
class _ContinueRail extends StatelessWidget {
  const _ContinueRail({
    required this.entries,
    required this.onOpen,
    required this.onOpenSeries,
  });

  final List<ContinueReadingEntry> entries;
  final void Function(PreviewSeries series, PreviewBook book) onOpen;
  final void Function(PreviewSeries series) onOpenSeries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '继续阅读',
          subtitle: '最近读过的 ${entries.length} 本',
          trailing: TextButton(onPressed: () {}, child: const Text('全部')),
        ),
        // A Row inside a horizontal scroll view, sized by IntrinsicHeight:
        // the rail's height is then exactly the height of its tallest card at
        // whatever text scale the system is using, with nothing to keep in
        // sync and nothing that can be a few pixels short. (A ListView cannot
        // do this — a sliver has no intrinsic dimensions.)
        IntrinsicHeight(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < entries.length; index++) ...[
                  if (index > 0) const SizedBox(width: ComicTokens.spaceXs),
                  _ContinueCard(
                    entry: entries[index],
                    onOpen: () =>
                        onOpen(entries[index].series, entries[index].book),
                    onOpenSeries: () => onOpenSeries(entries[index].series),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: ComicTokens.spaceXs),
      ],
    );
  }
}

/// The widest line counts the grid has to fit, so one tile height serves every
/// card in the same grid.
(int, int) _cardLineCounts(List<PreviewSeries> items) {
  var nameLines = 1;
  var detailLines = 1;
  for (final item in items) {
    if (item.name.length > 10) nameLines = 2;
    if (item.downloadSummary.label != null) detailLines = 2;
  }
  return (nameLines, detailLines);
}

/// One series card: cover, title, read counter, download summary.
class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.series, required this.onTap});

  final PreviewSeries series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = series.downloadSummary;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: Key('series-${series.seriesId}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: ComicTokens.coverAspectRatio,
            child: SeriesCover(series: series, showTitle: false),
          ),
          const SizedBox(height: 6),
          Text(
            series.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            series.readCounter,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (summary.label != null)
            Text(
              summary.label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.primary),
            ),
        ],
      ),
    );
  }
}

/// One continue-reading card.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.entry,
    required this.onOpen,
    required this.onOpenSeries,
  });

  final ContinueReadingEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onOpenSeries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: ComicTokens.continueCardWidth,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
        child: InkWell(
          key: Key('continue-${entry.book.bookId}'),
          borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
          // The card opens the book directly. The cover inside it is a second
          // target that goes to the series — "resume this book" and "look at
          // this series" are different intentions.
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(ComicTokens.spaceXs),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onOpenSeries,
                  child: SizedBox(
                    width: 56,
                    child: AspectRatio(
                      aspectRatio: ComicTokens.coverAspectRatio,
                      child: SeriesCover(
                        series: entry.series,
                        showTitle: false,
                        borderRadius: 6,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: ComicTokens.spaceXs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.series.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      Text(
                        entry.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: entry.book.progressRatio,
                          minHeight: 4,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.progressLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      if (entry.downloaded)
                        Text(
                          '已下载，可离线阅读',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: const Color(0xFF81C784),
                                  ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
