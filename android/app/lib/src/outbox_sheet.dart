import 'package:flutter/material.dart';

import 'library_repository.dart';
import 'rust_core_api.dart';

/// Modal bottom sheet displaying the offline Outbox queue status and failure details.
class OutboxSheet extends StatefulWidget {
  const OutboxSheet({
    super.key,
    required this.repository,
    this.initialStatus,
    this.onRetry,
  });

  final LibraryRepository repository;
  final OutboxStatusDto? initialStatus;
  final Future<void> Function()? onRetry;

  @override
  State<OutboxSheet> createState() => _OutboxSheetState();
}

class _OutboxSheetState extends State<OutboxSheet> {
  OutboxStatusDto? _status;
  bool _isLoading = false;
  bool _isRetrying = false;
  String? _message;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    if (_status == null) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    try {
      final status = await widget.repository.outboxStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _message = null;
        _loadFailed = false;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = '获取写操作队列状态失败: $e';
        _loadFailed = true;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleRetry() async {
    setState(() => _isRetrying = true);
    try {
      if (widget.onRetry != null) {
        await widget.onRetry!();
      } else {
        final count = await widget.repository.retryFailedMutations();
        await widget.repository.uploadOutbox();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已将 $count 项操作重新排队并尝试上传')),
          );
        }
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _message = '重试失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isRetrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final pending = status?.pending ?? 0;
    final waiting = status?.waiting ?? 0;
    final failed = status?.failed ?? 0;
    final entries = status?.failedEntries ?? const <OutboxEntryDto>[];

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '离线写操作队列',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_message != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            // Header counters
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    title: '待上传',
                    count: pending,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: '等待退避',
                    count: waiting,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatCard(
                    title: '已失败',
                    count: failed,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (failed > 0)
              FilledButton.icon(
                onPressed: _isRetrying ? null : _handleRetry,
                icon: _isRetrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('重试失败项'),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadFailed
                      ? _QueueErrorState(onRetry: _refresh)
                      : (status == null ||
                              (pending == 0 &&
                                  waiting == 0 &&
                                  failed == 0 &&
                                  entries.isEmpty))
                          ? const _EmptyOutboxState()
                          : ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return _OutboxEntryCard(entry: entry);
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueErrorState extends StatelessWidget {
  const _QueueErrorState({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 8),
            const Text('无法读取待上传操作'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.count,
    required this.color,
  });

  final String title;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: count > 0
                  ? color
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
          ),
        ],
      ),
    );
  }
}

class _EmptyOutboxState extends StatelessWidget {
  const _EmptyOutboxState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 56,
            color: Colors.green,
          ),
          const SizedBox(height: 12),
          Text(
            '没有待上传的离线写操作',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '当前服务器的本地队列中没有待上传操作。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _OutboxEntryCard extends StatelessWidget {
  const _OutboxEntryCard({required this.entry});

  final OutboxEntryDto entry;

  String _mutationName(String type) {
    switch (type.toUpperCase()) {
      case 'READ_PROGRESS':
        return '阅读进度更新';
      case 'MARK_READ':
        return '标记已读';
      case 'MARK_UNREAD':
        return '标记未读';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: entry.state == 'failed'
              ? Colors.red.withValues(alpha: 0.3)
              : Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  entry.state == 'failed'
                      ? Icons.error_outline
                      : Icons.pending_outlined,
                  size: 16,
                  color: entry.state == 'failed' ? Colors.red : Colors.orange,
                ),
                const SizedBox(width: 6),
                Text(
                  _mutationName(entry.mutationType),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  '重试 ${entry.retryCount} 次',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '对象 ID: ${entry.entityId}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
            ),
            if (entry.lastError != null && entry.lastError!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '原因: ${entry.lastError}',
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                ),
              ),
            ],
            if (entry.nextRetryAt != null && entry.nextRetryAt!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                '下次重试: ${entry.nextRetryAt}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.secondary,
                      fontSize: 11,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
