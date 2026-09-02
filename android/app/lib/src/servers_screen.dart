import 'package:flutter/material.dart';

import 'error_presentation.dart';
import 'rust/model/server_profile.dart';
import 'server_form_screen.dart';
import 'server_manager.dart';

/// Server management: list / switch / edit / delete / add.
/// All remote entities elsewhere key on (serverId, remoteId); switching the
/// active server is the only global state (app_state.active_server_id).
class ServersScreen extends StatefulWidget {
  const ServersScreen({
    super.key,
    required this.manager,
    this.onChanged,
  });

  final ServerManager manager;

  /// Invoked after any mutation so the library screen can reload.
  final VoidCallback? onChanged;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  List<ServerProfile>? _servers;
  Object? _error;
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final servers = await widget.manager.list();
      final active = await widget.manager.activeServerId();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _activeId = active;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _switchTo(ServerProfile profile) async {
    await widget.manager.switchTo(serverId: profile.id);
    widget.onChanged?.call();
    await _reload();
  }

  Future<void> _delete(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('删除「${profile.displayName}」？本地镜像与凭据将一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.manager.delete(serverId: profile.id);
    widget.onChanged?.call();
    await _reload();
  }

  Future<void> _openForm([ServerProfile? existing]) async {
    final saved = await Navigator.of(context).push<ServerProfile>(
      MaterialPageRoute(
        builder: (_) => ServerFormScreen(
          manager: widget.manager,
          existing: existing,
          onSaved: (profile) => Navigator.of(context).pop(profile),
        ),
      ),
    );
    if (saved != null) {
      // Acceptance chain keeps going: switch to the just-saved server.
      await widget.manager.switchTo(serverId: saved.id);
      widget.onChanged?.call();
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        tooltip: '添加服务器',
        child: const Icon(Icons.add),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      final view = FailurePresentation.from(_error!);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 8),
              Text(view.headline, textAlign: TextAlign.center),
              if (view.detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  view.detail,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      );
    }
    final servers = _servers;
    if (servers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (servers.isEmpty) {
      return const Center(child: Text('还没有服务器 — 点右下角添加'));
    }
    return ListView.builder(
      itemCount: servers.length,
      itemBuilder: (context, index) {
        final profile = servers[index];
        final isActive = profile.id == _activeId;
        final subtitle = [
          profile.baseUrl,
          profile.lastSuccessfulConnection == null
              ? null
              : '最近连接 ${profile.lastSuccessfulConnection}',
        ].whereType<String>().join('\n');
        return ListTile(
          leading: Icon(
            isActive ? Icons.cloud_done : Icons.cloud_outlined,
            color: isActive ? Colors.green : null,
          ),
          title: Row(
            children: [
              Flexible(child: Text(profile.displayName)),
              if (isActive)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '当前',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
          subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          trailing: PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'switch':
                  _switchTo(profile);
                case 'edit':
                  _openForm(profile);
                case 'delete':
                  _delete(profile);
              }
            },
            itemBuilder: (context) => [
              if (!isActive)
                const PopupMenuItem(value: 'switch', child: Text('切换到此服务器')),
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
          onTap: isActive ? null : () => _switchTo(profile),
        );
      },
    );
  }
}