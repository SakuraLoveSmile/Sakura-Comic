import 'package:flutter/material.dart';

import 'download_controller.dart';
import 'rust/ffi/application.dart';

/// The download queue, and what the device is holding.
///
/// One screen rather than two: the storage numbers exist to explain the queue, and
/// splitting them meant a second route for six numbers.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  @override
  void initState() {
    super.initState();
    // Listener, not owner: the controller outlives this route (the shelf
    // creates it above every route), so this must never dispose it.
    widget.controller
      ..addListener(_repaint)
      ..start()
      ..refresh(withStorage: true);
  }

  @override
  void dispose() {
    widget.controller
      ..stop()
      ..removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final books = controller.books;
    final storage = controller.storage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载'),
        actions: [
          IconButton(
            key: const Key('downloads-sweep'),
            tooltip: '检查修复',
            icon: const Icon(Icons.build_outlined),
            onPressed: () async {
              // Grabbed before the awaits: a context that outlives the widget it
              // came from is how a snackbar becomes a crash.
              final messenger = ScaffoldMessenger.of(context);
              final report = await controller.sweep();
              await controller.refresh(withStorage: true);
              messenger.showSnackBar(SnackBar(
                content: Text(report.repairs() == 0
                    ? '下载内容完好，无需修复'
                    : '修复了 ${report.repairs()} 处不一致'),
              ));
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => controller.refresh(withStorage: true),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (storage != null) _StorageCard(storage: storage),
            const SizedBox(height: 12),
            if (books.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('还没有下载')),
              )
            else
              for (final book in books)
                _BookCard(
                  key: Key('download-${book.bookId}'),
                  book: book,
                  blocked: controller.stopReason == 'linkBlocked',
                  controller: controller,
                ),
          ],
        ),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.storage});

  final StorageDto storage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('存储', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('已下载',
                '${storage.bookCount} 本 · ${formatBytes(storage.downloadBytes)}'),
            _row('页面缓存', formatBytes(storage.cachePageBytes)),
            _row('预取缓存', formatBytes(storage.cachePrefetchBytes)),
            _row('封面缓存', formatBytes(storage.cacheThumbnailBytes)),
            if (storage.unownedBytes > 0)
              _row('无法归属',
                  '${storage.unownedBooks} 个目录 · ${formatBytes(storage.unownedBytes)}'),
            _row(
              '剩余空间',
              storage.freeVolumeBytes > 0
                  ? formatBytes(storage.freeVolumeBytes)
                  : '未知',
            ),
            const SizedBox(height: 8),
            Text(
              '清理缓存不会影响已下载的书籍。缓存是可以重取的东西，下载不是。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
                width: 80,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.book,
    required this.controller,
    required this.blocked,
  });

  final DownloadBookDto book;
  final DownloadController controller;
  final bool blocked;

  static const _labels = {
    'waiting': '排队中',
    'downloading': '下载中',
    'paused': '已暂停',
    'completed': '已完成',
    'failed': '失败',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = book.pagesTotal < 1 ? 1 : book.pagesTotal;
    final fraction = (book.pagesDone / total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.title.isEmpty ? book.bookId : book.title,
                style: theme.textTheme.titleSmall),
            if (book.seriesTitle.isNotEmpty)
              Text(book.seriesTitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(_labels[book.state] ?? book.state,
                    style: theme.textTheme.bodySmall),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已下载 ${book.pagesDone}/${book.pagesTotal} 页 · '
                    '${formatBytes(book.bytesDone)}/${formatBytes(book.bytesTotal)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (book.stale)
              Text('服务器上已经没有这本书，本机的这份仍可阅读',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.tertiary)),
            if (book.lastError.isNotEmpty)
              Text(book.lastError,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  if (book.state == 'waiting' || book.state == 'downloading')
                    TextButton(
                      key: Key('pause-${book.bookId}'),
                      onPressed: () => controller.pause(book.bookId),
                      child: const Text('暂停'),
                    ),
                  if (book.state == 'paused')
                    TextButton(
                      key: Key('resume-${book.bookId}'),
                      onPressed: () => controller.resumeBook(book.bookId),
                      child: const Text('继续'),
                    ),
                  if (book.state == 'failed')
                    TextButton(
                      key: Key('retry-${book.bookId}'),
                      onPressed: () => controller.retry(book.bookId),
                      child: const Text('重试'),
                    ),
                  if (blocked && !book.allowCellular)
                    TextButton(
                      key: Key('cellular-${book.bookId}'),
                      onPressed: () =>
                          controller.allowCellular(book.bookId, true),
                      child: const Text('用蜂窝下载'),
                    ),
                  TextButton(
                    key: Key('delete-${book.bookId}'),
                    onPressed: () => _confirmDelete(context),
                    child: const Text('删除下载'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Delete is the one action here that cannot be undone, so it asks — and it asks
  /// in words that say the offline copy is what goes, not the book.
  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('只删除本机的离线副本「${book.title}」，媒体库不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.remove(book.bookId);
    }
  }
}

/// Bytes the way a person reads them. The core reports integers because integers are
/// what it measured; this is presentation only.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

extension on DownloadSweepDto {
  /// How much the sweep had to repair. Mirrors the core's own `repairs()`: a healthy
  /// queue answers 0, and that is the number the message depends on.
  int repairs() =>
      staleParts +
      ghostRows +
      corrupt +
      sizeMismatch +
      adoptedFiles +
      countersRepaired +
      manifestsRewritten +
      pagesRemoved;
}
