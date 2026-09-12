import 'dart:io';

import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'reader_controller.dart';
import 'reader_screen.dart';
import 'reader_system_controls.dart';
import 'models.dart';
import 'download_controller.dart';

/// Series detail: metadata (Tags/Genres/Status/Authors/Publisher) + the
/// book list with read status and covers. All data from the local store;
/// the only network touch is the one-shot book-cover backfill.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.repository,
    required this.seriesId,
    this.onChanged,
    this.downloads,
  });

  final LibraryRepository repository;
  final String seriesId;
  final VoidCallback? onChanged;

  /// Stage 9. Null on a build with no queue to talk to, which is the same case as
  /// the reader's in-memory fallback: the button is not rendered at all.
  final DownloadController? downloads;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  SeriesDetail? _detail;
  List<Book> _books = const [];

  /// Which book the read button opens, straight from the core (统一阅读入口).
  ReadTarget? _readTarget;
  Map<String, String> _bookCoverPaths = const {};
  int _booksTotal = 0;
  String? _readFilter;

  @override
  void initState() {
    super.initState();
    _load();
    _syncBookCovers();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.repository.seriesDetail(seriesId: widget.seriesId),
      _queryBooks(reset: true),
      widget.repository.readTarget(seriesId: widget.seriesId),
    ]);
    final page = results[1] as PagedBooks;
    // Covers come after the books, because the query is what says which books
    // to ask about. A page-scoped lookup replaces what used to be the server's
    // entire book-thumbnail table, fetched in order to render ten rows.
    final covers = await widget.repository.fetchBookCoverPaths(
      bookIds: page.items.map((b) => b.remoteId).toList(),
    );
    if (!mounted) return;
    setState(() {
      _detail = results[0] as SeriesDetail?;
      _books = page.items;
      _booksTotal = page.total;
      _bookCoverPaths = covers;
      _readTarget = results[2] as ReadTarget?;
    });
  }

  Future<PagedBooks> _queryBooks({required bool reset}) {
    return widget.repository.queryBooks(
      seriesId: widget.seriesId,
      readStatus: _readFilter,
      sort: 'number',
      limit: 100,
      offset: reset ? 0 : _books.length,
    );
  }

  Future<void> _reloadBooks() async {
    final page = await _queryBooks(reset: true);
    final covers = await widget.repository.fetchBookCoverPaths(
      bookIds: page.items.map((b) => b.remoteId).toList(),
    );
    if (!mounted) return;
    setState(() {
      _books = page.items;
      _booksTotal = page.total;
      _bookCoverPaths = covers;
    });
  }

  Future<void> _loadMoreBooks() async {
    final page = await _queryBooks(reset: false);
    final covers = await widget.repository.fetchBookCoverPaths(
      bookIds: page.items.map((b) => b.remoteId).toList(),
    );
    if (!mounted) return;
    setState(() {
      _books = [..._books, ...page.items];
      _bookCoverPaths = {..._bookCoverPaths, ...covers};
    });
  }

  /// Book-cover backfill (缓存缺失自动补齐): only when a credential exists;
  /// failures are silent — the list renders placeholders.
  Future<void> _syncBookCovers() async {
    try {
      await widget.repository.syncBookCovers(seriesId: widget.seriesId);
    } catch (_) {
      // offline / no credential — covers backfill on the next online visit
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(detail?.name ?? 'Series')),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _header(detail),
                _readAction(detail),
                if (detail.summary != null && detail.summary!.isNotEmpty) ...[
                  _sectionTitle('简介'),
                  Text(detail.summary!,
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
                if (detail.authors.isNotEmpty) ...[
                  _sectionTitle('作者'),
                  Text(
                    detail.authors
                        .map((a) =>
                            a.role.isEmpty ? a.name : '${a.name}（${a.role}）')
                        .join('、'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                Wrap(
                  spacing: 16,
                  children: [
                    if (detail.publisher != null)
                      _infoCell('出版社', detail.publisher!),
                    if (detail.language != null)
                      _infoCell('语言', detail.language!),
                    if (detail.readingDirection != null)
                      _infoCell('阅读方向', detail.readingDirection!),
                    if (detail.ageRating != null)
                      _infoCell('分级', detail.ageRating!),
                  ],
                ),
                if (detail.tags.isNotEmpty) _chipRow('标签', detail.tags),
                if (detail.genres.isNotEmpty) _chipRow('题材', detail.genres),
                _sectionTitle('Books · $_booksTotal'),
                _bookFilters(),
                ..._books.map((book) => _bookRow(book)),
                if (_books.length < _booksTotal)
                  Center(
                    child: TextButton(
                      onPressed: _loadMoreBooks,
                      child: const Text('加载更多'),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _header(SeriesDetail detail) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              if (detail.status != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(detail.status!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 4),
              Text(
                '共 ${detail.booksCount ?? 0} 册 · 已读 ${detail.booksReadCount ?? 0} · '
                '未读 ${detail.booksUnreadCount ?? 0} · 阅读中 ${detail.booksInProgressCount ?? 0}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The one button a reader taps without thinking, so what it says has to be
  /// true: the label, the line under it and the book it opens all come from the
  /// same core answer (`series_read_target`), which is also what the shelf's
  /// rail uses. When the core cannot answer, the button disappears rather than
  /// guessing — opening the wrong volume is worse than asking for a sync.
  Widget _readAction(SeriesDetail detail) {
    final target = _readTarget;
    if (target == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final opens = target.opensBook;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('series-read-action'),
              onPressed: opens ? () => _openReader(context, target.book) : null,
              icon: Icon(
                switch (target.intent) {
                  ReadIntent.continueReading => Icons.play_arrow,
                  ReadIntent.startReading => Icons.menu_book,
                  ReadIntent.reread => Icons.restart_alt,
                  ReadIntent.empty => Icons.block,
                },
              ),
              label: Text(target.intent.label),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            target.detail,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // "No next book" and "we cannot prove there is no next book" are
          // different facts, and only one of them may be stated as an ending.
          if (!target.catalogComplete && detail.booksCount != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '本地目录尚未完整同步（已镜像 ${target.bookCount ?? 0} / ${detail.booksCount} 册）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }

  /// Opens one book in the reader. Everything the reader needs — the page
  /// manifest, the cached files, the reading position — comes from the core
  /// through ReaderApi; the widget never sees a URL.
  Future<void> _openReader(BuildContext context, Book book) async {
    final mediaType = book.mediaType?.toLowerCase() ?? '';
    if (mediaType.contains('epub') || mediaType.contains('pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '当前版本暂不支持 ${mediaType.contains("epub") ? "EPUB" : "PDF"} 格式漫画的直接阅读，请使用外部阅读器。',
          ),
        ),
      );
      return;
    }
    final api = await widget.repository.readerApi(bookId: book.remoteId);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ReaderScreen(
          title: book.title,
          controller: ReaderController(
            api: api,
            systemControls: ReaderSystemControls(),
          ),
        ),
      ),
    );
    widget.onChanged?.call();
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _infoCell(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  Widget _chipRow(String title, List<String> values) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final v in values)
                Chip(
                  label: Text(v, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bookFilters() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: _readFilter == null,
            onSelected: (_) {
              setState(() => _readFilter = null);
              _reloadBooks();
            },
          ),
          ChoiceChip(
            label: const Text('未读'),
            selected: _readFilter == 'unread',
            onSelected: (_) {
              setState(() => _readFilter = 'unread');
              _reloadBooks();
            },
          ),
          ChoiceChip(
            label: const Text('进行中'),
            selected: _readFilter == 'in_progress',
            onSelected: (_) {
              setState(() => _readFilter = 'in_progress');
              _reloadBooks();
            },
          ),
          ChoiceChip(
            label: const Text('已读'),
            selected: _readFilter == 'read',
            onSelected: (_) {
              setState(() => _readFilter = 'read');
              _reloadBooks();
            },
          ),
        ],
      ),
    );
  }

  Widget _bookRow(Book book) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _openBookDetail(book),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            _bookCover(book),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _readIcon(book),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  if (book.number != null)
                    Text('第 ${book.number} 册',
                        style: Theme.of(context).textTheme.bodySmall),
                  if (book.progressPage != null && !book.progressCompleted)
                    Text(
                        '读到 ${book.progressPage} / ${book.pagesCount ?? '?'} 页',
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookCover(Book book) {
    final path = _bookCoverPaths[book.remoteId];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: 42,
          height: 63,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _coverPlaceholder(),
        ),
      );
    }
    return Container(
      width: 42,
      height: 63,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.auto_stories_outlined, size: 18),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      width: 42,
      height: 63,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.auto_stories_outlined, size: 18),
    );
  }

  Widget _readIcon(Book book) {
    if (book.progressCompleted) {
      return const Icon(Icons.check_circle, size: 18, color: Colors.green);
    }
    if ((book.progressPage ?? 0) > 0) {
      return const Icon(Icons.panorama_fish_eye,
          size: 18, color: Colors.orange);
    }
    return Icon(Icons.circle_outlined, size: 18, color: Colors.grey.shade500);
  }

  void _openBookDetail(Book book) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _BookDetailSheet(
        repository: widget.repository,
        downloads: widget.downloads,
        book: book,
        onChanged: () {
          widget.onChanged?.call();
          _reloadBooks();
        },
      ),
    );
  }
}

/// Book metadata + 阅读状态 actions (本地优先 + Outbox).
class _BookDetailSheet extends StatefulWidget {
  const _BookDetailSheet({
    required this.repository,
    required this.book,
    this.onChanged,
    this.downloads,
  });

  final LibraryRepository repository;
  final Book book;
  final VoidCallback? onChanged;
  final DownloadController? downloads;

  @override
  State<_BookDetailSheet> createState() => _BookDetailSheetState();
}

class _BookDetailSheetState extends State<_BookDetailSheet> {
  BookDetail? _detail;
  bool _isDownloadingAction = false;

  /// The button's label follows the queue's state and nothing else. The five words
  /// are the contract's five states
  /// (`specs/contracts/fixtures/downloads/states.json`) rendered for a person;
  /// `''` means the book is not in the queue at all.
  String get _downloadLabel {
    final state = widget.downloads?.stateOf(widget.book.remoteId) ?? '';
    return const {
          'waiting': '排队中',
          'downloading': '下载中',
          'paused': '已暂停',
          'completed': '已下载',
          'failed': '重试下载',
        }[state] ??
        '下载';
  }

  /// One button, five states, and the mapping is the contract's: a tap on a queued
  /// book pauses it, a tap on a paused one resumes it, a tap on a failed one retries
  /// it. Never delete — that gesture only exists on the Downloads screen, where it
  /// asks first.
  Future<void> _toggleDownload() async {
    final controller = widget.downloads;
    if (controller == null || _isDownloadingAction) return;
    final bookId = widget.book.remoteId;
    setState(() => _isDownloadingAction = true);
    try {
      switch (controller.stateOf(bookId)) {
        case 'waiting':
        case 'downloading':
          await controller.pause(bookId);
          break;
        case 'paused':
          await controller.resumeBook(bookId);
          break;
        case 'failed':
          await controller.retry(bookId);
          break;
        case 'completed':
          // Already on the device. Re-downloading means deleting it first, which is a
          // decision worth more than a stray tap.
          break;
        default:
          await controller.enqueue(bookId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载操作失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloadingAction = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.repository.bookDetail(bookId: widget.book.remoteId).then((detail) {
      if (!mounted) return;
      setState(() => _detail = detail);
    });
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final detail = _detail;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.title, style: Theme.of(context).textTheme.titleMedium),
            if (book.seriesTitle != null)
              Text(book.seriesTitle!,
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                if (book.number != null) _cell('册数', book.number!),
                if (book.pagesCount != null) _cell('页数', '${book.pagesCount}'),
                if (book.mediaType != null) _cell('类型', book.mediaType!),
              ],
            ),
            const SizedBox(height: 8),
            Text(_statusText(book),
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => _openReader(context, book),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('开始阅读'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () async {
                    await widget.repository.markRead(bookId: book.remoteId);
                    widget.onChanged?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('标记已读'),
                ),
                if (widget.downloads != null) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    key: Key('download-${book.remoteId}'),
                    onPressed: _isDownloadingAction ? null : _toggleDownload,
                    icon: _isDownloadingAction
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 18),
                    label: Text(_downloadLabel),
                  ),
                ],
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () async {
                    await widget.repository.markUnread(bookId: book.remoteId);
                    widget.onChanged?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('标记未读'),
                ),
              ],
            ),
            if (detail != null &&
                detail.summary != null &&
                detail.summary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('简介', style: Theme.of(context).textTheme.titleSmall),
              Text(detail.summary!,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (detail != null && detail.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('标签', style: Theme.of(context).textTheme.bodySmall),
              Text(detail.tags.join('、'),
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }

  String _statusText(Book book) {
    if (book.progressCompleted) return '阅读状态：已读';
    if ((book.progressPage ?? 0) > 0) {
      final total = book.pagesCount ?? 0;
      final pct = total > 0 ? (book.progressPage! * 100 / total).round() : 0;
      return '阅读状态：读到 ${book.progressPage} / ${book.pagesCount ?? '?'} 页（$pct%）';
    }
    return '阅读状态：未读';
  }

  /// Open the Stage 7 reader for one book. Everything the screen needs — the
  /// page manifest, the cached files, the reading position — comes from the
  /// core through ReaderApi; the widget never sees a URL.
  Future<void> _openReader(BuildContext context, Book book) async {
    final mediaType = book.mediaType?.toLowerCase() ?? '';
    if (mediaType.contains('epub') || mediaType.contains('pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '当前版本暂不支持 ${mediaType.contains("epub") ? "EPUB" : "PDF"} 格式漫画的直接阅读，请使用外部阅读器。',
          ),
        ),
      );
      return;
    }
    final api = await widget.repository.readerApi(bookId: book.remoteId);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ReaderScreen(
          title: book.title,
          controller: ReaderController(
            api: api,
            systemControls: ReaderSystemControls(),
            seriesId: book.seriesId,
            onSeriesLayoutChanged: (mode, direction) => _rememberSeriesLayout(
                messenger, book.seriesId, mode, direction),
          ),
        ),
      ),
    );
    widget.onChanged?.call();
  }

  /// A mode or direction chosen inside the reader belongs to the *series*.
  ///
  /// Writing it to the global preference is the bug this replaces: tap 双页 once
  /// in volume 3 and every other book opened as a spread. The user is told which
  /// of the two levels their tap just changed, so "跟随全局" stays a statement
  /// they can trust.
  Future<void> _rememberSeriesLayout(
    ScaffoldMessengerState messenger,
    String seriesId,
    String mode,
    String direction,
  ) async {
    try {
      await widget.repository.setSeriesOverride(
        seriesId: seriesId,
        mode: mode,
        direction: direction,
      );
    } catch (exception) {
      // The reading session is unaffected either way — this is a preference
      // write, and losing it must not interrupt a page turn.
      debugPrint('[Reader] series override not saved: $exception');
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text('已把此系列设为${_layoutWords(mode, direction)}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _layoutWords(String mode, String direction) {
    const modes = {
      'single': '单页',
      'double': '双页',
      'webtoon': '条漫',
    };
    const directions = {
      'ltr': '左→右',
      'rtl': '右→左',
      'vertical': '上下滚动',
    };
    return '${modes[mode] ?? mode}・${directions[direction] ?? direction}';
  }

  Widget _cell(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
