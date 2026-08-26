import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'server_manager.dart';
import 'servers_screen.dart';
import 'series.dart';

/// Library cover wall — reads series through [LibraryRepository] (local
/// store); server management is one tap away (ServerManager).
class SeriesGridScreen extends StatefulWidget {
  const SeriesGridScreen({
    super.key,
    this.repository = const StubLibraryRepository(),
    this.manager,
    this.rustStatus,
  });

  final LibraryRepository repository;

  /// Optional server manager — enables the server management entry point.
  final ServerManager? manager;

  /// Optional FFI connectivity banner (e.g. "Rust core FFI 已连接").
  final String? rustStatus;

  @override
  State<SeriesGridScreen> createState() => _SeriesGridScreenState();
}

class _SeriesGridScreenState extends State<SeriesGridScreen> {
  List<Series> _series = const [];
  Object? _error;
  String? _activeServerName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.fetchSeries();
      if (!mounted) return;
      setState(() => _series = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _loadServerName() async {
    final manager = widget.manager;
    if (manager == null) return;
    final id = await manager.activeServerId();
    if (id == null) {
      if (mounted && _activeServerName != null) {
        setState(() => _activeServerName = null);
      }
      return;
    }
    final profile = await manager.get(serverId: id);
    if (!mounted) return;
    setState(() => _activeServerName = profile?.displayName);
  }

  Future<void> _openServers() async {
    final manager = widget.manager;
    if (manager == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServersScreen(
          manager: manager,
          onChanged: () {
            _load();
            _loadServerName();
          },
        ),
      ),
    );
    await _load();
    await _loadServerName();
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    return Scaffold(
      appBar: AppBar(
        title: Text(_activeServerName ?? 'Library'),
        actions: [
          if (manager != null)
            IconButton(
              onPressed: _openServers,
              tooltip: '服务器',
              icon: const Icon(Icons.dns_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.rustStatus != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                widget.rustStatus!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    if (_series.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('暂无 Series — 添加服务器并完成连接后显示封面墙'),
            if (widget.manager != null)
              TextButton(
                onPressed: _openServers,
                child: const Text('管理服务器'),
              ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2 / 3,
      ),
      itemCount: _series.length,
      itemBuilder: (context, index) {
        final item = _series[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.menu_book_outlined),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}