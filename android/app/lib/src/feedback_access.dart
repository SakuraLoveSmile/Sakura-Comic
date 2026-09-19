import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart';

/// Android 返回键守卫：反馈面板打开时优先关面板、不执行页面返回。
///
/// 机制：普通 MaterialApp 没有 Router，BackButtonListener 不可用；返回键经
/// `handlePopRoute` 按注册顺序遍历 [WidgetsBindingObserver.didPopRoute]。
/// 本守卫在应用根 initState 注册，早于 WidgetsApp 自身的观察者，因此面板
/// 打开时直接消费返回事件，内层 Navigator 根本收不到本次返回。
///
/// 同时作为 [NavigatorObserver] 给每条 ModalRoute 挂 [PopEntry] 哨兵：
/// 面板打开期间 `canPopNotifier` 为 false，让路由的 popDisposition 拒绝
/// pop——预测返回手势因此留在框架内处理（回到 didPopRoute 路径），而不是
/// 由系统直接把应用退到后台。
class FeedbackBackGuard extends NavigatorObserver with WidgetsBindingObserver {
  FeedbackBackGuard({required this.controller});

  final FeedbackController controller;

  /// 面板关闭时为 true（宿主路由可正常 pop）；面板打开时为 false。
  final ValueNotifier<bool> panelClosed = ValueNotifier<bool>(true);

  final Map<ModalRoute<dynamic>, PopEntry<Object?>> _entries =
      <ModalRoute<dynamic>, PopEntry<Object?>>{};

  /// 监听控制器开合状态并同步 [panelClosed]。
  void attach() {
    controller.addListener(_syncPanelClosed);
    _syncPanelClosed();
  }

  /// 与 attach 对应：摘除监听、清理各路由上的哨兵并释放通知器。
  void dispose() {
    controller.removeListener(_syncPanelClosed);
    for (final entry in _entries.entries) {
      try {
        entry.key.unregisterPopEntry(entry.value);
      } catch (_) {/* 路由已销毁 */}
    }
    _entries.clear();
    panelClosed.dispose();
  }

  void _syncPanelClosed() => panelClosed.value = !controller.isOpen;

  /// 系统返回键：面板打开时关面板并消费；否则放行给后续观察者
  /// （WidgetsApp → 内层 Navigator.maybePop → 正常页面返回）。
  @override
  Future<bool> didPopRoute() async {
    if (controller.isOpen) {
      controller.close();
      return true;
    }
    return false;
  }

  void _attach(Route<dynamic>? route) {
    if (route is! ModalRoute<dynamic> || _entries.containsKey(route)) return;
    final PopEntry<Object?> entry = _GuardPopEntry(panelClosed);
    _entries[route] = entry;
    route.registerPopEntry(entry);
  }

  void _detach(Route<dynamic>? route) {
    final PopEntry<Object?>? entry = _entries.remove(route);
    if (entry != null && route is ModalRoute<dynamic>) {
      try {
        route.unregisterPopEntry(entry);
      } catch (_) {/* 路由已销毁 */}
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _attach(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _detach(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _detach(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _detach(oldRoute);
    _attach(newRoute);
  }
}

/// 每条宿主路由上的守卫项：仅借 [canPopNotifier] 表达「面板开着、不许 pop」，
/// pop 结果本身不需要处理（面板由 [FeedbackBackGuard.didPopRoute] 关闭）。
class _GuardPopEntry extends PopEntry<Object?> {
  _GuardPopEntry(this._panelClosed);

  final ValueListenable<bool> _panelClosed;

  @override
  ValueListenable<bool> get canPopNotifier => _panelClosed;
}

/// 宿主侧反馈访问点：把根级唯一的 [FeedbackController] 与阅读可见性计数
/// 挂进 [FeedbackWidget] 的子树，任何路由都能以 context 就近取得——免掉
/// 跨多层页面构造函数的参数传递。
///
/// 组件未配置（缺 dart-define）时作用域不存在，[maybeOf] 返回 null，
/// 各入口据此自行隐藏，宿主行为与未接入一致。
class FeedbackAccess extends InheritedWidget {
  const FeedbackAccess({
    super.key,
    required this.controller,
    required this.readerDepth,
    required super.child,
  });

  /// 根级唯一控制器：open / close / captureAndOpen。
  final FeedbackController controller;

  /// 处于前台阅读中的 [ReaderScreen] 实例数；>0 时悬浮球隐藏。
  /// 由阅读器在 didChangeDependencies / dispose 中自增自减，
  /// 临时弹层（如阅读设置底部页）不影响计数。
  final ValueNotifier<int> readerDepth;

  /// 建立依赖并返回最近的访问点；未接入反馈时返回 null。
  static FeedbackAccess? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeedbackAccess>();

  @override
  bool updateShouldNotify(FeedbackAccess oldWidget) =>
      !identical(controller, oldWidget.controller) ||
      !identical(readerDepth, oldWidget.readerDepth);
}
