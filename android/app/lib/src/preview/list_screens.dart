import 'package:flutter/material.dart';

import 'components.dart';
import 'models.dart';
import 'preview_data.dart';
import 'theme.dart';

/// The two browse tabs that are not the shelf.
///
/// They are thin on purpose: the milestone assigns them navigation only, and the
/// prototype has to prove the bottom bar's four entries each land somewhere
/// real without inventing feature scope that is not in this milestone.
class CollectionsScreen extends StatelessWidget {
  const CollectionsScreen({
    super.key,
    required this.series,
    required this.onOpenSeries,
  });

  final List<PreviewSeries> series;
  final void Function(PreviewSeries series) onOpenSeries;

  @override
  Widget build(BuildContext context) {
    final collections = [
      (
        '连载中还没读完',
        '把在读的系列放在一起',
        series.where((s) => s.booksInProgressCount > 0).toList()
      ),
      (
        '短篇与单行本',
        '顺手翻完的',
        series.where((s) => s.effectiveBooksCount <= 5).toList()
      ),
      (
        '可以离线读',
        '至少一册已下载',
        series.where((s) => s.downloadSummary.downloaded > 0).toList()
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('合集'),
        actions: [
          IconButton(
            tooltip: '新建合集',
            icon: const Icon(Icons.add),
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('原型中「新建合集」只做占位')),
            ),
          ),
        ],
      ),
      body: collections.isEmpty
          ? const PreviewStateView(
              icon: Icons.collections_bookmark_outlined,
              headline: '还没有合集',
              detail: '服务器上的合集同步后会出现在这里。',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                ComicTokens.spaceMd,
                ComicTokens.spaceXs,
                ComicTokens.spaceMd,
                ComicTokens.spaceLg,
              ),
              children: [
                for (final (name, subtitle, items) in collections)
                  Card(
                    margin: const EdgeInsets.only(bottom: ComicTokens.spaceSm),
                    child: Padding(
                      padding: const EdgeInsets.all(ComicTokens.spaceSm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            '$subtitle · ${items.length} 个系列',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: ComicTokens.spaceXs),
                          if (items.isEmpty)
                            Text(
                              '这个合集暂时是空的',
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          else
                            SizedBox(
                              height: 92,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: ComicTokens.spaceXs),
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  return GestureDetector(
                                    onTap: () => onOpenSeries(item),
                                    child: SizedBox(
                                      width: 61,
                                      child: AspectRatio(
                                        aspectRatio:
                                            ComicTokens.coverAspectRatio,
                                        child: SeriesCover(
                                            series: item, showTitle: false),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 书单: the milestone's fourth browse entry, kept as a simple ordered list.
class ReadlistsScreen extends StatelessWidget {
  const ReadlistsScreen({
    super.key,
    required this.series,
    required this.onOpenSeries,
    required this.onOpenBook,
  });

  final List<PreviewSeries> series;
  final void Function(PreviewSeries series) onOpenSeries;
  final void Function(PreviewSeries series, PreviewBook book) onOpenBook;

  @override
  Widget build(BuildContext context) {
    final readlists = [
      (
        '睡前读完这一本',
        [
          for (final item in series)
            if (item.books.isNotEmpty) (item, item.orderedBooks.first),
        ]
      ),
      (
        '重读清单',
        [
          for (final item in series)
            if (item.books.any((b) => b.completed))
              (item, item.books.firstWhere((b) => b.completed)),
        ]
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('书单')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: ComicTokens.spaceLg),
        children: [
          for (final (name, entries) in readlists) ...[
            SectionHeader(title: name, subtitle: '${entries.length} 本'),
            for (final (item, book) in entries.take(6))
              ListTile(
                onTap: () => onOpenBook(item, book),
                leading:
                    BookCover(seriesName: book.title, seed: item.coverSeed),
                title: Text('${item.name} · ${book.title}'),
                subtitle: Text(
                  book.completed
                      ? '已读完'
                      : book.inProgress
                          ? '读到第 ${book.resumePage} 页'
                          : '未读',
                ),
                trailing: StatusChip(
                  label: book.downloadState == DownloadState.complete
                      ? '可离线'
                      : '在线',
                  icon: book.downloadState == DownloadState.complete
                      ? Icons.download_done
                      : Icons.cloud_outlined,
                  tone: book.downloadState == DownloadState.complete
                      ? StateTone.success
                      : StateTone.neutral,
                ),
              ),
            const SizedBox(height: ComicTokens.spaceSm),
          ],
        ],
      ),
    );
  }
}

/// The server switcher, reachable from the shelf's title and from settings.
class ServerSwitcherSheet extends StatelessWidget {
  const ServerSwitcherSheet({
    super.key,
    required this.servers,
    required this.onPick,
  });

  final List<PreviewServer> servers;
  final void Function(PreviewServer server) onPick;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ComicTokens.spaceMd,
              ComicTokens.spaceXs,
              ComicTokens.spaceMd,
              ComicTokens.spaceXs,
            ),
            child:
                Text('切换服务器', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final server in servers)
            ListTile(
              key: Key('server-${server.id}'),
              leading: Icon(
                server.active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: server.active
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(server.name),
              subtitle: Text(server.baseUrl),
              trailing: server.credentialState == 'expired'
                  ? const StatusChip(
                      label: '凭据失效',
                      icon: Icons.key_off,
                      tone: StateTone.error,
                    )
                  : null,
              onTap: () => onPick(server),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('添加服务器'),
            onTap: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('原型中「添加服务器」只做占位')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('管理服务器与凭据'),
            onTap: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('现有的服务器管理页会在接入时替换这一行')),
              );
            },
          ),
        ],
      ),
    );
  }
}
