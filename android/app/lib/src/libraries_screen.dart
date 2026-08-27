import 'dart:io';

import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'models.dart';
import 'series.dart';
import 'series_detail.dart';

/// Library 列表：每个库的本地计数、根路径与可用性（全部来自 SQLite）。
class LibrariesScreen extends StatefulWidget {
  const LibrariesScreen({
    super.key,
    required this.repository,
    this.selectedLibraryId,
    this.onSelected,
  });

  final LibraryRepository repository;
  final String? selectedLibraryId;

  /// Applies a shelf scope ('全部' clears it) before popping back.
  final void Function(String? libraryId)? onSelected;

  @override
  State<LibrariesScreen> createState() => _LibrariesScreenState();
}

class _LibrariesScreenState extends State<LibrariesScreen> {
  List<LibraryCount> _libraries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.repository.fetchLibraryCounts();
    if (!mounted) return;
    setState(() {
      _libraries = rows;
      _loading = false;
    });
  }

  void _select(String? libraryId) {
    widget.onSelected?.call(libraryId);
    // The shelf is the app's root route: return straight to it.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final totalSeries = _libraries.fold<int>(0, (sum, l) => sum + l.seriesCount);
    final totalBooks = _libraries.fold<int>(0, (sum, l) => sum + l.bookCount);
    return Scaffold(
      appBar: AppBar(title: const Text('图书馆')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _libraries.isEmpty
              ? const Center(child: Text('尚未同步任何 Library'))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.library_books_outlined),
                        title: const Text('全部 Series'),
                        subtitle: Text('共 $totalSeries 个 Series · $totalBooks 本书'),
                        trailing: widget.selectedLibraryId == null
                            ? const Icon(Icons.check_circle, color: Colors.blue)
                            : const Icon(Icons.filter_alt_outlined),
                        onTap: () => _select(null),
                      ),
                    ),
                    for (final lib in _libraries)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(lib.name),
                          subtitle: Text(_subtitle(lib)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '设为书架筛选',
                                icon: const Icon(Icons.filter_alt_outlined),
                                onPressed: () => _select(lib.remoteId),
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LibraryDetailScreen(
                                  repository: widget.repository,
                                  libraryId: lib.remoteId,
                                  onSelected: widget.onSelected,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
    );
  }

  String _subtitle(LibraryCount lib) {
    final counts = '${lib.seriesCount} Series · ${lib.bookCount} Books · 已读 ${lib.readCount}';
    final root = lib.root;
    if (root == null || root.isEmpty) return lib.unavailable ? '$counts · 不可用' : counts;
    return lib.unavailable ? '$counts · $root · 不可用' : '$counts · $root';
  }
}

/// Library 详情：统计 + 阅读进度 + 根路径 + 该库的 Series 封面墙（本地 FTS 搜索、分页）。
class LibraryDetailScreen extends StatefulWidget {
  const LibraryDetailScreen({
    super.key,
    required this.repository,
    required this.libraryId,
    this.onSelected,
  });

  final LibraryRepository repository;
  final String libraryId;
  final void Function(String? libraryId)? onSelected;

  @override
  State<LibraryDetailScreen> createState() => _LibraryDetailScreenState();
}

class _LibraryDetailScreenState extends State<LibraryDetailScreen> {
  static const int _pageSize = 50;

  LibraryCount? _library;
  List<Series> _items = const [];
  Map<String, String> _covers = const {};
  int _total = 0;
  String _search = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  final TextEditingController _searchController = TextEditingController();

  Future<void> _load({bool append = false}) async {
    final repository = widget.repository;
    final page = await repository.querySeries(
      libraryId: widget.libraryId,
      search: _search.isEmpty ? null : _search,
      limit: _pageSize,
      offset: append ? _items.length : 0,
    );
    final results = await Future.wait([
      repository.libraryDetail(libraryId: widget.libraryId),
      repository.fetchCoverPaths(),
    ]);
    if (!mounted) return;
    setState(() {
      _library = results[0] as LibraryCount?;
      _covers = results[1] as Map<String, String>;
      _items = append ? [..._items, ...page.items] : page.items;
      _total = page.total;
      _loading = false;
    });
  }

  bool get _hasMore => _items.length < _total;

  @override
  Widget build(BuildContext context) {
    final library = _library;
    return Scaffold(
      appBar: AppBar(
        title: Text(library?.name ?? 'Library'),
        actions: [
          IconButton(
            tooltip: '设为书架筛选',
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () {
              widget.onSelected?.call(widget.libraryId);
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (library != null) _header(library),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: '在此库中搜索（本地 FTS）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) {
                      setState(() => _search = value.trim());
                      _load();
                    },
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 140,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2 / 3,
                    ),
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _items.length) {
                        return Center(
                          child: TextButton(
                            onPressed: () => _load(append: true),
                            child: Text('加载更多（${_items.length} / $_total）'),
                          ),
                        );
                      }
                      return _cell(_items[index]);
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _header(LibraryCount library) {
    final progress = library.bookCount == 0
        ? 0.0
        : (library.readCount / library.bookCount).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _stat('${library.seriesCount}', 'Series'),
                _stat('${library.bookCount}', 'Books'),
                _stat('${library.readCount}', '已读'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              '阅读进度 ${library.readCount} / ${library.bookCount}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (library.root != null && library.root!.isNotEmpty)
              Text(
                '根路径 ${library.root}',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (library.unavailable)
              Text(
                '服务端标记为不可用',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _cell(Series item) {
    final path = _covers[item.remoteId];
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SeriesDetailScreen(
              repository: widget.repository,
              seriesId: item.remoteId,
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: path != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.menu_book_outlined),
                    ),
                  )
                : const Icon(Icons.menu_book_outlined),
          ),
          const SizedBox(height: 4),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
