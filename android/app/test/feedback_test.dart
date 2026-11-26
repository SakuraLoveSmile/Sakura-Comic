import 'dart:async';
import 'dart:convert';

import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/main.dart' show buildFeedbackShell;
import 'package:comic_app/src/app_settings.dart';
import 'package:comic_app/src/auth_store.dart';
import 'package:comic_app/src/diagnostics_screen.dart'
    show buildRedactedDiagnosticsExport;
import 'package:comic_app/src/feedback_access.dart';
import 'package:comic_app/src/reader_api.dart';
import 'package:comic_app/src/reader_controller.dart';
import 'package:comic_app/src/reader_screen.dart';
import 'package:comic_app/src/rust/diagnostics/log.dart' show LogRecord;
import 'package:comic_app/src/rust/ffi/application.dart' show ConnectionResult;
import 'package:comic_app/src/server_form_screen.dart';
import 'package:comic_app/src/server_manager.dart';
import 'package:comic_app/src/settings_screen.dart';
import 'package:comic_app/src/library_repository.dart';

import 'fakes.dart';

/// 反馈组件接入的宿主侧契约：入口、悬浮球显隐、返回键、遮挡与日志附件。
/// 组件自身行为由上游包测试覆盖；这里只钉宿主接线。
void main() {
  /// 把宿主页面挂进反馈作用域（等价于组件已配置 dart-define 的运行态）。
  /// 返回 (controller, readerDepth)；teardown 先卸载整棵树再释放资源——
  /// ReaderScreen.dispose 会向活的 readerDepth 减计数，顺序不能反。
  Future<({FeedbackController feedback, ValueNotifier<int> readerDepth})>
      pumpWithAccess(
    WidgetTester tester,
    Widget child,
  ) async {
    final feedback = FeedbackController();
    final readerDepth = ValueNotifier<int>(0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      feedback.dispose();
      readerDepth.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: FeedbackAccess(
        controller: feedback,
        readerDepth: readerDepth,
        child: child,
      ),
    ));
    return (feedback: feedback, readerDepth: readerDepth);
  }

  /// 按真实接线整树挂起：MaterialApp + 返回键守卫 + 反馈外壳。
  ///
  /// [injectTestStores] 为 true 时换掉上游的 @visibleForTesting 仓库（内存
  /// 令牌 / 偏好仓库），让打开面板的用例不必等插件通道超时；为 false 时走
  /// 生产路径的组件构造——断言宿主托管值这类接线必须用生产路径。
  Future<
      ({
        FeedbackController feedback,
        ValueNotifier<int> readerDepth,
        ValueNotifier<AppSettings> settings,
        List<AppSettings> appearanceChanges,
      })> pumpFeedbackApp(
    WidgetTester tester, {
    required Widget child,
    String? appVersion,
    AppSettings initialSettings = const AppSettings(),
    FeedbackLogProvider? logProvider,
    bool injectTestStores = true,
  }) async {
    final feedback = FeedbackController();
    final readerDepth = ValueNotifier<int>(0);
    final settings = ValueNotifier<AppSettings>(initialSettings);
    final version = ValueNotifier<String?>(appVersion);
    final appearanceChanges = <AppSettings>[];
    final guard = FeedbackBackGuard(controller: feedback)..attach();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      guard.dispose();
      feedback.dispose();
      readerDepth.dispose();
      settings.dispose();
      version.dispose();
    });
    // 组件挂在 MaterialApp 外侧（与生产接线一致），组件外壳的返回处理先于
    // WidgetsApp，面板打开时的返回因此会先问「放弃这次反馈？」。
    await tester.pumpWidget(buildFeedbackShell(
      apiBase: 'https://feedback.example.com',
      appId: 'comic',
      appName: 'Comic',
      controller: feedback,
      appVersion: version,
      readerDepth: readerDepth,
      settings: settings,
      onFeedbackAppearanceChanged: appearanceChanges.add,
      logProvider: logProvider,
      feedbackWidgetBuilder: injectTestStores
          ? ({
              required context,
              required config,
              required controller,
              required appearance,
              required onAppearanceChanged,
              required child,
            }) =>
              FeedbackWidget(
                config: config,
                controller: controller,
                launcherStyle: appearance.launcherStyle,
                orbIdleStyle: appearance.orbIdleStyle,
                wakeGestures: appearance.wakeGestures,
                orbEntrance: appearance.orbEntrance,
                wakeVisual: appearance.wakeVisual,
                onLauncherStyleChanged: (style) => onAppearanceChanged(
                    appearance.copyWith(launcherStyle: style)),
                hideSettings: true,
                tokenStoreFactory: (_) => MemoryTokenStore(),
                serverPrefStore: MemoryServerPrefStore(),
                child: child,
              )
          : null,
      child: MaterialApp(
        navigatorObservers: [guard],
        home: child,
      ),
    ));
    return (
      feedback: feedback,
      readerDepth: readerDepth,
      settings: settings,
      appearanceChanges: appearanceChanges,
    );
  }

  testWidgets('问题反馈入口只存在于已接入的作用域内', (tester) async {
    final repo = PagingFakeRepository(const []);

    // 无作用域（未配置 dart-define 的等价物）：入口隐藏。
    await tester
        .pumpWidget(MaterialApp(home: SettingsScreen(repository: repo)));
    await tester.pumpAndSettle();
    // 版本号那一行已经挪进「更新」小节，滚到本节末尾的小标题即可；
    // 反馈外观小节在它上面，同一屏内。
    await tester.scrollUntilVisible(find.text('系统支持与关于'), 200);
    expect(find.text('问题反馈'), findsNothing);

    final env = await pumpWithAccess(
        tester, SettingsScreen(repository: repo));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('问题反馈'), 200);
    expect(find.text('问题反馈'), findsOneWidget);

    // 与悬浮球同一路径：captureAndOpen 呼出面板。
    await tester.tap(find.text('问题反馈'));
    await tester.pump();
    expect(env.feedback.isOpen, isTrue);
  });

  testWidgets('阅读器登记阅读态：悬浮球计数随进入/退出增减', (tester) async {
    final readerDepth = ValueNotifier<int>(0);
    final feedback = FeedbackController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      feedback.dispose();
      readerDepth.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: FeedbackAccess(
        controller: feedback,
        readerDepth: readerDepth,
        child: ReaderScreen(
          controller: ReaderController(api: InMemoryReaderApi(pageCount: 3)),
        ),
      ),
    ));
    await tester.pump();
    expect(readerDepth.value, 1);

    // 离开阅读器（卸载）后计数归零——悬浮球恢复。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(readerDepth.value, 0);
  });

  testWidgets('阅读设置菜单的「反馈当前页面」在菜单关闭后截图呼出',
      (tester) async {
    // 菜单项在底部页里偏下：把测试视口加高让其在屏内。
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);

    final env = await pumpWithAccess(
      tester,
      ReaderScreen(
        controller: ReaderController(api: InMemoryReaderApi(pageCount: 3)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 阅读器默认沉浸：先点中间把顶栏叫出来，设置入口在顶栏上。
    // 这条用例测的是反馈截图流程，与工具栏显隐无关，所以补这一步而不是改断言。
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('反馈当前页面'), findsOneWidget);

    await tester.tap(find.text('反馈当前页面'));
    // 菜单需要先收起（动画完成）才会触发截图呼出。
    await tester.pumpAndSettle();
    expect(env.feedback.isOpen, isTrue);
  });

  testWidgets('真机回归：路由推入阅读器隐藏悬浮球，退出恢复', (tester) async {
    // 阅读器必须作为被 push 的路由进入真实导航结构：推入帧内对
    // readerDepth 的同步通知会被内层 Navigator 的 buildScope 吞掉，
    // 外层外壳收不到重建信号——本用例钉死「推迟登记」的修复。
    await pumpFeedbackApp(
      tester,
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ReaderScreen(
                controller:
                    ReaderController(api: InMemoryReaderApi(pageCount: 3)),
              ),
            ),
          ),
          child: const Text('open-reader'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final orb = find.byKey(const Key('feedback-orb'));
    expect(orb, findsOneWidget);

    await tester.tap(find.text('open-reader'));
    await tester.pumpAndSettle();
    expect(orb, findsNothing);

    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
    expect(orb, findsOneWidget);
  });

  testWidgets('外壳：阅读中隐藏悬浮球，返回键优先关闭面板', (tester) async {
    final env = await pumpFeedbackApp(
      tester,
      appVersion: '0.1.0+2',
      child: const Scaffold(body: Text('home')),
    );
    await tester.pump();

    final orb = find.byKey(const Key('feedback-orb'));
    expect(orb, findsOneWidget);

    env.readerDepth.value = 1;
    await tester.pump();
    expect(orb, findsNothing);
    env.readerDepth.value = 0;
    await tester.pump();
    expect(orb, findsOneWidget);

    // 面板打开时返回键先关面板；面板关闭时才轮到页面返回。
    env.feedback.open();
    await tester.pump();
    // 面板会话恢复带 2s 超时兜底（测试环境无 secure-storage 插件）。
    await tester.pump(const Duration(seconds: 3));
    expect(env.feedback.isOpen, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(env.feedback.isOpen, isFalse);
  });

  testWidgets('路由跳转不重建反馈会话：草稿跨页面保留', (tester) async {
    final env = await pumpFeedbackApp(
      tester,
      child: const Scaffold(body: Text('home')),
    );
    await tester.pump();

    env.feedback.open();
    await tester.pump();
    // 面板会话恢复带 2s 超时兜底（测试环境无 secure-storage 插件）。
    await tester.pump(const Duration(seconds: 3));

    // 未登录也进入 compose 视图：正文输入框跨路由保留即可证明会话未重建。
    final field = find.byKey(const Key('feedback-input'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '跨页面草稿');
    await tester.pump();

    // 0.14.0 起「关闭面板 = 放弃未提交的草稿」（破坏性变更），所以这里不再
    // 用「关面板 → 导航 → 再打开」来验证草稿，那是旧版本的行为。改在面板
    // 保持打开的状态下推入 / 退出宿主页面：组件挂在应用 Navigator 之上，
    // 草稿与面板状态都不该受影响。检查强度比原来更强（中间没有关闭重置）。
    final hostNavigator =
        tester.state<NavigatorState>(find.byType(Navigator).last);
    hostNavigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('page-2')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('page-2'), findsOneWidget);
    expect(env.feedback.isOpen, isTrue);

    hostNavigator.pop();
    await tester.pump();
    // 退场动画（约 300ms）结束后还要几帧才把路由子树摘掉。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('page-2'), findsNothing);
    expect(env.feedback.isOpen, isTrue);
    expect(find.text('跨页面草稿'), findsOneWidget);
  });

  testWidgets('返回键先弹放弃确认：继续编辑保留草稿，确认后才关面板', (tester) async {
    final env = await pumpFeedbackApp(
      tester,
      child: const Scaffold(body: Text('home')),
    );
    await tester.pump();

    env.feedback.open();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final field = find.byKey(const Key('feedback-input'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '写了一半');
    await tester.pump();

    // 面板里有用户写的内容：返回先问「放弃这次反馈？」，既不直接关面板，
    // 也不把底下的宿主页面 pop 掉（守卫的 PopEntry 让宿主路由拒绝 pop）。
    // handlePopRoute 会一直等到确认框出结果，所以不能 await（会卡住测试）。
    unawaited(tester.binding.handlePopRoute());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('feedback-discard-confirm')), findsOneWidget);
    expect(env.feedback.isOpen, isTrue);
    expect(find.text('home'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feedback-discard-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('feedback-discard-confirm')), findsNothing);
    expect(env.feedback.isOpen, isTrue);
    expect(find.text('写了一半'), findsOneWidget);

    // 再来一次并确认放弃：面板关闭，宿主页面仍在。
    unawaited(tester.binding.handlePopRoute());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('feedback-discard-ok')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(env.feedback.isOpen, isFalse);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('宿主托管的五项外观原样交给组件，设置快照变了组件跟着变',
      (tester) async {
    const initial = AppSettings(
      feedbackLauncherStyle: 'beam',
      feedbackOrbIdleStyle: 'edge',
      feedbackWakeGestures: <String>[
        'two-finger-hold',
        'two-finger-double-tap',
      ],
      feedbackOrbEntrance: 'turn',
      feedbackWakeVisual: 'aurora',
    );
    final env = await pumpFeedbackApp(
      tester,
      child: const Scaffold(body: Text('home')),
      initialSettings: initial,
      // 生产路径：不做记忆仓库注入，断言的就是组件真正收到的参数。
      injectTestStores: false,
    );
    await tester.pump();

    FeedbackWidget hosted() =>
        tester.widget<FeedbackWidget>(find.byType(FeedbackWidget));

    expect(hosted().launcherStyle, FeedbackLauncherStyle.beam);
    expect(hosted().orbIdleStyle, FeedbackOrbIdleStyle.edge);
    expect(hosted().wakeGestures, <FeedbackWakeGesture>{
      FeedbackWakeGesture.twoFingerHold,
      FeedbackWakeGesture.twoFingerDoubleTap,
    });
    expect(hosted().orbEntrance, FeedbackOrbEntrance.turn);
    expect(hosted().wakeVisual, FeedbackWakeVisual.aurora);
    // 面板只留服务器设置。
    expect(hosted().hideSettings, isTrue);

    // 设置页保存后的新快照走同一条可监听路径重建组件。
    env.settings.value = const AppSettings(
      feedbackLauncherStyle: 'orb',
      feedbackOrbIdleStyle: 'hidden',
      feedbackWakeGestures: <String>[],
      feedbackOrbEntrance: 'drop',
      feedbackWakeVisual: 'ripple',
    );
    await tester.pump();
    expect(hosted().launcherStyle, FeedbackLauncherStyle.orb);
    expect(hosted().orbIdleStyle, FeedbackOrbIdleStyle.hidden);
    expect(hosted().wakeGestures, isEmpty);
    expect(hosted().orbEntrance, FeedbackOrbEntrance.drop);
    expect(hosted().wakeVisual, FeedbackWakeVisual.ripple);

    // 面板里的改选（hideSettings 之后不再出现，回调链仍然接通）回到宿主。
    hosted().onWakeVisualChanged!(FeedbackWakeVisual.aurora);
    hosted().onWakeGesturesChanged!(<FeedbackWakeGesture>{
      FeedbackWakeGesture.threeFingerSwipeUp,
    });
    expect(env.appearanceChanges, hasLength(2));
    expect(env.appearanceChanges.first.feedbackWakeVisual, 'aurora');
    expect(env.appearanceChanges.first.feedbackLauncherStyle, 'orb');
    expect(env.appearanceChanges.last.feedbackWakeGestures,
        <String>['three-finger-swipe-up']);
  });

  testWidgets('面板设置页只剩服务器设置：五项外观不再出现', (tester) async {
    final env = await pumpFeedbackApp(
      tester,
      child: const Scaffold(body: Text('home')),
    );
    await tester.pump();

    env.feedback.open();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(const Key('feedback-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 停在设置页：服务器设置还在，宿主托管的五项一个都不该出现。
    expect(find.byKey(const Key('feedback-settings-view')), findsOneWidget);
    expect(find.text('Feedback 服务器'), findsOneWidget);
    expect(find.text('入口样式'), findsNothing);
    expect(find.text('唤醒方式'), findsNothing);
    expect(find.text('唤醒效果'), findsNothing);
    expect(find.text('唤醒动效'), findsNothing);
    expect(find.byKey(const Key('feedback-launcher-style-orb')), findsNothing);
    expect(find.byKey(const Key('feedback-orb-idle-handle')), findsNothing);
    expect(find.byKey(const Key('feedback-orb-entrance')), findsNothing);
    expect(find.byKey(const Key('feedback-wake-two-finger-hold')),
        findsNothing);
  });

  testWidgets('服务器表单遮挡：名称、地址、API Key 与错误详情', (tester) async {
    final api = _FailProbeApi();
    final manager = ServerManager(
      dbPath: '/tmp/test.sqlite',
      api: api,
      secrets: InMemorySecretStore(),
    );
    await tester.pumpWidget(MaterialApp(
      home: ServerFormScreen(manager: manager, onSaved: (_) {}),
    ));
    await tester.pumpAndSettle();

    // 显示名称 + 服务器地址 + API Key 三块遮挡。
    expect(find.byType(FeedbackCaptureMask), findsNWidgets(3));

    await tester.enterText(
        find.widgetWithText(TextField, '服务器地址'), 'http://192.0.2.10:25600');
    await tester.enterText(
        find.widgetWithText(TextField, 'API Key（X-API-Key）'), 'secret-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    // 失败的探测结果整块进遮挡（错误文本可能回显地址或凭据）。
    expect(find.byType(FeedbackCaptureMask), findsNWidgets(4));
    expect(find.byKey(const ValueKey('test-error-headline')), findsOneWidget);
  });

  test('诊断导出：脱敏形状与凭据遮蔽', () async {
    final json = await buildRedactedDiagnosticsExport(_DiagLogRepository());
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded.containsKey('logs'), isTrue);
    // 快照缺省时仍产出日志段。
    expect(decoded.containsKey('db'), isFalse);
    expect(json, contains('Authorization: [REDACTED]'));
    expect(json, isNot(contains('secret-token-abc')));
  });
}

/// 探测必失败的 API：驱动 _TestErrorView 出现以验证遮挡。
class _FailProbeApi extends MemoryRustCoreApi {
  @override
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) async {
    throw StateError(
        '连接 http://a.local:25600 失败 (401): Authorization: Bearer secret');
  }
}

/// 只回日志的仓库：快照缺省、日志含一条待脱敏凭据。
class _DiagLogRepository extends StubLibraryRepository {
  @override
  Future<List<LogRecord>> diagnosticsLogs({
    int limit = 100,
    String minLevel = '',
  }) async =>
      const [
        LogRecord(
          level: 'warn',
          target: 'sync',
          message:
              'sync failed Authorization: Bearer secret-token-abc for http://a.local',
          at: '2026-09-17T00:00:00.000Z',
        ),
      ];
}
