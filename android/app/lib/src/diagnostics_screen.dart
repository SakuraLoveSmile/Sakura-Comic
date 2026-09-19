import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_repository.dart';
import 'rust_core_api.dart';

/// Diagnostics dashboard displaying SQLite health, sync cursors, Outbox counters,
/// storage and ring logs, with a one-tap redacted export.
class DiagnosticsSanitizer {
  static String redactServerId(String id) {
    if (id.length <= 8) return '***';
    return '${id.substring(0, 8)}***';
  }

  static String redactString(String input) {
    var result = input;
    // Authorization header (Bearer, Basic, raw token)
    result = result.replaceAll(
      RegExp(
          r'Authorization\s*:\s*(?:Bearer\s+[A-Za-z0-9\-._~+/]+=*|Basic\s+[A-Za-z0-9+/=]+|[^\s\r\n]+)',
          caseSensitive: false),
      'Authorization: [REDACTED]',
    );
    result = result.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    result = result.replaceAll(
      RegExp(r'\bBasic\s+[A-Za-z0-9+/=]+', caseSensitive: false),
      'Basic [REDACTED]',
    );
    // Custom auth headers
    result = result.replaceAllMapped(
      RegExp(r'\b(X-API-Key|X-Auth-Token)\s*:\s*[^\s\r\n]+',
          caseSensitive: false),
      (m) => '${m[1]}: [REDACTED]',
    );
    // Embedded URL credentials (e.g., http://user:pass@host)
    result = result.replaceAllMapped(
      RegExp(r'(https?://)[^:/\s]+:[^@/\s]+@', caseSensitive: false),
      (m) => '${m[1]}[REDACTED_AUTH]@',
    );
    // URL query parameters (e.g., ?key=secret, &token=secret, ?api_key=secret)
    result = result.replaceAllMapped(
      RegExp(
          r'([?&](?:apikey|api_key|key|token|password|secret|auth)=)[^& \r\n"\x27\t]+',
          caseSensitive: false),
      (m) => '${m[1]}[REDACTED]',
    );
    // Key-value credentials (e.g., apikey: xyz, token=xyz, password: xyz)
    result = result.replaceAllMapped(
      RegExp(
          r'\b(apikey|api_key|token|password|secret|key)\s*[:=]\s*(?!\[REDACTED\])[^\s,;&"\x27]+',
          caseSensitive: false),
      (m) => '${m[1]}=[REDACTED]',
    );
    return result;
  }
}

typedef DiagnosticsScreenState = DiagnosticsSanitizer;

String redactServerId(String id) => DiagnosticsSanitizer.redactServerId(id);
String redactString(String input) => DiagnosticsSanitizer.redactString(input);

/// 脱敏诊断快照的 map 形状——剪贴板导出与反馈日志附件共用同一形状。
/// [snap] 为 null 时只导出日志段（快照字段整体缺省）。
Map<String, dynamic> redactedDiagnosticsMap(
    DiagnosticsDto? snap, List<LogRecord> logs) {
  return <String, dynamic>{
    if (snap != null) ...{
      'serverId': redactServerId(snap.serverId),
      'db': {
        'schemaVersion': snap.db.schemaVersion.toInt(),
        'integrity': snap.db.integrity,
        'journalMode': snap.db.journalMode,
        'pageSize': snap.db.pageSize.toInt(),
        'pageCount': snap.db.pageCount.toInt(),
        'freelistCount': snap.db.freelistCount.toInt(),
        'fileBytes': snap.db.fileBytes.toInt(),
        'tables': snap.db.tables
            .map((t) => {'table': t.table, 'rows': t.rows.toInt()})
            .toList(),
      },
      'auth': {
        'state': snap.auth.state,
        'at': snap.auth.at,
      },
      'outbox': {
        'pending': snap.outbox.pending.toInt(),
        'waiting': snap.outbox.waiting.toInt(),
        'failed': snap.outbox.failed.toInt(),
        'queuedRows': snap.outboxQueuedRows.toInt(),
      },
      'cache': {
        'pageBytes': snap.cache.pageBytes.toInt(),
        'prefetchBytes': snap.cache.prefetchBytes.toInt(),
        'downloadBytes': snap.cache.downloadBytes.toInt(),
        'diskBytes': snap.cache.diskBytes.toInt(),
        'memoryBytes': snap.cache.memoryBytes.toInt(),
        'ledgerBytes': snap.cache.ledgerBytes.toInt(),
      },
      'storage': {
        'cacheTotalBytes': snap.storage.cacheTotalBytes.toInt(),
        'downloadBytes': snap.storage.downloadBytes.toInt(),
        'bookCount': snap.storage.bookCount.toInt(),
        'freeVolumeBytes': snap.storage.freeVolumeBytes.toInt(),
      },
      'sync': snap.sync_
          .map((s) => {
                'entityType': s.entityType,
                'status': s.syncStatus,
                'cursor': s.syncCursor == null ? 'none' : '[REDACTED_CURSOR]',
                'lastSyncAt': s.lastSyncAt,
                'lastError':
                    s.lastError == null ? null : redactString(s.lastError!),
              })
          .toList(),
    },
    'logs': logs
        .take(50)
        .map((l) => {
              'level': l.level,
              'target': l.target,
              'at': l.at,
              'message': l.message,
            })
        .toList(),
  };
}

/// 现场拉取快照与近期日志并产出脱敏 JSON，供反馈组件作日志附件上报。
/// 单项失败（快照不可用、日志环为空）只让对应段缺省，不整单失败。
Future<String> buildRedactedDiagnosticsExport(
    LibraryRepository repository) async {
  DiagnosticsDto? snap;
  List<LogRecord> logs = const [];
  try {
    snap = await repository.diagnosticsSnapshot();
  } catch (_) {/* 快照缺省 */}
  try {
    logs = (await repository.diagnosticsLogs(limit: 200))
        .map((l) => LogRecord(
              level: l.level,
              target: l.target,
              at: l.at,
              message: redactString(l.message),
            ))
        .toList();
  } catch (_) {/* 日志段缺省 */}
  return const JsonEncoder.withIndent('  ')
      .convert(redactedDiagnosticsMap(snap, logs));
}

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.repository,
  });

  final LibraryRepository repository;

  static String redactServerId(String id) =>
      DiagnosticsSanitizer.redactServerId(id);
  static String redactString(String input) =>
      DiagnosticsSanitizer.redactString(input);

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  DiagnosticsDto? _snapshot;
  List<LogRecord> _logs = const [];
  String _logFilter = 'all';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.repository.diagnosticsSnapshot();
      final logs = await widget.repository.diagnosticsLogs(
        limit: 200,
        minLevel: _logFilter == 'all' ? '' : _logFilter,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _logs = logs
            .map((l) => LogRecord(
                  level: l.level,
                  target: l.target,
                  at: l.at,
                  message: redactString(l.message),
                ))
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
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

  void _copyRedactedExport() {
    final snap = _snapshot;
    if (snap == null) return;

    final jsonStr = const JsonEncoder.withIndent('  ')
        .convert(redactedDiagnosticsMap(snap, _logs));
    Clipboard.setData(ClipboardData(text: jsonStr));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制脱敏诊断快照到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('系统诊断与日志'),
        actions: [
          if (_snapshot != null)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: '复制脱敏诊断报告',
              onPressed: _copyRedactedExport,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在读取系统诊断快照...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('读取诊断快照失败: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadData, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final snap = _snapshot;
    if (snap == null) {
      return const Center(child: Text('当前环境无可用诊断数据 (Stub 模式)'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildDatabaseCard(snap),
        const SizedBox(height: 12),
        _buildAuthSyncCard(snap),
        const SizedBox(height: 12),
        _buildOutboxCard(snap),
        const SizedBox(height: 12),
        _buildStorageCard(snap),
        const SizedBox(height: 12),
        _buildLogCard(snap),
      ],
    );
  }

  Widget _buildDatabaseCard(DiagnosticsDto snap) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地数据库 (SQLite)',
                style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _infoRow('模式', snap.db.journalMode.toUpperCase()),
            _infoRow('完整性校验', snap.db.integrity,
                isOk: snap.db.integrity.toLowerCase() == 'ok'),
            _infoRow('Schema 版本', '${snap.db.schemaVersion}'),
            _infoRow('主库文件大小', _formatBytes(snap.db.fileBytes.toInt())),
            const SizedBox(height: 8),
            Text('数据表行数：', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: snap.db.tables.map((t) {
                return Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('${t.table}: ${t.rows}'),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthSyncCard(DiagnosticsDto snap) {
    String authDesc;
    bool isOk = false;
    switch (snap.auth.state.toLowerCase()) {
      case 'valid':
        authDesc = '有效';
        isOk = true;
        break;
      case 'expired':
        authDesc = '已失效 (需要重新认证)';
        break;
      default:
        authDesc = '未确定 / 从未连通';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('认证与同步状态', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _infoRow('服务器 ID', snap.serverId),
            _infoRow('凭据状态', authDesc, isOk: isOk),
            if (snap.auth.at.isNotEmpty) _infoRow('凭据更新时间', snap.auth.at),
            const SizedBox(height: 8),
            Text('各实体同步游标：', style: Theme.of(context).textTheme.bodySmall),
            ...snap.sync_.map((s) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(s.entityType,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text(
                      s.syncCursor == null ? '全量完成' : '游标: ${s.syncCursor}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildOutboxCard(DiagnosticsDto snap) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('写操作队列 (Outbox)',
                style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _infoRow('待上传 (Pending)', '${snap.outbox.pending}'),
            _infoRow('等待退避 (Waiting)', '${snap.outbox.waiting}'),
            _infoRow('已失败 (Failed)', '${snap.outbox.failed}',
                isOk: snap.outbox.failed.toInt() == 0),
            _infoRow('总积压 SQL 行数', '${snap.outboxQueuedRows}'),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageCard(DiagnosticsDto snap) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('存储与缓存', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _infoRow('磁盘缓存总计', _formatBytes(snap.cache.diskBytes.toInt())),
            _infoRow('页面缓存', _formatBytes(snap.cache.pageBytes.toInt())),
            _infoRow('预拉取缓存', _formatBytes(snap.cache.prefetchBytes.toInt())),
            _infoRow('内存缓存', _formatBytes(snap.cache.memoryBytes.toInt())),
            _infoRow('离线已下载书籍',
                '${snap.storage.bookCount} 本 (${_formatBytes(snap.storage.downloadBytes.toInt())})'),
            if (snap.storage.freeVolumeBytes.toInt() > 0)
              _infoRow(
                  '磁盘可用空间', _formatBytes(snap.storage.freeVolumeBytes.toInt())),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard(DiagnosticsDto snap) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('核心日志环 (Log Ring)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                DropdownButton<String>(
                  value: _logFilter,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部级别')),
                    DropdownMenuItem(value: 'error', child: Text('仅 Error')),
                    DropdownMenuItem(value: 'warn', child: Text('Warn 及以上')),
                    DropdownMenuItem(value: 'info', child: Text('Info 及以上')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _logFilter = val);
                      _loadData();
                    }
                  },
                ),
              ],
            ),
            const Divider(),
            _infoRow(
                '容量 / 保留', '${snap.log.capacity} / ${snap.log.retained} 条'),
            _infoRow('错误 / 警告 / 信息',
                '${snap.log.errors} / ${snap.log.warnings} / ${snap.log.info}'),
            const SizedBox(height: 8),
            Container(
              height: 240,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _logs.isEmpty
                  ? const Center(child: Text('暂无匹配的日志记录'))
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        Color levelColor = Colors.grey;
                        if (log.level.toLowerCase() == 'error') {
                          levelColor = Colors.red;
                        }
                        if (log.level.toLowerCase() == 'warn') {
                          levelColor = Colors.orange;
                        }
                        if (log.level.toLowerCase() == 'info') {
                          levelColor = Colors.blue;
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    log.level.toUpperCase(),
                                    style: TextStyle(
                                      color: levelColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    log.target,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(fontSize: 10),
                                  ),
                                  const Spacer(),
                                  Text(
                                    log.at,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(fontSize: 9),
                                  ),
                                ],
                              ),
                              Text(
                                log.message,
                                style: const TextStyle(
                                    fontSize: 12, fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool? isOk}) {
    Color? color;
    if (isOk != null) {
      color = isOk ? Colors.green : Colors.red;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
          ),
        ],
      ),
    );
  }
}
