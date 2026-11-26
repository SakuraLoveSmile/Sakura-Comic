import 'dart:convert';
import 'dart:io';

import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/app_settings.dart';
import 'package:comic_app/src/feedback_access.dart';
import 'package:comic_app/src/feedback_appearance.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/settings_screen.dart';

/// 宿主托管的五项反馈外观：存盘容错、真持久化，以及设置页上的改选落点。
///
/// 组件面板在 `hideSettings: true` 下只剩服务器设置，这五项的唯一入口是
/// 本应用设置页，所以「能改 / 能存 / 重进能读回」都在这里钉住。
void main() {
  test('老设置文件没有五项字段时回落默认值', () {
    final settings = AppSettings.decode(jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'appearance': 'dark',
    }));
    expect(settings.appearance, 'dark');
    expect(settings.feedbackLauncherStyle, 'orb');
    expect(settings.feedbackOrbIdleStyle, 'handle');
    expect(settings.feedbackWakeGestures, <String>['two-finger-hold']);
    expect(settings.feedbackOrbEntrance, 'bead');
    expect(settings.feedbackWakeVisual, 'ripple');
  });

  test('未知字段被忽略，五项里的未知值回落默认，未知手势被丢掉', () {
    final settings = AppSettings.decode(jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'autoSyncMetadata': false,
      'feedbackLauncherStyle': 'tab',
      'feedbackOrbIdleStyle': 'floating',
      'feedbackWakeGestures': <String>['three-finger-swipe-up', 'four-finger-roll'],
      'feedbackOrbEntrance': 'sparkle',
      'feedbackWakeVisual': 'laser',
      'updateChannelFromTheFuture': 'beta',
    }));
    expect(settings.autoSyncMetadata, isFalse);
    expect(settings.feedbackLauncherStyle, 'orb');
    expect(settings.feedbackOrbIdleStyle, 'handle');
    expect(settings.feedbackWakeGestures, <String>['three-finger-swipe-up']);
    expect(settings.feedbackOrbEntrance, 'bead');
    expect(settings.feedbackWakeVisual, 'ripple');
  });

  test('显式空的手势集合是「全关」，不是「缺字段」', () {
    final off = AppSettings.decode(jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'feedbackWakeGestures': <String>[],
    }));
    expect(off.feedbackWakeGestures, isEmpty);
    // 存盘再读回仍然是空（不被打回默认）。
    final again = AppSettings.decode(off.encode());
    expect(again.feedbackWakeGestures, isEmpty);
  });

  test('五项存盘后新实例读回同一份（退出重进仍生效）', () async {
    final directory = Directory.systemTemp.createTempSync('comic-feedback-look-');
    addTearDown(() => directory.delete(recursive: true));
    final dbPath = '${directory.path}/comic.sqlite';
    const settings = AppSettings(
      feedbackLauncherStyle: 'beam',
      feedbackOrbIdleStyle: 'edge',
      feedbackWakeGestures: <String>[
        'three-finger-swipe-up',
        'two-finger-double-tap',
      ],
      feedbackOrbEntrance: 'drop',
      feedbackWakeVisual: 'aurora',
    );
    await RustLibraryRepository(dbPath: dbPath).saveAppSettings(settings);

    final reopened =
        await RustLibraryRepository(dbPath: dbPath).loadAppSettings();
    expect(reopened.feedbackLauncherStyle, 'beam');
    expect(reopened.feedbackOrbIdleStyle, 'edge');
    expect(reopened.feedbackWakeGestures,
        <String>['three-finger-swipe-up', 'two-finger-double-tap']);
    expect(reopened.feedbackOrbEntrance, 'drop');
    expect(reopened.feedbackWakeVisual, 'aurora');
    // 读回来的值换成组件枚举时要对得上（设置页 → 组件这条路）。
    final appearance = FeedbackHostAppearance.fromSettings(reopened);
    expect(appearance.launcherStyle, FeedbackLauncherStyle.beam);
    expect(appearance.orbIdleStyle, FeedbackOrbIdleStyle.edge);
    expect(appearance.wakeGestures, <FeedbackWakeGesture>{
      FeedbackWakeGesture.threeFingerSwipeUp,
      FeedbackWakeGesture.twoFingerDoubleTap,
    });
    expect(appearance.orbEntrance, FeedbackOrbEntrance.drop);
    expect(appearance.wakeVisual, FeedbackWakeVisual.aurora);
  });

  testWidgets('设置页的反馈外观小节能改五项，保存后重进读回同一份', (tester) async {
    final repository = _SettingsRepository();
    final feedback = FeedbackController();
    final readerDepth = ValueNotifier<int>(0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      feedback.dispose();
      readerDepth.dispose();
    });

    // 与生产接线一致：FeedbackAccess 在 MaterialApp 外侧（组件外壳里）。
    Future<void> pumpSettings() async {
      await tester.pumpWidget(FeedbackAccess(
        controller: feedback,
        readerDepth: readerDepth,
        child: MaterialApp(home: SettingsScreen(repository: repository)),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('反馈外观'), 240);
    }

    // 每一项都在长列表里，先滚到可见再点。
    Future<void> reveal(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    await pumpSettings();
    expect(find.text('反馈外观'), findsOneWidget);

    // 入口样式：灵感球 → 光束唤醒。
    await reveal(find.byKey(const Key('feedback-appearance-launcher-style')));
    await tester.tap(find.descendant(
      of: find.byKey(const Key('feedback-appearance-launcher-style')),
      matching: find.text('光束唤醒'),
    ));
    await tester.pumpAndSettle();
    expect(repository.saved.feedbackLauncherStyle, 'beam');

    // 灵感球待机样式：小把手 → 球体贴边。
    await reveal(find.byKey(const Key('feedback-appearance-orb-idle')));
    await tester.tap(find.descendant(
      of: find.byKey(const Key('feedback-appearance-orb-idle')),
      matching: find.text('球体贴边'),
    ));
    await tester.pumpAndSettle();
    expect(repository.saved.feedbackOrbIdleStyle, 'edge');

    // 唤醒方式：默认只有双指长按，加上双指双击。
    await reveal(
        find.byKey(const Key('feedback-appearance-wake-two-finger-double-tap')));
    await tester.tap(find.byKey(
        const Key('feedback-appearance-wake-two-finger-double-tap')));
    await tester.pumpAndSettle();
    expect(repository.saved.feedbackWakeGestures,
        <String>['two-finger-hold', 'two-finger-double-tap']);

    // 唤醒效果：七种入场动画里改选「牵丝成滴」。
    await reveal(find.byKey(const Key('feedback-appearance-orb-entrance')));
    await tester.tap(find.byKey(const Key('feedback-appearance-orb-entrance')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('牵丝成滴').last);
    await tester.pumpAndSettle();
    expect(repository.saved.feedbackOrbEntrance, 'drop');

    // 唤醒动效：水波纹 → 波光。
    await reveal(find.byKey(const Key('feedback-appearance-wake-visual')));
    await tester.tap(find.descendant(
      of: find.byKey(const Key('feedback-appearance-wake-visual')),
      matching: find.text('波光'),
    ));
    await tester.pumpAndSettle();
    expect(repository.saved.feedbackWakeVisual, 'aurora');

    // 退出重进：重新挂一个设置页，五项仍是刚才改的值（读的是落盘的设置）。
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSettings();

    await reveal(find.byKey(const Key('feedback-appearance-launcher-style')));
    final launcherStyle = tester.widget<SegmentedButton<String>>(
        find.byKey(const Key('feedback-appearance-launcher-style')));
    expect(launcherStyle.selected, <String>{'beam'});

    await reveal(find.byKey(const Key('feedback-appearance-orb-idle')));
    final orbIdle = tester.widget<SegmentedButton<String>>(
        find.byKey(const Key('feedback-appearance-orb-idle')));
    expect(orbIdle.selected, <String>{'edge'});

    await reveal(
        find.byKey(const Key('feedback-appearance-wake-two-finger-double-tap')));
    final doubleTap = tester.widget<CheckboxListTile>(find.byKey(
        const Key('feedback-appearance-wake-two-finger-double-tap')));
    expect(doubleTap.value, isTrue);

    await reveal(find.byKey(const Key('feedback-appearance-orb-entrance')));
    final entrance = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('feedback-appearance-orb-entrance')));
    expect(entrance.value, 'drop');

    await reveal(find.byKey(const Key('feedback-appearance-wake-visual')));
    final wakeVisual = tester.widget<SegmentedButton<String>>(
        find.byKey(const Key('feedback-appearance-wake-visual')));
    expect(wakeVisual.selected, <String>{'aurora'});
  });

  testWidgets('未接入反馈时设置页不出现反馈外观小节', (tester) async {
    final repository = _SettingsRepository();
    await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(repository: repository)));
    await tester.pumpAndSettle();
    // 版本号那一行已经挪进「更新」小节，滚到本节末尾的小标题即可；
    // 反馈外观小节在它上面，同一屏内。
    await tester.scrollUntilVisible(find.text('系统支持与关于'), 240);
    expect(find.text('反馈外观'), findsNothing);
    expect(find.text('入口样式'), findsNothing);
  });
}

/// 只关心设置读写的仓库：保存后能读回，并留下最后一次保存的快照。
class _SettingsRepository extends StubLibraryRepository {
  AppSettings saved = const AppSettings();

  @override
  Future<AppSettings> loadAppSettings() async => saved;

  @override
  Future<void> saveAppSettings(AppSettings settings,
      {bool overwriteCorrupt = false}) async {
    saved = settings;
  }
}
