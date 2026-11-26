import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/app_update.dart';
import 'package:comic_app/src/update_section.dart';

Map<String, Object?> _release(String tag,
        {bool prerelease = false, List<String> assets = const []}) =>
    {
      'tag_name': tag,
      'name': tag,
      'prerelease': prerelease,
      'draft': false,
      'html_url': 'https://github.com/SakuraLoveSmile/Sakura-Comic/releases/tag/$tag',
      'published_at': '2026-11-26T10:00:00Z',
      'body': '两支修复 + 更新检查',
      'assets': [
        for (final name in assets)
          {
            'name': name,
            'browser_download_url':
                'https://github.com/SakuraLoveSmile/Sakura-Comic/releases/download/$tag/$name',
          },
      ],
    };

/// The settings page owns the channel: the section is controlled, so the
/// harness has to hold that state the way the real page does.
class _Host extends StatefulWidget {
  const _Host({
    required this.checker,
    this.initialChannel = UpdateChannel.release,
    this.onChannelChanged,
    this.opened,
  });

  final UpdateChecker checker;
  final UpdateChannel initialChannel;
  final ValueChanged<UpdateChannel>? onChannelChanged;
  final List<Uri>? opened;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late UpdateChannel _channel = widget.initialChannel;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              UpdateSection(
                currentVersion: '0.2.0+3',
                channel: _channel,
                onChannelChanged: (next) {
                  widget.onChannelChanged?.call(next);
                  setState(() => _channel = next);
                },
                checker: widget.checker,
                openUrl: (uri) async => widget.opened?.add(uri),
              ),
            ],
          ),
        ),
      );
}

void main() {
  Future<void> pumpSection(
    WidgetTester tester, {
    required UpdateChecker checker,
    UpdateChannel channel = UpdateChannel.release,
    ValueChanged<UpdateChannel>? onChannelChanged,
    List<Uri>? opened,
  }) =>
      tester.pumpWidget(_Host(
        checker: checker,
        initialChannel: channel,
        onChannelChanged: onChannelChanged,
        opened: opened,
      ));

  testWidgets('a newer release is offered with the phone\'s APK', (tester) async {
    final opened = <Uri>[];
    await pumpSection(
      tester,
      opened: opened,
      checker: UpdateChecker(
        fetch: (_) async => jsonEncode([
          _release('v0.3.0', assets: const [
            'app-armeabi-v7a-release.apk',
            'app-arm64-v8a-release.apk',
          ]),
        ]),
      ),
    );

    expect(find.text('0.2.0+3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();

    expect(find.text('有新版本 v0.3.0'), findsOneWidget);
    expect(find.textContaining('两支修复'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), endsWith('app-arm64-v8a-release.apk'));
  });

  testWidgets('the newest build says so instead of inventing an update',
      (tester) async {
    await pumpSection(
      tester,
      checker: UpdateChecker(
          fetch: (_) async => jsonEncode([_release('v0.2.0')])),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('update-up-to-date')), findsOneWidget);
    expect(find.byKey(const ValueKey('update-download')), findsNothing);
  });

  testWidgets('a failed check offers a retry, not a stack trace', (tester) async {
    await pumpSection(
      tester,
      checker: UpdateChecker(
          fetch: (_) async => throw const FormatException('connection refused')),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('update-failed')), findsOneWidget);
    expect(find.byKey(const ValueKey('update-retry')), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
  });

  testWidgets('switching channel drops the answer that belonged to the old one',
      (tester) async {
    final asked = <UpdateChannel>[];
    await pumpSection(
      tester,
      onChannelChanged: asked.add,
      checker: UpdateChecker(
          fetch: (_) async => jsonEncode([_release('v0.3.0')])),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    expect(find.text('有新版本 v0.3.0'), findsOneWidget);

    await tester.tap(find.text('预览版'));
    await tester.pumpAndSettle();
    expect(asked, [UpdateChannel.preview]);
    expect(find.text('有新版本 v0.3.0'), findsNothing,
        reason: 'a release answer must not survive a channel switch');
    expect(find.textContaining('预览版会收到'), findsOneWidget);
  });

  testWidgets('a release without an APK opens its page instead', (tester) async {
    final opened = <Uri>[];
    await pumpSection(
      tester,
      opened: opened,
      checker: UpdateChecker(
          fetch: (_) async => jsonEncode([_release('v0.3.0')])),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();

    expect(find.text('打开发布页'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), contains('/releases/tag/v0.3.0'));
  });
}
