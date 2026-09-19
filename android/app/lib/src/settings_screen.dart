import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'diagnostics_screen.dart';
import 'feedback_access.dart';
import 'library_repository.dart';
import 'manual_sync_result.dart';
import 'error_presentation.dart';
import 'outbox_sheet.dart';
import 'rust_core_api.dart';
import 'server_manager.dart';
import 'servers_screen.dart';

/// App settings screen: server connection, offline Outbox queue, cache cleanup,
/// appearance/density controls, and diagnostics dashboard entry point.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    this.manager,
    this.activeServerName,
    this.initialSettings,
    this.onSettingsChanged,
    this.onServerChanged,
    this.onManualSync,
  });

  final LibraryRepository repository;
  final ServerManager? manager;
  final String? activeServerName;
  final AppSettings? initialSettings;
  final ValueChanged<AppSettings>? onSettingsChanged;
  final VoidCallback? onServerChanged;
  final Future<ManualSyncResult> Function()? onManualSync;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings = widget.initialSettings ?? const AppSettings();
  CacheStatsDto? _cacheStats;
  OutboxStatusDto? _outbox;
  bool _isCleaningCache = false;
  bool _isSyncing = false;
  bool _isSavingSettings = false;
  bool _isLoadingSettings = true;
  String? _settingsError;
  int _statsGeneration = 0;
  int _settingsReadGeneration = 0;
  Object? _settingsReadError;
  Object? _outboxError;
  Object? _cacheError;
  bool _statsLoading = true;

  bool get _canRestoreCorrupt {
    final error = _settingsReadError;
    final cause = error is AppSettingsLoadException ? error.cause : error;
    return cause is! UnsupportedAppSettingsVersion &&
        (cause is FormatException || cause is AppSettingsFormatException);
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadStats();
  }

  Future<void> _loadSettings() async {
    if (!mounted || _isSavingSettings) return;
    final generation = ++_settingsReadGeneration;
    setState(() => _isLoadingSettings = true);
    try {
      final settings = await widget.repository.loadAppSettings();
      if (!mounted || generation != _settingsReadGeneration) return;
      setState(() {
        _settings = settings;
        _settingsError = null;
        _settingsReadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _settingsReadGeneration) return;
      setState(() {
        _settingsReadError = error;
        _settingsError = '设置读取失败: $error';
      });
    } finally {
      if (mounted && generation == _settingsReadGeneration) {
        setState(() => _isLoadingSettings = false);
      }
    }
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    final generation = ++_statsGeneration;
    setState(() => _statsLoading = true);
    CacheStatsDto? cache;
    OutboxStatusDto? outbox;
    Object? cacheError;
    Object? outboxError;
    try {
      cache = await widget.repository.cacheStats();
    } catch (error) {
      cacheError = error;
    }
    try {
      outbox = await widget.repository.outboxStatus();
    } catch (error) {
      outboxError = error;
    }
    if (!mounted || generation != _statsGeneration) return;
    setState(() {
      _cacheStats = cache;
      _outbox = outbox;
      _cacheError = cacheError;
      _outboxError = outboxError;
      _statsLoading = false;
    });
  }

  Future<void> _updateSettings(AppSettings next,
      {bool forceReset = false}) async {
    if (_isSavingSettings || _isLoadingSettings) return;
    final previous = _settings;
    _settingsReadGeneration++;
    setState(() => _isSavingSettings = true);
    try {
      await widget.repository
          .saveAppSettings(next, overwriteCorrupt: forceReset);
      if (!mounted) return;
      setState(() {
        _settings = next;
        _settingsError = null;
        _settingsReadError = null;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      widget.onSettingsChanged?.call(next);
    } catch (error) {
      if (mounted) {
        setState(() => _settings = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('设置保存失败: $error'),
              action: SnackBarAction(
                  label: '重试',
                  onPressed: () =>
                      _updateSettings(next, forceReset: forceReset))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _restoreDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认设置？'),
        content: const Text('这会覆盖当前损坏的设置文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('恢复默认')),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _updateSettings(const AppSettings(), forceReset: true);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _clearCache() async {
    setState(() => _isCleaningCache = true);
    try {
      final cleaned = await widget.repository.reconcileCache();
      final prefetched = await widget.repository.clearPrefetchCache();
      final freed = (cleaned?.freedBytes.toInt() ?? 0) + prefetched;
      await _loadStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清理页面缓存，释放了 ${_formatBytes(freed)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理缓存失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCleaningCache = false);
      }
    }
  }

  Future<void> _triggerSync() async {
    setState(() => _isSyncing = true);
    try {
      if (widget.onManualSync != null) {
        final result = await widget.onManualSync!();
        if (result.status == ManualSyncStatus.notRun) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(result.message ?? '同步未执行')),
            );
          }
          return;
        }
        if (!result.isSuccess) {
          final error = result.error;
          final presentation =
              error == null ? null : FailurePresentation.from(error);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  result.message ?? presentation?.headline ?? '同步没有完成',
                ),
              ),
            );
          }
          return;
        }
      } else {
        final result = await widget.repository
            .reconcileActiveServer(trigger: 'manual_refresh');
        if (result == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('没有可用的服务器或凭据，同步未执行')),
            );
          }
          return;
        }
      }
      await _loadStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('元数据同步已完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        final presentation = FailurePresentation.from(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(presentation.headline)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  void _openOutbox() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => OutboxSheet(
        repository: widget.repository,
        initialStatus: _outbox,
        onRetry: () async {
          await widget.repository.retryFailedMutations();
          await widget.repository.uploadOutbox();
          await _loadStats();
        },
      ),
    ).then((_) => _loadStats());
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final totalCache = _cacheStats?.diskBytes.toInt() ?? 0;
    final queued = (_outbox?.pending.toInt() ?? 0) +
        (_outbox?.waiting.toInt() ?? 0) +
        (_outbox?.failed.toInt() ?? 0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          if (_settingsError != null)
            ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(_settingsError!),
              subtitle: Wrap(children: [
                TextButton(
                    onPressed: _isSavingSettings || _isLoadingSettings
                        ? null
                        : _loadSettings,
                    child: const Text('重试读取')),
                if (_canRestoreCorrupt)
                  TextButton(
                      onPressed: _isSavingSettings || _isLoadingSettings
                          ? null
                          : _restoreDefaults,
                      child: const Text('恢复默认')),
              ]),
            ),
          // Section: Server
          const _SectionHeader(title: '当前服务器'),
          if (manager != null)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(widget.activeServerName ?? '服务器管理'),
              subtitle: const Text('点击配置或切换服务器'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ServersScreen(
                      manager: manager,
                      onChanged: () {
                        widget.onServerChanged?.call();
                        _loadStats();
                      },
                    ),
                  ),
                );
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(widget.activeServerName ?? '本地 / 演示模式'),
              subtitle: const Text('未连接远程服务器'),
            ),

          const Divider(),

          // Section: Sync & Network
          const _SectionHeader(title: '同步与网络'),
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('自动同步元数据'),
            subtitle: const Text('启动及回到前台时自动对齐变更'),
            value: _settings.autoSyncMetadata,
            onChanged: (_isSavingSettings ||
                    _isLoadingSettings ||
                    _settingsError != null)
                ? null
                : (val) =>
                    _updateSettings(_settings.copyWith(autoSyncMetadata: val)),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('离线写操作队列'),
            subtitle: Text(_statsLoading
                ? '正在读取队列状态'
                : _outboxError != null
                    ? '队列状态读取失败，点击重试'
                    : _outbox == null
                        ? '队列状态暂不可用'
                        : queued > 0
                            ? '$queued 项客户端写操作待同步'
                            : '没有待上传操作'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (!_statsLoading && _outboxError == null && _outbox != null)
                if (queued > 0)
                  Badge(label: Text('$queued'))
                else
                  const Icon(Icons.check, size: 16, color: Colors.green),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ]),
            onTap: _outboxError != null ? _loadStats : _openOutbox,
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('立即手动同步'),
            subtitle: const Text('对齐最新漫画与阅读进度'),
            trailing: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _isSyncing ? null : _triggerSync,
          ),

          const Divider(),

          // Section: Storage & Cache
          const _SectionHeader(title: '存储与缓存'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('当前缓存占用'),
            trailing: Text(
              _statsLoading
                  ? '读取中'
                  : _cacheError != null
                      ? '读取失败'
                      : _cacheStats == null
                          ? '暂不可用'
                          : _formatBytes(totalCache),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.cleaning_services_outlined, color: Colors.red),
            title: const Text(
              '清理页面缓存',
              style: TextStyle(color: Colors.red),
            ),
            trailing: _isCleaningCache
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _isCleaningCache ? null : _clearCache,
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('缓存上限'),
            subtitle: const Text('超出上限时优先清理最早未阅读的预取缓存'),
            trailing: DropdownButton<int>(
              value: _settings.cacheLimitMiB,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 256, child: Text('256 MiB')),
                DropdownMenuItem(value: 512, child: Text('512 MiB')),
                DropdownMenuItem(value: 1024, child: Text('1024 MiB (1 GiB)')),
              ],
              onChanged: (_isSavingSettings ||
                      _isLoadingSettings ||
                      _settingsError != null)
                  ? null
                  : (val) {
                      if (val != null) {
                        _updateSettings(_settings.copyWith(cacheLimitMiB: val));
                      }
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '清理缓存仅清除临时页面与封面，已下载的书籍和离线文件绝不会被删除。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
            ),
          ),

          const Divider(),

          // Section: Appearance & Layout
          const _SectionHeader(title: '外观与布局'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('深浅模式'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'system', label: Text('跟随系统')),
                  ButtonSegment(value: 'light', label: Text('浅色')),
                  ButtonSegment(value: 'dark', label: Text('深色')),
                ],
                selected: {_settings.appearance},
                onSelectionChanged: (_isSavingSettings ||
                        _isLoadingSettings ||
                        _settingsError != null)
                    ? null
                    : (selected) {
                        if (selected.isNotEmpty) {
                          _updateSettings(
                              _settings.copyWith(appearance: selected.first));
                        }
                      },
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.grid_view_outlined),
            title: const Text('书架网格密度'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'compact', label: Text('紧凑')),
                  ButtonSegment(value: 'comfortable', label: Text('舒适')),
                  ButtonSegment(value: 'spacious', label: Text('宽松')),
                ],
                selected: {_settings.gridDensity},
                onSelectionChanged: (_isSavingSettings ||
                        _isLoadingSettings ||
                        _settingsError != null)
                    ? null
                    : (selected) {
                        if (selected.isNotEmpty) {
                          _updateSettings(
                              _settings.copyWith(gridDensity: selected.first));
                        }
                      },
              ),
            ),
          ),

          const Divider(),

          // Section: Diagnostics & About
          const _SectionHeader(title: '系统支持与关于'),
          // 反馈组件未接入（缺 dart-define）时作用域不存在，入口整体隐藏。
          if (FeedbackAccess.maybeOf(context) case final access?)
            ListTile(
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('问题反馈'),
              subtitle: const Text('截图并附脱敏诊断日志，向开发者反馈问题'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => access.controller.captureAndOpen(),
            ),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('系统诊断与日志'),
            subtitle: const Text('SQLite 健康状态、日志环与脱敏导出'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DiagnosticsScreen(repository: widget.repository),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('客户端版本'),
            trailing: Text(
              '1.0.0 (Release)',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
