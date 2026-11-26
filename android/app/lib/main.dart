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
import 'src/feedback_appearance.dart';
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
  /// 设置快照。反馈外观要送进组件外壳，而外壳挂在 MaterialApp 外侧、只建
  /// 一次（见 [buildFeedbackShell]），所以设置走可监听快照：设置页保存后
  /// 通知，外壳按新值重建组件。
  final ValueNotifier<AppSettings> _settings =
      ValueNotifier<AppSettings>(const AppSettings());

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
    _loadSettings();
    unawaited(_loadAppVersion());
  }

  @override
  void dispose() {
    _feedbackBackGuard.dispose();
    _feedback.dispose();
    _appVersion.dispose();
    _readerDepth.dispose();
    _settings.dispose();
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
          _settings.value = loaded;
        }
      } catch (error) {
        debugPrint('[Settings] load failed: $error');
      }
    }
  }

  void _onSettingsChanged(AppSettings next) {
    _settingsGeneration++;
    if (!mounted) return;
    _settings.value = next;
  }

  /// 反馈面板里改选外观后回传：先让新值生效，再落盘。
  /// 写盘失败只记日志——本次会话继续按新值显示（组件对宿主托管值不做回读）。
  /// 面板传了 `hideSettings: true`，这条路径平时不会触发，留着是为了让
  /// 「面板改 → 宿主保存 → 重建组件」这条回传链路保持完整。
  Future<void> _onFeedbackAppearanceChanged(AppSettings next) async {
    if (!mounted) return;
    _settings.value = next;
    final repo = widget.repository;
    if (repo == null) return;
    try {
      await repo.saveAppSettings(next);
    } catch (error) {
      debugPrint('[Settings] feedback appearance save failed: $error');
    }
  }

  Widget _homeFor(AppSettings settings) {
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
      initialSettings: settings,
      onSettingsChanged: _onSettingsChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: _settings,
      builder: (BuildContext context, AppSettings settings, Widget? _) {
        final Widget app = MaterialApp(
          title: 'Comic',
          themeMode: switch (settings.appearance) {
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
          home: _homeFor(settings),
          // 返回键守卫挂在应用 Navigator 上：面板开着时各宿主路由拒绝 pop，
          // 关面板与「放弃这次反馈？」确认由组件自己的返回处理完成。
          navigatorObservers: [_feedbackBackGuard],
        );
        // 反馈组件包在 MaterialApp 外侧（上游 v12 推荐挂载）：push/pop 路由
        // 不会重建它；组件自己先于 WidgetsApp 收到安卓返回，关闭前能弹出
        // 「放弃这次反馈？」确认。未配置 dart-define 时组件完全不挂载。
        if (!ComicApp.feedbackConfigured) return app;
        return buildFeedbackShell(
          apiBase: ComicApp.feedbackApiBase,
          appId: ComicApp.feedbackAppId,
          appName: 'Comic',
          controller: _feedback,
          appVersion: _appVersion,
          readerDepth: _readerDepth,
          settings: _settings,
          onFeedbackAppearanceChanged: _onFeedbackAppearanceChanged,
          logProvider: _collectFeedbackLogs,
          child: app,
        );
      },
    );
  }
}

/// 反馈组件外壳。抽成顶层函数以便宿主测试用测试配置复用同一套接线。
///
/// 结构（由内到外）：
/// - ListenableBuilder：随 appVersion（异步到达）、阅读中隐藏入口、设置页改
///   反馈外观这些输入重建组件——组件外壳只挂一次，实例上的可变输入必须经
///   可监听来源注入，否则改了也不生效。
/// - FeedbackWidget：包在宿主 [child]（本应用是 `MaterialApp`）**外侧**
///   （上游 v12 推荐挂载）。好处有两个：push/pop 路由永远不会重建它，面板
///   打开时的安卓返回先到组件而不是宿主 —— 有正文 / 手加图片 / 手动日志时
///   组件先弹「放弃这次反馈？」，确认后才关；截图边界也落在应用 Navigator
///   之上，根弹窗与页面同样入图。组件在 MaterialApp 外侧会自备
///   Directionality / MediaQuery / Theme / Localizations / Overlay。
/// - FeedbackAccess：把控制器与阅读计数暴露给组件子树内的任意路由
///   （设置页入口、阅读器菜单），避免跨层构造函数传参。
///
/// 反馈外观五项由宿主托管（feedback_widget 0.14.0 的接入要求）：值来自
/// [settings] 快照，改选回传给 [onFeedbackAppearanceChanged] 由宿主保存；
/// 面板传 `hideSettings: true`，里面的设置页只留服务器设置。
///
/// [FeedbackBackGuard] 挂在宿主 MaterialApp 的 navigatorObservers 上，只负责
/// 「面板开着时别把宿主页面 pop 掉」，不在这里。
Widget buildFeedbackShell({
  required String apiBase,
  required String appId,
  required FeedbackController controller,
  required ValueListenable<String?> appVersion,
  required ValueNotifier<int> readerDepth,
  required ValueListenable<AppSettings> settings,
  String? appName,
  ValueChanged<AppSettings>? onFeedbackAppearanceChanged,
  FeedbackLogProvider? logProvider,
  // 测试注入点：默认构造 FeedbackWidget；测试可换 builder 注入上游的
  // @visibleForTesting 参数（内存令牌 / 偏好仓库），避免未注册插件通道挂起
  // 导致面板卡在加载态。生产路径不引用它们。
  @visibleForTesting
  Widget Function({
    required BuildContext context,
    required FeedbackConfig config,
    required FeedbackController controller,
    required FeedbackHostAppearance appearance,
    required ValueChanged<FeedbackHostAppearance> onAppearanceChanged,
    required Widget child,
  })? feedbackWidgetBuilder,
  required Widget child,
}) {
  return ListenableBuilder(
    listenable: Listenable.merge([appVersion, readerDepth, settings]),
    builder: (BuildContext context, _) {
      final config = FeedbackConfig(
        apiBase,
        appId,
        appName: appName,
        appVersion: appVersion.value,
        side: FeedbackSide.right,
        showLauncher: readerDepth.value == 0,
        // 入口形态不在这里写死：由下面宿主托管的 `launcherStyle` 决定
        // （FeedbackConfig.launcherMode 在托管后不参与）；截图仍是
        // 「呼出时截取当前应用视口」。
        captureMode: FeedbackCaptureMode.viewport,
        // 唤醒快捷键沿用组件默认（Ctrl/⌘ + Shift + F），不在宿主设置页另开
        // 一项：Android 触屏设备没有硬件键盘，五项已经覆盖手势与入口。
        wakeShortcut: const FeedbackWakeShortcut(),
        logProvider: logProvider,
      );
      final FeedbackHostAppearance appearance =
          FeedbackHostAppearance.fromSettings(settings.value);
      void onAppearanceChanged(FeedbackHostAppearance next) =>
          onFeedbackAppearanceChanged?.call(next.applyTo(settings.value));
      final accessChild = FeedbackAccess(
        controller: controller,
        readerDepth: readerDepth,
        child: child,
      );
      return feedbackWidgetBuilder?.call(
            context: context,
            config: config,
            controller: controller,
            appearance: appearance,
            onAppearanceChanged: onAppearanceChanged,
            child: accessChild,
          ) ??
          FeedbackWidget(
            config: config,
            controller: controller,
            // 宿主托管：入口样式、待机样式、唤醒方式、入场动画与光束动效。
            launcherStyle: appearance.launcherStyle,
            onLauncherStyleChanged: (FeedbackLauncherStyle style) =>
                onAppearanceChanged(appearance.copyWith(launcherStyle: style)),
            orbIdleStyle: appearance.orbIdleStyle,
            onOrbIdleStyleChanged: (FeedbackOrbIdleStyle style) =>
                onAppearanceChanged(appearance.copyWith(orbIdleStyle: style)),
            wakeGestures: appearance.wakeGestures,
            onWakeGesturesChanged: (Set<FeedbackWakeGesture> gestures) =>
                onAppearanceChanged(
                    appearance.copyWith(wakeGestures: gestures)),
            orbEntrance: appearance.orbEntrance,
            onOrbEntranceChanged: (FeedbackOrbEntrance entrance) =>
                onAppearanceChanged(
                    appearance.copyWith(orbEntrance: entrance)),
            wakeVisual: appearance.wakeVisual,
            onWakeVisualChanged: (FeedbackWakeVisual visual) =>
                onAppearanceChanged(appearance.copyWith(wakeVisual: visual)),
            // 五项都在本应用设置页，面板只留服务器设置。
            hideSettings: true,
            child: accessChild,
          );
    },
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
