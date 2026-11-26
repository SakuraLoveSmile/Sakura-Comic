import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart';

/// Android 返回键守卫：面板打开时宿主页面不响应 pop，关面板那一步交给
/// 反馈组件自己的返回处理（有内容时先弹「放弃这次反馈？」，确认后才关）。
///
/// 分工（feedback_widget 0.14/0.15 起）：
/// - 组件挂在宿主 `MaterialApp` **外侧**，它的 [WidgetsBindingObserver]
///   比 `WidgetsApp` 先注册，所以返回键先到组件：组件关面板前会确认，
///   然后返回 true，宿主页面不会被 pop。
/// - 本守卫作为 [NavigatorObserver] 给每条 ModalRoute 挂 [PopEntry] 哨兵：
///   面板打开期间 `canPopNotifier` 为 false，这些路由的 popDisposition 是
///   doNotPop——预测返回手势、以及任何绕过组件直接走 `Navigator.maybePop`
///   的返回路径都不会把面板底下的宿主页面 pop 掉。
///
/// 这里**不消费返回键**：0.5.2 时代本守卫直接 `controller.close()`，那会跳过
/// 组件 0.15.0 新增的关闭确认，把用户刚写的正文和手加图片静默丢掉。
class FeedbackBackGuard extends NavigatorObserver {
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
