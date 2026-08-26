import 'dart:io';

import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'server_manager.dart';
import 'servers_screen.dart';
import 'series.dart';

/// Library cover wall — reads series + cover paths from the local store
/// ([LibraryRepository]); network is confined to sync/demo actions (Local
/// First: 本地数据库负责展示). Server management is one tap away.
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
  Map<String, String> _coverPaths = const {};
  Object? _error;
  String? _activeServerName;
  bool _syncing = false;
  bool _autoSynced = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.fetchSeries();
      final covers = await widget.repository.fetchCoverPaths();
      if (!mounted) return;
      setState(() {
        _series = rows;
        _coverPaths = covers;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
    _maybeAutoSync();
  }

  /// First load with an FFI-backed repository triggers one sync (mirrors
  /// the iOS `initialLoad`): pull series into SQLite + backfill covers.
  Future<void> _maybeAutoSync() async {
    if (_autoSynced || !widget.repository.demoSupported) return;
    _autoSynced = true;
    await _sync(announce: false);
  }

  /// Acceptance chain on tap: 拉取 Series → SQLite → 补齐封面 → 重读本地库.
  Future<void> _sync({bool announce = true}) async {
    setState(() => _syncing = true);
    try {
      final summary = await widget.repository.bootstrapActiveServer();
      await _load();
      if (!mounted) return;
      if (announce) {
        final message = summary == null
            ? '没有可同步的服务器（先添加并连接）'
            : '已同步 ${summary.syncedSeries} 个 Series 到本地库';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (!mounted) return;
      if (announce) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('同步失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Offline demo: fixture series + generated covers (no server needed).
  Future<void> _loadDemo() async {
    setState(() => _syncing = true);
    try {
      final summary = await widget.repository.loadDemo();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('演示数据：${summary.syncedSeries} 个 Series')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('演示加载失败: $e')));
    } finally {
      if (mounted) setState(() => _syncing = false);
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
          if (widget.repository.demoSupported)
            IconButton(
              onPressed: _syncing ? null : _loadDemo,
              tooltip: '演示（本地封面墙）',
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
          IconButton(
            onPressed: _syncing ? null : _sync,
            tooltip: '同步',
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
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
            const Text('暂无 Series — 添加服务器并同步后显示封面墙'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                if (widget.manager != null)
                  FilledButton.tonal(
                    onPressed: _openServers,
                    child: const Text('管理服务器'),
                  ),
                if (widget.repository.demoSupported)
                  FilledButton(
                    onPressed: _syncing ? null : _loadDemo,
                    child: const Text('加载演示封面墙'),
                  ),
              ],
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
            Expanded(child: _coverFor(item)),
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

  /// The cover wall tile: the local file path comes from SQLite
  /// (`thumbnails` table) and the image is rendered straight from disk.
  Widget _coverFor(Series item) {
    final path = _coverPaths[item.remoteId];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _coverPlaceholder(),
        ),
      );
    }
    return _coverPlaceholder();
  }

  Widget _coverPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.menu_book_outlined),
    );
  }
}