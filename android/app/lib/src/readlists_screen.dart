import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'models.dart';
import 'series_detail.dart';

/// 书单 tab: readlist list → ordered book list (全部本地).
class ReadlistsScreen extends StatelessWidget {
  const ReadlistsScreen({
    super.key,
    required this.repository,
    this.readlists = const [],
  });

  final LibraryRepository repository;
  final List<ReadlistItem> readlists;

  @override
  Widget build(BuildContext context) {
    if (readlists.isEmpty) {
      return const Center(child: Text('暂无书单'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: readlists.length,
      itemBuilder: (context, index) {
        final item = readlists[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.format_list_bulleted),
            title: Text(item.name),
            subtitle: item.summary == null || item.summary!.isEmpty
                ? null
                : Text(item.summary!,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ReadlistDetailScreen(
                    repository: repository,
                    readlistId: item.remoteId,
                    name: item.name,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// One readlist's ordered books.
class ReadlistDetailScreen extends StatefulWidget {
  const ReadlistDetailScreen({
    super.key,
    required this.repository,
    required this.readlistId,
    required this.name,
  });

  final LibraryRepository repository;
  final String readlistId;
  final String name;

  @override
  State<ReadlistDetailScreen> createState() => _ReadlistDetailScreenState();
}

class _ReadlistDetailScreenState extends State<ReadlistDetailScreen> {
  List<Book> _books = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final detail =
        await widget.repository.readlistDetail(readlistId: widget.readlistId);
    if (!mounted || detail == null) return;
    setState(() => _books = detail.books.items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _books.length,
        itemBuilder: (context, index) {
          final book = _books[index];
          return ListTile(
            leading: Icon(
              book.progressCompleted
                  ? Icons.check_circle
                  : (book.progressPage ?? 0) > 0
                      ? Icons.panorama_fish_eye
                      : Icons.circle_outlined,
              color: book.progressCompleted
                  ? Colors.green
                  : (book.progressPage ?? 0) > 0
                      ? Colors.orange
                      : Colors.grey.shade500,
            ),
            title: Text(book.title),
            subtitle: book.seriesTitle == null
                ? null
                : Text(book.seriesTitle!,
                    style: Theme.of(context).textTheme.bodySmall),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SeriesDetailScreen(
                    repository: widget.repository,
                    seriesId: book.seriesId,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
