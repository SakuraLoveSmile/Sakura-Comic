import 'dart:async';
import 'dart:convert' show utf8;

import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_settings.dart';
import 'src/diagnostics_screen.dart' show buildRedactedDiagnosticsExport;
import 'src/download_stress.dart';
import 'src/feedback_access.dart';
import 'src/library_repository.dart';
import 'src/reader_stress.dart';
import 'src/rust_core_frb.dart';
import 'src/server_manager.dart';
import 'src/series_grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (repository, manager, rustStatus, isCoreAvailable) =
      await createServices();
  final rawRoute = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  debugPrint('BOOT route=${sanitizeRoute(rawRoute)}');
  runApp(ComicApp(
    repository: repository,
    serverManager: manager,
    rustStatus: rustStatus,
    initialRoute: rawRoute,
    isCoreAvailable: isCoreAvailable,
  ));
}

/// Sanitizes route string so authentication tokens or credentials are never logged.
String sanitizeRoute(String route) {
  final uri = Uri.tryParse(route);
  if (uri == null || uri.queryParameters.isEmpty) return route;
  final sanitizedParams = Map<String, String>.from(uri.queryParameters);
  for (final key in sanitizedParams.keys) {
    final lower = key.toLowerCase();
    if (lower.contains('key') ||
        lower.contains('pass') ||
        lower.contains('token') ||
        lower.contains('auth') ||
        lower.contains('secret')) {
      sanitizedParams[key] = '***';
    }
  }
  return uri.replace(queryParameters: sanitizedParams).toString();
}

/// Wires the UI to the Rust Core through flutter_rust_bridge.
/// In debug, falls back to the in-memory stub whenever the native library cannot
/// be loaded, so the UI can be iterated without an NDK toolchain.
/// In release, missing native core shows an unavailable state and never enters demo data.
Future<(LibraryRepository?, ServerManager?, String?, bool)>
    createServices() async {
  if (!await initRustCore()) {
    debugPrint('[RustCore] init failed — libkomga_core not loaded');
    if (kReleaseMode) {
      return (null, null, '原生核心库加载失败', false);
    }
    return (
      const StubLibraryRepository(),
      null,
      'Rust core 未加载（Stub 模式）',
      true,
    );
  }
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}/comic.sqlite';
    debugPrint('[RustCore] FFI connected (libkomga_core loaded), db=$dbPath');
    final api = FrbRustCoreApi();
    final manager = ServerManager(dbPath: dbPath, api: api);
    return (
      RustLibraryRepository(dbPath: dbPath, api: api, serverManager: manager),
      manager,
      null,
      true,
    );
  } catch (e) {
    debugPrint('[RustCore] init error: $e');
    if (kReleaseMode) {
      return (null, null, '原生核心库初始化异常', false);
    }
    return (
      const StubLibraryRepository(),
      null,
      'Rust core 初始化失败（Stub 模式）',
      true,
    );
  }
}

class ComicApp extends StatefulWidget {
  const ComicApp({
    super.key,
    this.repository = const StubLibraryRepository(),
    this.serverManager,
    this.rustStatus,
    this.initialRoute = '/',
    this.isCoreAvailable = true,
  });

  final LibraryRepository? repository;
  final ServerManager? serverManager;
  final String? rustStatus;
  final String initialRoute;
  final bool isCoreAvailable;

  /// Whether stress acceptance entries are enabled.
  /// Allowed in debug/profile builds or when explicitly configured via dart-define.
  static const bool enableStressHarness = bool.fromEnvironment(
    'ENABLE_STRESS_HARNESS',
    defaultValue: !kReleaseMode,
  );

  /// 反馈服务接入配置（编译期 dart-define）。
  /// 未配置时组件完全不挂载，宿主行为与接入前一致。
  static const String feedbackApiBase =
      String.fromEnvironment('FEEDBACK_API_BASE');
  static const String feedbackAppId = String.fromEnvironment('FEEDBACK_APP_ID');
  static const bool feedbackConfigured =
      feedbackApiBase != '' && feedbackAppId != '';

  @override
  State<ComicApp> createState() => _ComicAppState();
}

class _ComicAppState extends State<ComicApp> {
  AppSettings _settings = const AppSettings();

  /// 反馈控制器由应用根持有，只在根 dispose 时释放：任何路由都共用同一个实例。
  final FeedbackController _feedback = FeedbackController();

  /// 返回键守卫：兼作 MaterialApp 的 navigatorObserver（给每条路由挂
  /// 防 pop 哨兵）与 WidgetsBinding 观察者（面板打开时消费返回键）。
  /// 未配置反馈时控制器恒为关闭态，守卫完全惰性。
  late final FeedbackBackGuard _feedbackBackGuard =
      FeedbackBackGuard(controller: _feedback);

  /// 真实安装包版本（package_info_plus 的 version+buildNumber）。
  /// 读取失败保持 null，组件上报时省略版本字段。
  final ValueNotifier<String?> _appVersion = ValueNotifier<String?>(null);

  /// 前台阅读中的阅读器数量；>0 时反馈悬浮球隐藏（ReaderScreen 负责登记）。
  final ValueNotifier<int> _readerDepth = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _feedbackBackGuard.attach();
    WidgetsBinding.instance.addObserver(_feedbackBackGuard);
    _loadSettings();
    unawaited(_loadAppVersion());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_feedbackBackGuard);
    _feedbackBackGuard.dispose();
    _feedback.dispose();
    _appVersion.dispose();
    _readerDepth.dispose();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion.value = '${info.version}+${info.buildNumber}';
    } catch (_) {/* 读取失败则省略版本字段，不阻塞接入 */}
  }

  /// 反馈日志附件：复用诊断页的脱敏导出（快照 + 日志环，凭据与游标已遮蔽）。
  /// 原生核心不可用（repository 为 null）时返回 null，不提供附件。
  Future<List<FeedbackLogFile>?> _collectFeedbackLogs() async {
    final repo = widget.repository;
    if (repo == null) return null;
    final json = await buildRedactedDiagnosticsExport(repo);
    return <FeedbackLogFile>[
      FeedbackLogFile(
        filename: 'comic-diagnostics.json',
        bytes: utf8.encode(json),
      ),
    ];
  }

  int _settingsGeneration = 0;

  Future<void> _loadSettings() async {
    final generation = ++_settingsGeneration;
    final repo = widget.repository;
    if (repo != null) {
      try {
        final loaded = await repo.loadAppSettings();
        if (mounted && generation == _settingsGeneration) {
          setState(() => _settings = loaded);
        }
      } catch (error) {
        debugPrint('[Settings] load failed: $error');
      }
    }
  }

  void _onSettingsChanged(AppSettings next) {
    _settingsGeneration++;
    if (!mounted) return;
    setState(() => _settings = next);
  }

  Widget get _home {
    if (ComicApp.enableStressHarness) {
      final stress = ReaderStressParams.parse(widget.initialRoute);
      if (stress != null) return ReaderStressScreen(params: stress);
      final download = DownloadStressParams.parse(widget.initialRoute);
      if (download != null) return DownloadStressScreen(params: download);
    }
    if (!widget.isCoreAvailable || widget.repository == null) {
      return const CoreUnavailableScreen();
    }
    return SeriesGridScreen(
      repository: widget.repository!,
      manager: widget.serverManager,
      rustStatus: widget.rustStatus,
      initialSettings: _settings,
      onSettingsChanged: _onSettingsChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic',
      themeMode: switch (_settings.appearance) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: _home,
      // 返回键守卫挂在内层 Navigator：面板开着时各宿主路由拒绝 pop，
      // 由守卫的 didPopRoute 关面板并消费本次返回。
      navigatorObservers: [_feedbackBackGuard],
      // 反馈组件包在应用 Navigator 子树之外，因此 push/pop 路由不会重建它。
      // 未配置 dart-define 时 builder 为 null，宿主行为与接入前一致。
      builder: ComicApp.feedbackConfigured
          ? (context, child) => buildFeedbackShell(
                apiBase: ComicApp.feedbackApiBase,
                appId: ComicApp.feedbackAppId,
                appName: 'Comic',
                controller: _feedback,
                appVersion: _appVersion,
                readerDepth: _readerDepth,
                logProvider: _collectFeedbackLogs,
                child: child,
              )
          : null,
    );
  }
}

/// 反馈组件外壳。抽成顶层函数以便宿主测试用测试配置复用同一套接线。
///
/// 结构（由内到外）：
/// - 外层 Navigator：组件需要 Navigator/Overlay 祖先（面板输入框的选择浮层、
///   截图放大的 showDialog），而应用自己的 Navigator 在组件之下、祖先查找
///   只向上走，故补一个只承载组件、不做页面跳转的外层 Navigator。
/// - ListenableBuilder：外层路由的 onGenerateRoute/pageBuilder 闭包只在
///   首次构建时求值，appVersion 异步到达、阅读中隐藏悬浮球这类随状态变化
///   的输入必须经可监听来源注入，否则不会生效。
/// - FeedbackAccess：把控制器与阅读计数暴露给组件子树内的任意路由
///   （设置页入口、阅读器菜单），避免跨层构造函数传参。
///
/// Android 返回键由 [FeedbackBackGuard] 处理（挂在 MaterialApp 的
/// navigatorObservers 与 WidgetsBinding 观察者上），不在此外壳内。
Widget buildFeedbackShell({
  required String apiBase,
  required String appId,
  required FeedbackController controller,
  required ValueListenable<String?> appVersion,
  required ValueNotifier<int> readerDepth,
  String? appName,
  FeedbackLogProvider? logProvider,
  // 测试注入点：默认构造 FeedbackWidget；测试可换 builder 注入
  // 上游的 @visibleForTesting 参数（内存令牌/偏好仓库），避免
  // 未注册插件通道挂起导致面板卡在加载态。生产路径不引用它们。
  @visibleForTesting
  Widget Function({
    required BuildContext context,
    required FeedbackConfig config,
    required FeedbackController controller,
    required Widget child,
  })? feedbackWidgetBuilder,
  Widget? child,
}) {
  return Navigator(
    onGenerateRoute: (RouteSettings settings) => PageRouteBuilder<void>(
      settings: settings,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation) =>
          ListenableBuilder(
        listenable: Listenable.merge([appVersion, readerDepth]),
        builder: (BuildContext context, _) {
          final config = FeedbackConfig(
            apiBase,
            appId,
            appName: appName,
            appVersion: appVersion.value,
            side: FeedbackSide.right,
            showLauncher: readerDepth.value == 0,
            // 显式声明：灵感球（可拖拽落点）+ 呼出时截取当前应用视口。
            launcherMode: FeedbackLauncherMode.orb,
            captureMode: FeedbackCaptureMode.viewport,
            logProvider: logProvider,
          );
          final accessChild = FeedbackAccess(
            controller: controller,
            readerDepth: readerDepth,
            child: child ?? const SizedBox.shrink(),
          );
          return feedbackWidgetBuilder?.call(
                context: context,
                config: config,
                controller: controller,
                child: accessChild,
              ) ??
              FeedbackWidget(
                config: config,
                controller: controller,
                child: accessChild,
              );
        },
      ),
    ),
  );
}

class CoreUnavailableScreen extends StatelessWidget {
  const CoreUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Comic')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 64, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                '核心服务不可用',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Comic 原生核心库缺失或加载失败。应用无法在此环境下安全运行。请检查安装包完整性或重新安装。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
