import 'package:flutter/material.dart';

import 'app_update.dart';

/// 「关于与更新」 in the settings page: the installed version, which channel
/// this device follows, and one button that asks GitHub whether there is
/// anything newer.
///
/// Opening a link is injected ([openUrl]) for two reasons: the widget then
/// needs no platform plugin, and a test can assert the exact address the
/// download button would hand the browser.
class UpdateSection extends StatefulWidget {
  const UpdateSection({
    super.key,
    required this.currentVersion,
    required this.channel,
    required this.onChannelChanged,
    required this.openUrl,
    this.checker = const UpdateChecker(),
    this.enabled = true,
  });

  /// What is actually installed (`0.3.0+4`), read from the package, never
  /// hard-coded.
  final String currentVersion;

  final UpdateChannel channel;
  final ValueChanged<UpdateChannel> onChannelChanged;
  final Future<void> Function(Uri uri) openUrl;
  final UpdateChecker checker;

  /// False while the settings file is being read or saved: the channel lives
  /// in that file, so changing it then would be written back over an older
  /// snapshot.
  final bool enabled;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

enum _Phase { idle, checking, upToDate, available, failed }

class _UpdateSectionState extends State<UpdateSection> {
  _Phase _phase = _Phase.idle;
  AppRelease? _release;

  /// An empty reading means the package metadata could not be read at all.
  /// Comparing against it would answer "there is an update" for every build.
  bool get _versionKnown => widget.currentVersion.trim().isNotEmpty;

  bool get _canCheck =>
      widget.enabled && _versionKnown && _phase != _Phase.checking;

  Future<void> _check() async {
    if (!_canCheck) return;
    setState(() {
      _phase = _Phase.checking;
      _release = null;
    });
    try {
      final result = await widget.checker.check(
        channel: widget.channel,
        currentVersion: widget.currentVersion,
      );
      if (!mounted) return;
      setState(() {
        _release = result.available;
        _phase = result.upToDate ? _Phase.upToDate : _Phase.available;
      });
    } catch (_) {
      if (!mounted) return;
      // The reason is almost always "the network or GitHub", and neither is a
      // sentence with an error object in it. The detail belongs in a log.
      setState(() => _phase = _Phase.failed);
    }
  }

  void _setChannel(UpdateChannel next) {
    if (next == widget.channel) return;
    // A result belongs to the channel it was asked on: switching channels and
    // leaving the old answer on screen would recommend the wrong build.
    setState(() {
      _phase = _Phase.idle;
      _release = null;
    });
    widget.onChannelChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = _release;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('update-current-version'),
          title: const Text('当前版本'),
          subtitle: Text(_versionKnown ? widget.currentVersion : '版本号读取失败'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<UpdateChannel>(
            key: const ValueKey('update-channel'),
            segments: const [
              ButtonSegment(
                value: UpdateChannel.release,
                label: Text('正式版'),
              ),
              ButtonSegment(
                value: UpdateChannel.preview,
                label: Text('预览版'),
              ),
            ],
            selected: {widget.channel},
            onSelectionChanged:
                widget.enabled ? (selection) => _setChannel(selection.first) : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            widget.channel == UpdateChannel.preview
                ? '预览版会收到还没正式发布的构建，可能不稳定；有新正式版时仍然优先给你正式版。'
                : '只接收正式发布的版本。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        ListTile(
          key: const ValueKey('update-check'),
          title: const Text('检查更新'),
          subtitle: Text(_subtitle()),
          trailing: _phase == _Phase.checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _canCheck ? _check : null,
        ),
        if (_phase == _Phase.upToDate)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '已经是最新版本',
              key: const ValueKey('update-up-to-date'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        if (_phase == _Phase.failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '检查没有完成，可能是网络或 GitHub 暂时不可用',
                    key: const ValueKey('update-failed'),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
                TextButton(
                  key: const ValueKey('update-retry'),
                  onPressed: _check,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        if (_phase == _Phase.available && release != null)
          Card(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.prerelease
                        ? '有新预览版 ${release.tag}'
                        : '有新版本 ${release.tag}',
                    key: const ValueKey('update-available'),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (release.publishedAt != null)
                    Text(
                      '发布于 ${release.publishedAt!.toLocal().toString().substring(0, 16)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  if (release.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      release.notes.trim(),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('update-download'),
                        onPressed: release.downloadUrl == null
                            ? null
                            : () => widget.openUrl(release.downloadUrl!),
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: Text(release.apkUrl != null ? '下载安装包' : '打开发布页'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _subtitle() {
    switch (_phase) {
      case _Phase.checking:
        return '正在问 GitHub…';
      case _Phase.available:
        return '发现新版本';
      case _Phase.upToDate:
        return '刚刚检查过';
      case _Phase.failed:
        return '上次检查没有完成';
      case _Phase.idle:
        if (!_versionKnown) return '拿不到当前版本号，检查更新暂时不可用';
        return '从 GitHub Releases 读取，只在你点的时候联网';
    }
  }
}
