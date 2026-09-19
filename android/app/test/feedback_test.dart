import 'dart:convert';

import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/main.dart' show buildFeedbackShell;
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
  Future<({FeedbackController feedback, ValueNotifier<int> readerDepth})>
      pumpFeedbackApp(
    WidgetTester tester, {
    required Widget child,
    String? appVersion,
    FeedbackLogProvider? logProvider,
  }) async {
    final feedback = FeedbackController();
    final readerDepth = ValueNotifier<int>(0);
    final version = ValueNotifier<String?>(appVersion);
    final guard = FeedbackBackGuard(controller: feedback)..attach();
    WidgetsBinding.instance.addObserver(guard);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      WidgetsBinding.instance.removeObserver(guard);
      guard.dispose();
      feedback.dispose();
      readerDepth.dispose();
      version.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [guard],
      builder: (context, child) => buildFeedbackShell(
        apiBase: 'https://feedback.example.com',
        appId: 'comic',
        appName: 'Comic',
        controller: feedback,
        appVersion: version,
        readerDepth: readerDepth,
        logProvider: logProvider,
        feedbackWidgetBuilder: ({
          required context,
          required config,
          required controller,
          required child,
        }) =>
            FeedbackWidget(
          config: config,
          controller: controller,
          tokenStoreFactory: (_) => MemoryTokenStore(),
          serverPrefStore: MemoryServerPrefStore(),
          child: child,
        ),
        child: child,
      ),
      home: child,
    ));
    return (feedback: feedback, readerDepth: readerDepth);
  }

  testWidgets('问题反馈入口只存在于已接入的作用域内', (tester) async {
    final repo = PagingFakeRepository(const []);

    // 无作用域（未配置 dart-define 的等价物）：入口隐藏。
    await tester
        .pumpWidget(MaterialApp(home: SettingsScreen(repository: repo)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('客户端版本'), 200);
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
      child: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('page-2')),
              ),
            ),
            child: const Text('open-page-2'),
          ),
        ),
      ),
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

    // 面板遮罩会挡住页面按钮，先关面板再导航。
    env.feedback.close();
    await tester.pump();
    await tester.tap(find.text('open-page-2'));
    await tester.pumpAndSettle();
    expect(find.text('page-2'), findsOneWidget);

    tester
        .state<NavigatorState>(find.byType(Navigator).last)
        .pop();
    await tester.pumpAndSettle();

    env.feedback.open();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('跨页面草稿'), findsOneWidget);
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
        find.widgetWithText(TextField, '服务器地址'), 'http://192.168.0.69:25600');
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
