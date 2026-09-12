import 'dart:async';

import 'package:flutter/material.dart';

import 'components.dart';
import 'models.dart';
import 'preview_data.dart';
import 'theme.dart';

/// The download screen: every state a download can be in, one book at a time.
///
/// The prototype runs a small fake scheduler so the screen is *operable* — pause
/// actually stops the bar, resume restarts it, delete asks first — because a
/// static picture cannot answer "is the busy state legible" or "does deleting
/// explain what it deletes".
class PreviewDownloadsScreen extends StatefulWidget {
  const PreviewDownloadsScreen({
    super.key,
    required this.downloads,
    required this.onChanged,
    required this.onOpenBook,
    required this.onOpenSeries,
  });

  final List<PreviewDownload> downloads;
  final VoidCallback onChanged;
  final void Function(PreviewDownload download) onOpenBook;
  final void Function(PreviewDownload download) onOpenSeries;

  @override
  State<PreviewDownloadsScreen> createState() => _PreviewDownloadsScreenState();
}

class _PreviewDownloadsScreenState extends State<PreviewDownloadsScreen> {
  /// Books whose queue action is in flight. The milestone requires the button to
  /// be disabled while it runs and to come back if the action fails, so the
  /// prototype keeps that busy flag per book rather than per screen.
  final Set<String> _busy = {};

  /// The one book the fake scheduler is allowed to advance.
  String? _running;

  Timer? _ticker;

  /// Whether any list-level read failed — the state that must not be rendered
  /// as "nothing downloaded".
  bool _listError = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted || _listError) return;
    final running = _running;
    if (running == null) return;
    final item =
        widget.downloads.where((d) => d.book.bookId == running).firstOrNull;
    if (item == null || item.state != DownloadState.downloading) {
      _running = null;
      return;
    }
    setState(() {
      item.pagesDone = (item.pagesDone + 6).clamp(0, item.pagesTotal);
      if (item.pagesDone >= item.pagesTotal) {
        item.state = DownloadState.complete;
        _running = null;
        widget.onChanged();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final downloads = widget.downloads;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载'),
        actions: [
          IconButton(
            tooltip: '检查修复',
            icon: const Icon(Icons.build_outlined),
            onPressed: () => _snack('已检查下载内容，没有发现不一致'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'error') {
                setState(() => _listError = !_listError);
              } else if (value == 'all') {
                _confirmRemoveAll();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'error',
                child: Text(_listError ? '恢复正常读取' : '模拟读取失败'),
              ),
              const PopupMenuItem(value: 'all', child: Text('删除全部下载')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        },
        child: _listError
            ? ListView(
                padding: const EdgeInsets.only(top: 48),
                children: [
                  PreviewStateView(
                    icon: Icons.warning_amber_outlined,
                    headline: '下载列表读取失败',
                    detail: '本地数据库读取没有完成。已下载的文件还在设备上，重试即可。',
                    tone: StateTone.error,
                    primaryLabel: '重试',
                    onPrimary: () => setState(() => _listError = false),
                  ),
                ],
              )
            : downloads.isEmpty
                ? ListView(
                    padding: const EdgeInsets.only(top: 48),
                    children: [
                      PreviewStateView(
                        icon: Icons.download_outlined,
                        headline: '还没有下载',
                        detail: '在系列详情里点下载，整册会保存到本机，断网也能读。',
                        primaryLabel: '去书架找内容',
                        onPrimary: () => _snack('书架在底部导航的第一个入口'),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: ComicTokens.spaceLg),
                    children: [
                      const PreviewBanner(
                        icon: Icons.info_outline,
                        message: '保持应用在前台可继续下载；切到后台会暂停开始新的批次，回来之后接着下。',
                      ),
                      _storageCard(context),
                      SectionHeader(
                        title: '下载队列',
                        subtitle: '${downloads.length} 册 · 单册忙碌状态独立',
                        trailing: TextButton(
                          onPressed: _confirmRemoveAll,
                          child: const Text('全部删除'),
                        ),
                      ),
                      for (final item in downloads)
                        _DownloadTile(
                          key: Key('download-${item.book.bookId}'),
                          item: item,
                          busy: _busy.contains(item.book.bookId),
                          onOpenBook: () => widget.onOpenBook(item),
                          onOpenSeries: () => widget.onOpenSeries(item),
                          onPause: () =>
                              _act(item, (d) => d.state = DownloadState.paused),
                          onResume: () => _act(item, (d) {
                            d.state = DownloadState.downloading;
                            _running = d.book.bookId;
                          }),
                          onRetry: () => _act(item, (d) {
                            d.lastError = '';
                            d.state = DownloadState.downloading;
                            _running = d.book.bookId;
                          }),
                          onDelete: () => _confirmRemove(item),
                          onAllowCellular: (allow) =>
                              _act(item, (d) => d.allowCellular = allow),
                        ),
                    ],
                  ),
      ),
    );
  }

  Widget _storageCard(BuildContext context) {
    const storage = previewStorage;
    final scheme = Theme.of(context).colorScheme;
    final cacheRatio = (storage.cacheBytes / storage.cacheLimitBytes)
        .clamp(0.0, 1.0)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        0,
        ComicTokens.spaceMd,
        ComicTokens.spaceXs,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(ComicTokens.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('存储',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  TextButton(
                    onPressed: () => _snack('清理缓存不会影响正式下载'),
                    child: const Text('清理缓存'),
                  ),
                ],
              ),
              _kv('下载占用', formatBytes(storage.downloadedBytes)),
              _kv('设备剩余', formatBytes(storage.deviceFreeBytes)),
              _kv(
                '阅读缓存',
                '${formatBytes(storage.cacheBytes)} / ${formatBytes(storage.cacheLimitBytes)}',
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: cacheRatio,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '清缓存不影响正式下载；下载的书只有你自己删除才会消失。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  /// Runs one state change behind a per-book busy flag.
  Future<void> _act(
      PreviewDownload item, void Function(PreviewDownload) change) async {
    final id = item.book.bookId;
    setState(() => _busy.add(id));
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    setState(() {
      change(item);
      _busy.remove(id);
    });
    widget.onChanged();
  }

  Future<void> _confirmRemove(PreviewDownload item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除下载'),
        content: Text(
          '只会删除本机的离线副本「${item.book.title}」。\n\n'
          '书架信息、阅读进度和其他下载都不会受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('download-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final index = widget.downloads.indexOf(item);
    if (index >= 0) widget.downloads.removeAt(index);
    setState(() {});
    widget.onChanged();
    _snack('已删除本机离线副本');
  }

  Future<void> _confirmRemoveAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除全部下载'),
        content: const Text('只会删除本机的离线副本，书架信息和阅读进度不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => widget.downloads.clear());
    widget.onChanged();
    _snack('已删除全部本机离线副本');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    super.key,
    required this.item,
    required this.busy,
    required this.onOpenBook,
    required this.onOpenSeries,
    required this.onPause,
    required this.onResume,
    required this.onRetry,
    required this.onDelete,
    required this.onAllowCellular,
  });

  final PreviewDownload item;
  final bool busy;
  final VoidCallback onOpenBook;
  final VoidCallback onOpenSeries;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final ValueChanged<bool> onAllowCellular;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = item.state;
    return Card(
      margin: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        0,
        ComicTokens.spaceMd,
        ComicTokens.spaceXs,
      ),
      child: Padding(
        padding: const EdgeInsets.all(ComicTokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: onOpenSeries,
                  child: BookCover(
                      seriesName: item.book.title,
                      seed: item.book.bookId.length),
                ),
                const SizedBox(width: ComicTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      GestureDetector(
                        onTap: onOpenSeries,
                        child: Text(
                          item.seriesName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.primary),
                        ),
                      ),
                      const SizedBox(height: 6),
                      StatusChip(
                        label: _stateLabel(state, item),
                        icon: _stateIcon(state),
                        tone: _stateTone(state),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (state == DownloadState.downloading ||
                state == DownloadState.paused) ...[
              const SizedBox(height: ComicTokens.spaceXs),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: item.ratio,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.pagesDone} / ${item.pagesTotal} 页 · ${formatBytes(item.bytesDone)} / ${formatBytes(item.bytesTotal)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (state == DownloadState.complete) ...[
              const SizedBox(height: ComicTokens.spaceXs),
              Text(
                item.readableRange,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (state == DownloadState.failed && item.lastError.isNotEmpty) ...[
              const SizedBox(height: ComicTokens.spaceXs),
              Text(
                item.lastError,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
              Text(
                '已下载的 ${item.pagesDone} 页仍然可以离线阅读。',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (item.allowCellular) ...[
              const SizedBox(height: 4),
              Text(
                '已允许这一册使用蜂窝网络',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.primary),
              ),
            ],
            const SizedBox(height: ComicTokens.spaceXs),
            Row(
              children: [
                if (state == DownloadState.complete)
                  FilledButton.tonalIcon(
                    key: Key('download-read-${item.book.bookId}'),
                    onPressed: busy ? null : onOpenBook,
                    icon: const Icon(Icons.menu_book, size: 18),
                    label: const Text('阅读'),
                  )
                else if (state == DownloadState.downloading)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onPause,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('暂停'),
                  )
                else if (state == DownloadState.paused)
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : onResume,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('继续'),
                  )
                else if (state == DownloadState.failed)
                  FilledButton.tonalIcon(
                    key: Key('download-retry-${item.book.bookId}'),
                    onPressed: busy ? null : onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  )
                else if (state == DownloadState.queued)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onPause,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('移出队列'),
                  ),
                if (busy) ...[
                  const SizedBox(width: ComicTokens.spaceSm),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                if (!item.allowCellular && state != DownloadState.complete)
                  IconButton(
                    tooltip: '允许用蜂窝网络下载这一册',
                    icon: const Icon(Icons.signal_cellular_alt),
                    onPressed: busy ? null : () => onAllowCellular(true),
                  ),
                IconButton(
                  tooltip: '删除本机副本',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: busy ? null : onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(DownloadState state, PreviewDownload item) {
    switch (state) {
      case DownloadState.complete:
        return '已下载 · ${formatBytes(item.bytesTotal)}';
      case DownloadState.downloading:
        return '下载中 · ${(item.ratio * 100).round()}%';
      case DownloadState.paused:
        return '已暂停 · 第 ${item.pagesDone + 1} 页起继续';
      case DownloadState.failed:
        return '下载失败 · 已重试 3 次';
      case DownloadState.queued:
        return '排队中 · 等待前一册完成';
      case DownloadState.none:
        return '未下载';
    }
  }

  IconData _stateIcon(DownloadState state) {
    switch (state) {
      case DownloadState.complete:
        return Icons.download_done;
      case DownloadState.downloading:
        return Icons.downloading;
      case DownloadState.paused:
        return Icons.pause_circle_outline;
      case DownloadState.failed:
        return Icons.error_outline;
      case DownloadState.queued:
        return Icons.schedule;
      case DownloadState.none:
        return Icons.cloud_download_outlined;
    }
  }

  StateTone _stateTone(DownloadState state) {
    switch (state) {
      case DownloadState.complete:
        return StateTone.success;
      case DownloadState.failed:
        return StateTone.error;
      case DownloadState.downloading:
      case DownloadState.paused:
      case DownloadState.queued:
        return StateTone.warning;
      case DownloadState.none:
        return StateTone.neutral;
    }
  }
}
