import 'package:feedback_widget/feedback_widget.dart';
import 'package:flutter/foundation.dart' show immutable;

import 'app_settings.dart';

/// 宿主托管的五项反馈外观。
///
/// feedback_widget 从 0.14.0 起要求宿主自己提供入口样式、灵感球待机样式、
/// 唤醒方式、唤醒效果（灵感球入场）与唤醒动效，并由宿主保存；组件面板在
/// `hideSettings` 下只剩服务器设置，用户只在本应用的设置页改这里。
///
/// [AppSettings] 里存的是字符串（跨版本、跨端的稳定名字），这一层负责换成
/// 组件枚举，再把面板里的改选写回设置快照。
@immutable
class FeedbackHostAppearance {
  const FeedbackHostAppearance({
    required this.launcherStyle,
    required this.orbIdleStyle,
    required this.wakeGestures,
    required this.orbEntrance,
    required this.wakeVisual,
  });

  /// 按设置快照构造；字符串缺失或过期时回落默认值（与 app_settings 的容错一致）。
  factory FeedbackHostAppearance.fromSettings(AppSettings settings) {
    return FeedbackHostAppearance(
      launcherStyle: _parseLauncherStyle(settings.feedbackLauncherStyle),
      orbIdleStyle: _parseOrbIdleStyle(settings.feedbackOrbIdleStyle),
      wakeGestures: _parseWakeGestures(settings.feedbackWakeGestures),
      orbEntrance: _parseOrbEntrance(settings.feedbackOrbEntrance),
      wakeVisual: _parseWakeVisual(settings.feedbackWakeVisual),
    );
  }

  /// 入口样式：灵感球（常驻入口）或光束唤醒（无常驻入口，靠手势/快捷键呼出）。
  final FeedbackLauncherStyle launcherStyle;

  /// 灵感球待机样式：小把手 / 球体贴边 / 隐藏。
  final FeedbackOrbIdleStyle orbIdleStyle;

  /// 唤醒手势集合：可多选，也可全部关闭。
  final Set<FeedbackWakeGesture> wakeGestures;

  /// 灵感球下次出现时播放的入场动画。
  final FeedbackOrbEntrance orbEntrance;

  /// 光束唤醒时的动效：水波纹 / 波光。
  final FeedbackWakeVisual wakeVisual;

  FeedbackHostAppearance copyWith({
    FeedbackLauncherStyle? launcherStyle,
    FeedbackOrbIdleStyle? orbIdleStyle,
    Set<FeedbackWakeGesture>? wakeGestures,
    FeedbackOrbEntrance? orbEntrance,
    FeedbackWakeVisual? wakeVisual,
  }) {
    return FeedbackHostAppearance(
      launcherStyle: launcherStyle ?? this.launcherStyle,
      orbIdleStyle: orbIdleStyle ?? this.orbIdleStyle,
      wakeGestures: wakeGestures ?? this.wakeGestures,
      orbEntrance: orbEntrance ?? this.orbEntrance,
      wakeVisual: wakeVisual ?? this.wakeVisual,
    );
  }

  /// 写回设置快照：面板里改选 → 宿主保存 → 重建组件后生效。
  AppSettings applyTo(AppSettings settings) {
    return settings.copyWith(
      feedbackLauncherStyle: launcherStyle.name,
      feedbackOrbIdleStyle: orbIdleStyle.name,
      feedbackWakeGestures: <String>[
        for (final FeedbackWakeGesture gesture in FeedbackWakeGesture.values)
          if (wakeGestures.contains(gesture)) gesture.id,
      ],
      feedbackOrbEntrance: orbEntrance.name,
      feedbackWakeVisual: wakeVisual.name,
    );
  }
}

FeedbackLauncherStyle _parseLauncherStyle(String value) {
  for (final FeedbackLauncherStyle style in FeedbackLauncherStyle.values) {
    if (style.name == value) return style;
  }
  return FeedbackLauncherStyle.orb;
}

FeedbackOrbIdleStyle _parseOrbIdleStyle(String value) {
  for (final FeedbackOrbIdleStyle style in FeedbackOrbIdleStyle.values) {
    if (style.name == value) return style;
  }
  return FeedbackOrbIdleStyle.handle;
}

FeedbackOrbEntrance _parseOrbEntrance(String value) {
  for (final FeedbackOrbEntrance entrance in FeedbackOrbEntrance.values) {
    if (entrance.name == value) return entrance;
  }
  return FeedbackOrbEntrance.bead;
}

FeedbackWakeVisual _parseWakeVisual(String value) {
  for (final FeedbackWakeVisual visual in FeedbackWakeVisual.values) {
    if (visual.name == value) return visual;
  }
  return FeedbackWakeVisual.ripple;
}

/// 手势按组件 id 匹配；存盘的未知 id 直接忽略（不会让已开的手势悄悄变成别的）。
Set<FeedbackWakeGesture> _parseWakeGestures(List<String> ids) {
  return <FeedbackWakeGesture>{
    for (final FeedbackWakeGesture gesture in FeedbackWakeGesture.values)
      if (ids.contains(gesture.id)) gesture,
  };
}
