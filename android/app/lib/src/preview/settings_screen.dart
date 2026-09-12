import 'package:flutter/material.dart';

import 'components.dart';
import 'preview_data.dart';
import 'theme.dart';

/// Application settings: server, appearance, global reader defaults, shelf
/// density, and sync/storage.
///
/// The reader defaults live here (not in the reader) because that is the rule
/// the milestone settled on: the reader edits *this series*, this screen edits
/// the default everything else follows.
class PreviewSettingsScreen extends StatelessWidget {
  const PreviewSettingsScreen({
    super.key,
    required this.servers,
    required this.settings,
    required this.overrides,
    required this.onChanged,
    required this.onOpenServers,
    required this.onOpenDiagnostics,
    required this.onClearOverrides,
  });

  final List<PreviewServer> servers;
  final PreviewGlobalSettings settings;
  final Map<String, PreviewSeriesOverride> overrides;
  final VoidCallback onChanged;
  final VoidCallback onOpenServers;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback onClearOverrides;

  @override
  Widget build(BuildContext context) {
    final active =
        servers.firstWhere((s) => s.active, orElse: () => servers.first);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: ComicTokens.spaceLg),
        children: [
          const SectionHeader(title: '服务器'),
          ListTile(
            key: const Key('settings-server'),
            leading: const Icon(Icons.dns_outlined),
            title: Text(active.name),
            subtitle: Text(active.baseUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: onOpenServers,
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
            child: Wrap(
              spacing: ComicTokens.spaceXs,
              children: [
                for (final server in servers.where((s) => s.active))
                  StatusChip(
                    label:
                        server.credentialState == 'expired' ? '凭据失效' : '凭据有效',
                    icon: server.credentialState == 'expired'
                        ? Icons.key_off
                        : Icons.verified_user,
                    tone: server.credentialState == 'expired'
                        ? StateTone.error
                        : StateTone.success,
                  ),
              ],
            ),
          ),
          const Divider(height: ComicTokens.spaceLg),
          const SectionHeader(title: '外观'),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('深色'),
            subtitle: const Text('本期固定深色，跟随系统切换不再改变主题'),
            trailing: const Icon(Icons.check),
            onTap: () =>
                _explain(context, '深色是本期唯一的主题。阅读纸张仍然可以在阅读器里选黑 / 灰 / 白。'),
          ),
          ListTile(
            leading: const Icon(Icons.stay_current_portrait),
            title: const Text('锁定竖屏'),
            subtitle: const Text('整个应用固定竖屏'),
            trailing: const Icon(Icons.lock_outline),
            onTap: () => _explain(context, '应用锁定竖屏，横屏不在本期范围内。'),
          ),
          const Divider(height: ComicTokens.spaceLg),
          const SectionHeader(
            title: '阅读默认值',
            subtitle: '阅读器里改的是单个系列；这里是全局默认',
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每页显示', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'single', label: Text('单页')),
                    ButtonSegment(value: 'double', label: Text('双页')),
                    ButtonSegment(value: 'webtoon', label: Text('条漫')),
                  ],
                  selected: {settings.mode},
                  onSelectionChanged: (values) {
                    settings.mode = values.first;
                    onChanged();
                  },
                ),
                const SizedBox(height: ComicTokens.spaceSm),
                Text('翻页方向', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ltr', label: Text('左 → 右')),
                    ButtonSegment(value: 'rtl', label: Text('右 → 左')),
                    ButtonSegment(value: 'vertical', label: Text('上下')),
                  ],
                  selected: {settings.direction},
                  onSelectionChanged: (values) {
                    settings.direction = values.first;
                    onChanged();
                  },
                ),
                const SizedBox(height: ComicTokens.spaceSm),
                Text('纸张背景', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'black', label: Text('黑')),
                    ButtonSegment(value: 'gray', label: Text('灰')),
                    ButtonSegment(value: 'white', label: Text('白')),
                  ],
                  selected: {settings.pageBackground},
                  onSelectionChanged: (values) {
                    settings.pageBackground = values.first;
                    onChanged();
                  },
                ),
              ],
            ),
          ),
          SwitchListTile(
            key: const Key('settings-volume-keys'),
            title: const Text('音量键翻页'),
            subtitle: const Text('默认关闭。开启后音量减下一页、音量加上一页；只在阅读页面生效'),
            value: settings.volumeKeysEnabled,
            onChanged: (value) {
              settings.volumeKeysEnabled = value;
              onChanged();
            },
          ),
          SwitchListTile(
            title: const Text('保持屏幕常亮'),
            subtitle: const Text('仅在阅读页面生效'),
            value: settings.keepScreenAwake,
            onChanged: (value) {
              settings.keepScreenAwake = value;
              onChanged();
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('系列覆盖'),
            subtitle: Text(
              overrides.isEmpty
                  ? '还没有任何系列单独设置，全部跟随全局'
                  : '${overrides.length} 个系列单独设置（${overrides.keys.join('、')}）',
            ),
            trailing: TextButton(
              onPressed: overrides.isEmpty ? null : onClearOverrides,
              child: const Text('全部恢复跟随全局'),
            ),
            onTap: () => _explain(
              context,
              '在阅读器里改模式或方向，只影响那个系列；这里可以把它们全部改回跟随全局。',
            ),
          ),
          const Divider(height: ComicTokens.spaceLg),
          const SectionHeader(title: '书架'),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('封面密度', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'compact', label: Text('紧凑')),
                    ButtonSegment(value: 'comfortable', label: Text('舒适')),
                    ButtonSegment(value: 'spacious', label: Text('宽松')),
                  ],
                  selected: {settings.gridDensity},
                  onSelectionChanged: (values) {
                    settings.gridDensity = values.first;
                    onChanged();
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  '新安装默认「舒适」；已有设置不会被重置。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(height: ComicTokens.spaceLg),
          const SectionHeader(title: '同步与存储'),
          SwitchListTile(
            title: const Text('自动同步元数据'),
            value: settings.autoSyncMetadata,
            onChanged: (value) {
              settings.autoSyncMetadata = value;
              onChanged();
            },
          ),
          SwitchListTile(
            title: const Text('允许蜂窝网络下载'),
            subtitle: const Text('按册授权优先；这里是全局开关'),
            value: settings.cellularAllowed,
            onChanged: (value) {
              settings.cellularAllowed = value;
              onChanged();
            },
          ),
          ListTile(
            title: const Text('阅读缓存上限'),
            subtitle: Text('${settings.cacheLimitMiB} MiB'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                value: settings.cacheLimitMiB.toDouble(),
                min: 128,
                max: 2048,
                divisions: 15,
                label: '${settings.cacheLimitMiB} MiB',
                onChanged: (value) {
                  settings.cacheLimitMiB = (value / 128).round() * 128;
                  onChanged();
                },
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理阅读缓存'),
            subtitle: const Text('不影响正式下载，也不会删除阅读进度'),
            onTap: () => _explain(context, '清缓存只清理预读的页面；下载的书和阅读进度都保留。'),
          ),
          ListTile(
            key: const Key('settings-diagnostics'),
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('诊断'),
            subtitle: const Text('同步状态、数据库、待上传队列'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onOpenDiagnostics,
          ),
          const Divider(height: ComicTokens.spaceLg),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: ComicTokens.spaceMd),
            child: Text(
              '原型说明：本页所有开关都是内存状态，重启原型会回到默认值。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  void _explain(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
