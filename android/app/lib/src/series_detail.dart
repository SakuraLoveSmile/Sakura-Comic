import 'dart:io';

import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'reader_controller.dart';
import 'reader_screen.dart';
import 'reader_system_controls.dart';
import 'models.dart';

/// Series detail: metadata (Tags/Genres/Status/Authors/Publisher) + the
/// book list with read status and covers. All data from the local store;
/// the only network touch is the one-shot book-cover backfill.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.repository,
    required this.seriesId,
    this.onChanged,
  });

  final LibraryRepository repository;
  final String seriesId;
  final VoidCallback? onChanged;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  SeriesDetail? _detail;
  List<Book> _books = const [];
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
      widget.repository.fetchBookCoverPaths(),
    ]);
    if (!mounted) return;
    setState(() {
      _detail = results[0] as SeriesDetail?;
      _books = (results[1] as PagedBooks).items;
      _booksTotal = (results[1] as PagedBooks).total;
      _bookCoverPaths = results[2] as Map<String, String>;
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
    if (!mounted) return;
    setState(() {
      _books = page.items;
      _booksTotal = page.total;
    });
  }

  void _loadMoreBooks() {
    _queryBooks(reset: false).then((page) {
      if (!mounted) return;
      setState(() => _books = [..._books, ...page.items]);
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
                if (detail.summary != null && detail.summary!.isNotEmpty) ...[
                  _sectionTitle('简介'),
                  Text(detail.summary!, style: Theme.of(context).textTheme.bodyMedium),
                ],
                if (detail.authors.isNotEmpty) ...[
                  _sectionTitle('作者'),
                  Text(
                    detail.authors
                        .map((a) => a.role.isEmpty ? a.name : '${a.name}（${a.role}）')
                        .join('、'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                Wrap(
                  spacing: 16,
                  children: [
                    if (detail.publisher != null)
                      _infoCell('出版社', detail.publisher!),
                    if (detail.language != null) _infoCell('语言', detail.language!),
                    if (detail.readingDirection != null)
                      _infoCell('阅读方向', detail.readingDirection!),
                    if (detail.ageRating != null) _infoCell('分级', detail.ageRating!),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                    Text('读到 ${book.progressPage} / ${book.pagesCount ?? '?'} 页',
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
      return const Icon(Icons.panorama_fish_eye, size: 18, color: Colors.orange);
    }
    return Icon(Icons.circle_outlined, size: 18, color: Colors.grey.shade500);
  }

  void _openBookDetail(Book book) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _BookDetailSheet(
        repository: widget.repository,
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
  });

  final LibraryRepository repository;
  final Book book;
  final VoidCallback? onChanged;

  @override
  State<_BookDetailSheet> createState() => _BookDetailSheetState();
}

class _BookDetailSheetState extends State<_BookDetailSheet> {
  BookDetail? _detail;

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
              Text(book.seriesTitle!, style: Theme.of(context).textTheme.bodySmall),
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
            Text(_statusText(book), style: Theme.of(context).textTheme.bodyMedium),
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
            if (detail != null && detail.summary != null && detail.summary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('简介', style: Theme.of(context).textTheme.titleSmall),
              Text(detail.summary!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (detail != null && detail.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('标签', style: Theme.of(context).textTheme.bodySmall),
              Text(detail.tags.join('、'), style: Theme.of(context).textTheme.bodyMedium),
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