import 'package:flutter/material.dart';

import 'rust/ffi/application.dart';
import 'rust/model/server_profile.dart';
import 'server_manager.dart';

/// Add/edit server form. The acceptance chain is enforced here:
/// 添加服务器 → 登录 → 验证 Komga → 获取服务器信息 → 保存 Server Profile.
/// Saving stays disabled until a connection test succeeds.
class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({
    super.key,
    required this.manager,
    required this.onSaved,
    this.existing,
  });

  final ServerManager manager;
  final ServerProfile? existing;

  /// Called with the saved profile so callers can switch to it.
  final void Function(ServerProfile profile) onSaved;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.displayName ?? 'Home');
  late final TextEditingController _url =
      TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final TextEditingController _apiKey = TextEditingController();

  ConnectionResult? _tested;
  Object? _testError;
  bool _testing = false;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testError = null;
      _tested = null;
    });
    try {
      final result = await widget.manager.testConnection(
        baseUrl: _url.text.trim(),
        apiKey: _apiKey.text,
      );
      if (!mounted) return;
      setState(() => _tested = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _testError = e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final existing = widget.existing;
      final profile = existing == null
          ? await widget.manager.add(
              displayName: _name.text.trim(),
              baseUrl: _url.text.trim(),
              apiKey: _apiKey.text,
            )
          : await widget.manager.update(
              existing: existing,
              displayName: _name.text.trim(),
              baseUrl: _url.text.trim(),
              apiKey: _apiKey.text,
            );
      if (!mounted) return;
      setState(() => _saving = false);
      // Acceptance chain: a freshly saved server becomes the active one.
      await widget.manager.switchTo(serverId: profile.id);
      widget.onSaved(profile);
    } catch (e) {
      if (!mounted) return;
      setState(() => _testError = e);
      _saving = false;
    }
  }

  bool get _canSave =>
      !_testing &&
      !_saving &&
      _tested != null &&
      _name.text.trim().isNotEmpty &&
      _url.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑服务器' : '添加服务器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '显示名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.0.69:25600',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key（X-API-Key）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _testing ? null : _testConnection,
            child: _testing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('测试连接'),
          ),
          if (_tested != null) _TestResultView(result: _tested!),
          if (_testError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '连接失败：$_testError',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_isEdit && _tested == null && _testError == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('编辑后需重新测试连接才能保存',
                  style: TextStyle(color: Colors.grey)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// Result of a successful connection test: server version + libraries.
class _TestResultView extends StatelessWidget {
  const _TestResultView({required this.result});

  final ConnectionResult result;

  @override
  Widget build(BuildContext context) {
    final version = result.serverVersion ?? '未知版本';
    final capabilities = result.capabilities.join(' · ');
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        leading: const Icon(Icons.check_circle, color: Colors.green),
        title: Text('Komga $version · ${result.libraries.length} 个库'),
        subtitle: capabilities.isEmpty ? null : Text(capabilities),
      ),
    );
  }
}