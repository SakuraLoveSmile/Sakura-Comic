import 'package:flutter/material.dart';

import 'download_controller.dart';
import 'error_presentation.dart';
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
  /// The last read of the queue that failed, or null once one has worked.
  ///
  /// Kept because a list nobody could read is not an empty list: without this
  /// the screen answers a database it could not open with 「还没有下载」, which is
  /// a claim about the user's device that nothing verified.
  Object? _loadFailure;

  @override
  void initState() {
    super.initState();
    // Listener, not owner: the controller outlives this route (the shelf
    // creates it above every route), so this must never dispose it.
    widget.controller
      ..addListener(_repaint)
      ..start();
    _load();
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

  /// Read the queue and the storage figures, keeping a failure for the screen to
  /// show instead of letting it land nowhere.
  Future<void> _load() async {
    final controller = widget.controller;
    try {
      await controller.refresh(withStorage: true);
      if (_loadFailure != null && mounted) {
        setState(() => _loadFailure = null);
      }
    } catch (error) {
      if (mounted) setState(() => _loadFailure = error);
    }
  }

  /// Delete every offline book on this server, after saying what that costs.
  ///
  /// The rules about what may be deleted live in the core; this only owns the
  /// asking, because a gesture that can empty a server's offline library in one
  /// tap is not one to run on a mis-tap.
  Future<void> _deleteAll() async {
    final controller = widget.controller;
    final books = controller.books;
    // The figure the question promises back is the one the storage card above
    // already counts, so the two cannot disagree.
    final bytes = controller.storage?.downloadBytes ??
        books.fold<int>(0, (sum, book) => sum + book.bytesDone);
    // Grabbed before the awaits: a context that outlives the widget it came from
    // is how a snackbar becomes a crash.
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('全部删除'),
        content: Text('会删掉这台设备上本服务器的全部离线书籍：'
            '${books.length} 本，共 ${formatBytes(bytes)}。'
            '媒体库里的书不受影响，以后还能重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirm-delete-all'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final outcome = await controller.removeAll();
      messenger.showSnackBar(SnackBar(
        content: Text(outcome.books == 0
            ? '没有可删除的离线书籍'
            : '已删除 ${outcome.books} 本离线书籍，释放 ${formatBytes(outcome.freedBytes)}'),
      ));
    } catch (_) {
      // Nothing here has to unwind: the list below is SQLite's answer, and it
      // still shows whatever is actually on the device.
      messenger.showSnackBar(const SnackBar(content: Text('删除没有完成，稍后再试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final books = controller.books;
    final storage = controller.storage;
    final loadFailure = _loadFailure;
    // Why the queue is standing still, in words. The core's identifier and the
    // controller's stringified failure both stop at [_queueNotice].
    final notice = _queueNotice(controller.stopReason, controller.failure);
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载'),
        actions: [
          IconButton(
            key: const Key('downloads-delete-all'),
            tooltip: '全部删除',
            icon: const Icon(Icons.delete_sweep_outlined),
            // A queue with nothing in it is not worth asking about.
            onPressed: books.isEmpty ? null : _deleteAll,
          ),
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
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (notice != null) _StatusBar(notice: notice),
            if (storage != null) _StorageCard(storage: storage),
            const SizedBox(height: 12),
            if (loadFailure != null)
              _LoadFailureCard(onRetry: _load)
            else if (books.isEmpty)
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

/// One thing worth telling the user about a queue that is not moving.
class _QueueNotice {
  const _QueueNotice(this.text, {this.attention = false});

  final String text;

  /// True when nothing moves until the user does something about it, which is
  /// what makes the bar worth colouring rather than merely tinting.
  final bool attention;
}

/// The line above the queue that says why it is standing still.

/// [stopReason] is the core's own identifier (`downloads/queue.rs`), so this
/// function is the only place that vocabulary is allowed to end: an identifier
/// printed on a phone is a sentence nobody wrote. The reasons that mean the
/// pump is working rather than stuck (`budget`, `drained`, `bytes`, `elapsed`,
/// `idle`, `paused`) answer `null` — a bar claiming "still going" every second
/// is noise, and the book cards already say 下载中 and 已暂停.
_QueueNotice? _queueNotice(String stopReason, Object? failure) {
  // A turn that threw has no report at all, so it is answered first. The
  // wording is per error code: the core's message is its own English text and
  // belongs in a log, never on this line.
  if (failure != null) {
    final presented = FailurePresentation.from(failure);
    // A failure with a code already has its own sentence ('本地数据库正被占用…');
    // one without a code has none, so the bar names the step instead of leaving
    // the generic '操作没有完成' standing on its own.
    return _QueueNotice(
        presented.code == null ? '下载这一步没有完成，稍后会自动重试' : presented.headline,
        attention: presented.needsReauth);
  }
  switch (stopReason) {
    case 'lowSpace':
      return const _QueueNotice('存储空间不足，清理后再继续', attention: true);
    case 'linkDown':
      return const _QueueNotice('网络断开了，恢复后会自动继续');
    case 'throttled':
      return const _QueueNotice('服务器限流，稍后自动重试');
    case 'blocked':
      return const _QueueNotice('服务器拒绝了这次下载，稍后自动重试',
          attention: true);
    case 'linkBlocked':
      return const _QueueNotice(
        '现在用的是蜂窝网络，为了省流量不会自动下载；想现在就下，可以在书卡上允许用蜂窝',
        attention: true,
      );
    case 'parked':
      return const _QueueNotice('已暂停等待，到点会自动继续');
    case 'gone':
      return const _QueueNotice('有一本在服务器上已经找不到了，不会再下载');
    case 'ioFailed':
      return const _QueueNotice('写不进磁盘，检查一下剩余空间', attention: true);
    case 'badRun':
      return const _QueueNotice('服务器连着返回坏数据，先停下，稍后自动重试');
    case 'badPage':
      return const _QueueNotice('有一页数据坏了，稍后自动重试');
    case '':
    case 'none':
    case 'drained':
    case 'budget':
    case 'bytes':
    case 'elapsed':
    case 'idle':
    case 'paused':
      return null;
    default:
      // Deliberately says the reason is unknown instead of printing it: the
      // identifier is a contract between the core and this file, not a word for
      // the person holding the phone.
      return const _QueueNotice('下载停在一个我们还不认识的原因上，稍后会自动重试');
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.notice});

  final _QueueNotice notice;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground =
        notice.attention ? colors.onErrorContainer : colors.onSecondaryContainer;
    return Container(
      key: const Key('downloads-status'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: notice.attention ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            notice.attention ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(notice.text,
                style: TextStyle(fontSize: 13, color: foreground)),
          ),
        ],
      ),
    );
  }
}

/// The queue could not be read at all.
///
/// A screen that answers an unreadable list with 「还没有下载」 is telling the user
/// their device is empty, which is a claim nothing here verified. This takes the
/// list's place instead, and offers the one action that can help.
class _LoadFailureCard extends StatelessWidget {
  const _LoadFailureCard({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('downloads-load-failed'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载列表没有读出来', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '设备上的离线文件还在，这次是本地的记录没读到。重试一次通常就好。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('downloads-retry-load'),
              onPressed: onRetry,
              child: const Text('重试'),
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
