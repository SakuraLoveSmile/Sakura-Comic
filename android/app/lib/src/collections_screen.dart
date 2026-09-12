import 'dart:io';

import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'models.dart';
import 'series_detail.dart';
import 'series.dart';

/// 合集 tab: collection list → member series wall (全部本地).
class CollectionsScreen extends StatelessWidget {
  const CollectionsScreen({
    super.key,
    required this.repository,
    this.collections = const [],
  });

  final LibraryRepository repository;
  final List<CollectionItem> collections;

  @override
  Widget build(BuildContext context) {
    if (collections.isEmpty) {
      return const Center(child: Text('暂无合集'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: collections.length,
      itemBuilder: (context, index) {
        final item = collections[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.collections_bookmark_outlined),
            title: Text(item.name),
            subtitle: item.ordered ? const Text('手动排序') : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CollectionDetailScreen(
                    repository: repository,
                    collectionId: item.remoteId,
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

/// One collection's members (series wall, paged).
class CollectionDetailScreen extends StatefulWidget {
  const CollectionDetailScreen({
    super.key,
    required this.repository,
    required this.collectionId,
    required this.name,
  });

  final LibraryRepository repository;
  final String collectionId;
  final String name;

  @override
  State<CollectionDetailScreen> createState() => _CollectionDetailScreenState();
}

class _CollectionDetailScreenState extends State<CollectionDetailScreen> {
  List<Series> _members = const [];
  Map<String, String> _coverPaths = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final detail = await widget.repository
        .collectionDetail(collectionId: widget.collectionId);
    if (detail == null) return;
    // Its own page-scoped lookup: a member series is not necessarily on the
    // shelf's loaded pages, so inheriting the shelf's cover map would leave
    // holes where the collection is the only place the series appears.
    final covers = await widget.repository.fetchCoverPaths(
      seriesIds: detail.members.items.map((s) => s.remoteId).toList(),
    );
    if (!mounted) return;
    setState(() {
      _members = detail.members.items;
      _coverPaths = covers;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 2 / 3,
        ),
        itemCount: _members.length,
        itemBuilder: (context, index) {
          final item = _members[index];
          final path = _coverPaths[item.remoteId];
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
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.menu_book_outlined),
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
        },
      ),
    );
  }
}
