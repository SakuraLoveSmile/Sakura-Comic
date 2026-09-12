import 'package:flutter/material.dart';

import 'components.dart';
import 'models.dart';
import 'preview_data.dart';
import 'theme.dart';

/// Series detail: what the series is, one obvious way to start reading, and the
/// volume list with download state.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.series,
    required this.settings,
    required this.overrides,
    required this.onOpenBook,
    required this.onBack,
    this.initialShowDownloadsOnly = false,
  });

  final PreviewSeries series;
  final PreviewGlobalSettings settings;
  final Map<String, PreviewSeriesOverride> overrides;
  final void Function(PreviewBook book,
      {required bool fromFirstPage, required bool viaReread}) onOpenBook;
  final VoidCallback onBack;
  final bool initialShowDownloadsOnly;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late bool _downloadsOnly = widget.initialShowDownloadsOnly;

  PreviewSeries get _series => widget.series;

  @override
  Widget build(BuildContext context) {
    final intent = _series.readIntent;
    final target = _series.primaryBook;
    final override = widget.overrides[_series.seriesId];
    final books = _downloadsOnly
        ? _series.orderedBooks
            .where((b) => b.downloadState != DownloadState.none)
            .toList()
        : _series.orderedBooks;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 236,
            leading: IconButton(
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onBack,
            ),
            actions: [
              IconButton(
                tooltip: '刷新元数据',
                icon: const Icon(Icons.refresh),
                onPressed: () => _later('刷新元数据'),
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert),
                onPressed: () => _later('更多操作'),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_series.name, style: const TextStyle(fontSize: 15)),
              titlePadding: const EdgeInsetsDirectional.only(
                  start: 52, end: 16, bottom: 12),
              background: _Header(series: _series),
            ),
          ),
          SliverToBoxAdapter(child: _metaBlock(context, override)),
          SliverToBoxAdapter(child: _primaryAction(context, intent, target)),
          SliverToBoxAdapter(
            child: SectionHeader(
              title: '册列表',
              subtitle: _series.completeness == CatalogCompleteness.incomplete
                  ? '本地已镜像 ${_series.mirroredBooks} / ${_series.effectiveBooksCount} 册'
                  : '共 ${_series.effectiveBooksCount} 册',
              trailing: Row(
                children: [
                  FilterChip(
                    label: const Text('只看已下载'),
                    selected: _downloadsOnly,
                    onSelected: (value) =>
                        setState(() => _downloadsOnly = value),
                  ),
                ],
              ),
            ),
          ),
          if (_series.completeness == CatalogCompleteness.incomplete)
            SliverToBoxAdapter(
              child: PreviewBanner(
                icon: Icons.cloud_sync_outlined,
                message: _series.incompleteNotice,
                tone: StateTone.warning,
                actionLabel: '同步',
                onAction: () => _later('同步系列'),
              ),
            ),
          if (books.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: PreviewStateView(
                icon: _downloadsOnly
                    ? Icons.download_outlined
                    : Icons.menu_book_outlined,
                headline: _downloadsOnly ? '这个系列还没有下载' : '这个系列还没有册',
                detail: _downloadsOnly
                    ? '下载整册后可以离线阅读。'
                    : '服务器上这个系列是空的；同步一次看看是否已经补上。',
                primaryLabel: _downloadsOnly ? '显示全部册' : '重新同步',
                onPrimary: () {
                  if (_downloadsOnly) {
                    setState(() => _downloadsOnly = false);
                  } else {
                    _later('重新同步');
                  }
                },
              ),
            )
          else
            SliverList.builder(
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                final isTarget = target != null && book.bookId == target.bookId;
                return _BookTile(
                  key: Key('book-${book.bookId}'),
                  series: _series,
                  book: book,
                  highlighted: isTarget,
                  onOpen: () => widget.onOpenBook(
                    book,
                    fromFirstPage: false,
                    viaReread: intent == ReadIntent.reread,
                  ),
                  onDownload: () => _later('下载 ${book.title}'),
                );
              },
            ),
          const SliverToBoxAdapter(
              child: SizedBox(height: ComicTokens.spaceLg)),
        ],
      ),
    );
  }

  Widget _metaBlock(BuildContext context, PreviewSeriesOverride? override) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveMode = override?.mode ?? widget.settings.mode;
    final effectiveDirection = override?.direction ?? widget.settings.direction;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        ComicTokens.spaceMd,
        ComicTokens.spaceMd,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: ComicTokens.spaceXs,
            runSpacing: 6,
            children: [
              StatusChip(
                label:
                    '已读 ${_series.booksReadCount}/${_series.effectiveBooksCount} 册',
                icon: Icons.check_circle_outline,
                tone: StateTone.success,
              ),
              if (_series.booksInProgressCount > 0)
                StatusChip(
                  label: '在读 ${_series.booksInProgressCount} 册',
                  icon: Icons.auto_stories_outlined,
                ),
              if (_series.status != null)
                StatusChip(
                    label: _statusLabel(_series.status!),
                    icon: Icons.timelapse),
              StatusChip(
                label:
                    '${readModeLabel(effectiveMode)} · ${directionLabel(effectiveDirection)}'
                    '${override == null ? '（跟随全局）' : '（此系列单独设置）'}',
                icon: Icons.chrome_reader_mode_outlined,
              ),
            ],
          ),
          if (_series.summary != null) ...[
            const SizedBox(height: ComicTokens.spaceSm),
            Text(
              _series.summary!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (_series.genres.isNotEmpty) ...[
            const SizedBox(height: ComicTokens.spaceSm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final genre in _series.genres)
                  Chip(
                    label: Text(genre),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
          const SizedBox(height: ComicTokens.spaceSm),
          Text(
            [
              if (_series.publisher != null) _series.publisher!,
              if (_series.language != null) _series.language!,
              if (_series.ageRating != null) _series.ageRating!,
            ].join(' · '),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// The primary button, and the thing that makes it honest: it names exactly
  /// which book it will open and why that one.
  Widget _primaryAction(
      BuildContext context, ReadIntent intent, PreviewBook? target) {
    final scheme = Theme.of(context).colorScheme;
    final label = intent.label;
    final enabled = target != null && intent != ReadIntent.empty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        ComicTokens.spaceLg,
        ComicTokens.spaceMd,
        ComicTokens.spaceXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const Key('detail-primary-action'),
            onPressed: enabled
                ? () => widget.onOpenBook(
                      target,
                      fromFirstPage: intent == ReadIntent.reread,
                      viaReread: intent == ReadIntent.reread,
                    )
                : null,
            icon: Icon(
              switch (intent) {
                ReadIntent.continueReading => Icons.play_arrow,
                ReadIntent.startReading => Icons.menu_book,
                ReadIntent.reread => Icons.restart_alt,
                ReadIntent.empty => Icons.block,
              },
            ),
            label: Text(label),
          ),
          const SizedBox(height: 6),
          Text(
            switch (intent) {
              ReadIntent.continueReading =>
                '打开 ${target?.title ?? ''} · 第 ${target?.resumePage ?? 1} 页',
              ReadIntent.startReading => '从 ${target?.title ?? ''} 开始',
              ReadIntent.reread => '从 ${target?.title ?? ''} 第 1 页打开（不改变已读状态）',
              ReadIntent.empty => '这个系列没有可以打开的册',
            },
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (_series.completeness != CatalogCompleteness.complete) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '本地目录尚未完整同步，主按钮只保证打开已知的这一册',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status.toUpperCase()) {
      case 'ONGOING':
        return '连载中';
      case 'ENDED':
        return '已完结';
      case 'HIATUS':
        return '休载';
      case 'ABANDONED':
        return '已弃坑';
      default:
        return status;
    }
  }

  void _later(String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('原型中「$action」只做占位')),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.series});

  final PreviewSeries series;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        SeriesCover(series: series, showTitle: false, borderRadius: 0),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.15),
                Colors.black.withValues(alpha: 0.75),
              ],
            ),
          ),
        ),
        Positioned(
          left: ComicTokens.spaceMd,
          bottom: 54,
          right: ComicTokens.spaceMd,
          child: Text(
            series.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
            ),
          ),
        ),
      ],
    );
  }
}

/// One volume row: number, title, progress, download state, and the actions the
/// milestone asks for (read, download, mark read).
class _BookTile extends StatelessWidget {
  const _BookTile({
    super.key,
    required this.series,
    required this.book,
    required this.highlighted,
    required this.onOpen,
    required this.onDownload,
  });

  final PreviewSeries series;
  final PreviewBook book;
  final bool highlighted;
  final VoidCallback onOpen;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = book.completed
        ? '已读完'
        : book.inProgress
            ? '读到第 ${book.resumePage} 页 / ${book.pages} 页'
            : '未读 · ${book.pages} 页';
    return Container(
      color: highlighted ? scheme.primary.withValues(alpha: 0.08) : null,
      child: ListTile(
        onTap: onOpen,
        leading: BookCover(seriesName: book.title, seed: series.coverSeed),
        title: Text(book.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle),
            const SizedBox(height: 4),
            if (book.downloadState == DownloadState.none)
              Text('未下载', style: Theme.of(context).textTheme.labelSmall)
            else
              StatusChip(
                label: book.downloadState == DownloadState.complete
                    ? '已下载 · 可离线阅读'
                    : '${book.downloadState.label} · ${book.downloadedPages}/${book.pages} 页',
                icon: book.downloadState == DownloadState.complete
                    ? Icons.download_done
                    : Icons.downloading,
                tone: book.downloadState == DownloadState.complete
                    ? StateTone.success
                    : book.downloadState == DownloadState.failed
                        ? StateTone.error
                        : StateTone.warning,
              ),
            if (book.inProgress || book.completed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: book.progressRatio,
                    minHeight: 3,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
          ],
        ),
        isThreeLine: true,
        trailing: IconButton(
          tooltip: '下载这一册',
          icon: const Icon(Icons.download_outlined),
          onPressed: onDownload,
        ),
      ),
    );
  }
}
