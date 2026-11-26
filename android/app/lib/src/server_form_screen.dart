import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/material.dart';

import 'error_presentation.dart';
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

  /// What the successful test ran against (地址 + 用的是哪一个 Key).
  ///
  /// Editing either field afterwards has to send the user back through
  /// 测试连接: saving a profile nobody proved works is how a server ends up in
  /// the list that the app can never open.
  String? _testedFingerprint;

  /// The key already in the keystore, read once for an edit where the field is
  /// left blank. Retyping a working key just to rename a server is not a step
  /// worth asking for.
  String? _storedKey;

  /// Shown as the key field's error when 测试连接 / 保存 had no key at all.
  bool _keyMissing = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _url.addListener(_dropStaleTest);
    _apiKey.addListener(_dropStaleTest);
  }

  /// The key a test or a save would use right now: what is typed, or the one
  /// already saved when an existing profile's field is left blank.
  Future<String> _resolveKey() async {
    if (_apiKey.text.isNotEmpty) return _apiKey.text;
    if (!_isEdit) return '';
    final ref = widget.existing?.credentialRef;
    if (ref == null) return '';
    _storedKey ??= await widget.manager.readSecret(ref);
    return _storedKey ?? '';
  }

  /// Cheap identity of "which URL, which key" — the saved key is one identity
  /// of its own so a blank field can be compared without reading the keystore.
  String _fingerprint() {
    final key = _apiKey.text.isEmpty && _isEdit ? 'saved' : 'typed:${_apiKey.text}';
    return '${_url.text.trim()}\u0000$key';
  }

  void _dropStaleTest() {
    if (_tested == null && _testError == null && !_keyMissing) return;
    if (_testedFingerprint == _fingerprint()) return;
    setState(() {
      _tested = null;
      _testError = null;
      _testedFingerprint = null;
      _keyMissing = false;
    });
  }

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
      _testedFingerprint = null;
      _keyMissing = false;
    });
    try {
      final key = await _resolveKey();
      if (key.trim().isEmpty) {
        if (mounted) setState(() => _keyMissing = true);
        return;
      }
      final result = await widget.manager.testConnection(
        baseUrl: _url.text.trim(),
        apiKey: key,
      );
      if (!mounted) return;
      setState(() {
        _tested = result;
        _testedFingerprint = _fingerprint();
      });
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
      // Same key the successful test used: on an edit where the field was left
      // blank that is the one already in the keystore.
      final key = await _resolveKey();
      if (key.trim().isEmpty) {
        if (mounted) {
          setState(() {
            _keyMissing = true;
            _saving = false;
          });
        }
        return;
      }
      final profile = existing == null
          ? await widget.manager.add(
              displayName: _name.text.trim(),
              baseUrl: _url.text.trim(),
              apiKey: key,
            )
          : await widget.manager.update(
              existing: existing,
              displayName: _name.text.trim(),
              baseUrl: _url.text.trim(),
              apiKey: key,
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
          // 显示名称与服务器地址同属账号标识：截图时一并遮挡。
          FeedbackCaptureMask(
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '显示名称',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FeedbackCaptureMask(
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: '例如 http://komga.example.com:25600',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _url,
            builder: (context, value, _) {
              if (!value.text.trim().toLowerCase().startsWith('http://')) {
                return const SizedBox.shrink();
              }
              return Container(
                key: const ValueKey('plaintext-http-warning'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade800),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.amber.shade900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '当前连接为明文 HTTP，账号密码与阅读记录在局域网/公共网络可能被窃听，建议尽可能配置 HTTPS',
                        style: TextStyle(
                          color: Colors.amber.shade900,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          // 服务器凭据：截图时整块被中性遮罩覆盖，最终图片中不可读。
          FeedbackCaptureMask(
            child: TextField(
              controller: _apiKey,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API Key（X-API-Key）',
                border: const OutlineInputBorder(),
                errorText: _keyMissing ? '请先填写 API Key' : null,
              ),
            ),
          ),
          // Where the key comes from is the one thing a first-time user cannot
          // guess, and it is not the password they log into Komga with.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _isEdit
                  ? '留空表示继续使用已保存的 API Key；换 Key 时直接粘贴新的。'
                  : '在 Komga 网页版点右上角头像 → 我的账户 → API Keys 生成一个 Key 粘贴到这里；它不是你的登录密码。',
              key: const ValueKey('api-key-help'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
          // 原始错误文本可能回显服务器地址或凭据：整块遮挡。
          if (_testError != null)
            FeedbackCaptureMask(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _TestErrorView(error: _testError!),
              ),
            ),
          if (_isEdit && _tested == null && _testError == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child:
                  Text('编辑后需重新测试连接才能保存', style: TextStyle(color: Colors.grey)),
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

/// A failed connection test, in the user's words: headline from the shared
/// code map ([FailurePresentation]); the raw text is demoted to a detail line,
/// never the headline.
class _TestErrorView extends StatelessWidget {
  const _TestErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final view = FailurePresentation.from(error);
    final theme = Theme.of(context);
    final errorStyle =
        theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.error);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          view.headline,
          key: const ValueKey('test-error-headline'),
          style: errorStyle,
        ),
        if (view.detail.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            view.detail,
            key: const ValueKey('test-error-detail'),
            style: theme.textTheme.bodySmall!
                .copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}
