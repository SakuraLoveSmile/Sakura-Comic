import 'dart:convert';

/// 反馈外观的可选值：与 feedback_widget 的枚举同名存盘，缺字段或未知值时
/// 一律回落默认（老设置文件因此能直接读，不需要迁移）。
const List<String> kFeedbackLauncherStyles = <String>['orb', 'beam'];
const List<String> kFeedbackOrbIdleStyles = <String>[
  'handle',
  'edge',
  'hidden',
];
const List<String> kFeedbackOrbEntrances = <String>[
  'bead',
  'join',
  'reveal',
  'dent',
  'turn',
  'drop',
  'corners',
];
const List<String> kFeedbackWakeVisuals = <String>['ripple', 'aurora'];

/// 唤醒手势：与 FeedbackWakeGesture.id 同源（跨 Web / Flutter 一致的稳定标识）。
const List<String> kFeedbackWakeGestureIds = <String>[
  'two-finger-hold',
  'three-finger-swipe-up',
  'two-finger-double-tap',
];

/// 默认只开双指长按，与组件的默认手势一致。
const List<String> kDefaultFeedbackWakeGestures = <String>['two-finger-hold'];

/// 默认入口是灵感球（沿用本次升级前的固定入口），其余为组件默认值。
const String kDefaultFeedbackLauncherStyle = 'orb';
const String kDefaultFeedbackOrbIdleStyle = 'handle';
const String kDefaultFeedbackOrbEntrance = 'bead';
const String kDefaultFeedbackWakeVisual = 'ripple';

/// AppSettings schema version 1.
///
/// Drives appearance theme mode, shelf grid density, auto metadata sync,
/// maximum disk cache budget, and the hosted feedback appearance
/// (feedback_widget 0.14.0 起由宿主托管的五项设置)。
class AppSettings {
  static const String stateKey = 'app_settings';
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final bool autoSyncMetadata;
  final int cacheLimitMiB;
  final String appearance; // 'system', 'light', 'dark'
  final String gridDensity; // 'compact', 'comfortable', 'spacious'

  /// 反馈入口样式：'orb'（灵感球）或 'beam'（光束唤醒，无常驻入口）。
  final String feedbackLauncherStyle;

  /// 灵感球待机样式：'handle'（小把手）/ 'edge'（球体贴边）/ 'hidden'（隐藏）。
  final String feedbackOrbIdleStyle;

  /// 唤醒手势集合，可多选、可全空；取值为 [kFeedbackWakeGestureIds]。
  final List<String> feedbackWakeGestures;

  /// 灵感球入场动画，取值为 [kFeedbackOrbEntrances]。
  final String feedbackOrbEntrance;

  /// 光束唤醒动效：'ripple'（水波纹）或 'aurora'（波光）。
  final String feedbackWakeVisual;

  /// 接收哪一类发布：'release'（只收正式版）或 'preview'（也收预览版）。
  /// 只影响检查更新时的筛选，不影响已安装包的身份。
  final String updateChannel;

  const AppSettings({
    this.schemaVersion = currentSchemaVersion,
    this.autoSyncMetadata = true,
    this.cacheLimitMiB = 512,
    this.appearance = 'system',
    this.gridDensity = 'comfortable',
    this.feedbackLauncherStyle = kDefaultFeedbackLauncherStyle,
    this.feedbackOrbIdleStyle = kDefaultFeedbackOrbIdleStyle,
    this.feedbackWakeGestures = kDefaultFeedbackWakeGestures,
    this.feedbackOrbEntrance = kDefaultFeedbackOrbEntrance,
    this.feedbackWakeVisual = kDefaultFeedbackWakeVisual,
    this.updateChannel = 'release',
  });

  AppSettings copyWith({
    int? schemaVersion,
    bool? autoSyncMetadata,
    int? cacheLimitMiB,
    String? appearance,
    String? gridDensity,
    String? feedbackLauncherStyle,
    String? feedbackOrbIdleStyle,
    List<String>? feedbackWakeGestures,
    String? feedbackOrbEntrance,
    String? feedbackWakeVisual,
    String? updateChannel,
  }) {
    return AppSettings(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      autoSyncMetadata: autoSyncMetadata ?? this.autoSyncMetadata,
      cacheLimitMiB: cacheLimitMiB ?? this.cacheLimitMiB,
      appearance: appearance ?? this.appearance,
      gridDensity: gridDensity ?? this.gridDensity,
      feedbackLauncherStyle:
          feedbackLauncherStyle ?? this.feedbackLauncherStyle,
      feedbackOrbIdleStyle: feedbackOrbIdleStyle ?? this.feedbackOrbIdleStyle,
      feedbackWakeGestures: feedbackWakeGestures ?? this.feedbackWakeGestures,
      feedbackOrbEntrance: feedbackOrbEntrance ?? this.feedbackOrbEntrance,
      feedbackWakeVisual: feedbackWakeVisual ?? this.feedbackWakeVisual,
      updateChannel: updateChannel ?? this.updateChannel,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'autoSyncMetadata': autoSyncMetadata,
        'cacheLimitMiB': cacheLimitMiB,
        'appearance': appearance,
        'gridDensity': gridDensity,
        'feedbackLauncherStyle': feedbackLauncherStyle,
        'feedbackOrbIdleStyle': feedbackOrbIdleStyle,
        'feedbackWakeGestures': feedbackWakeGestures,
        'feedbackOrbEntrance': feedbackOrbEntrance,
        'feedbackWakeVisual': feedbackWakeVisual,
        'updateChannel': updateChannel,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != null && version is! int) {
      throw const AppSettingsFormatException('schemaVersion 不是整数');
    }
    final schemaVersion = (version as int?) ?? currentSchemaVersion;
    if (schemaVersion > currentSchemaVersion) {
      throw UnsupportedAppSettingsVersion(schemaVersion);
    }
    return AppSettings(
      schemaVersion: schemaVersion,
      autoSyncMetadata: json['autoSyncMetadata'] is bool
          ? json['autoSyncMetadata'] as bool
          : true,
      cacheLimitMiB: _validCacheLimit(json['cacheLimitMiB']),
      appearance: _validChoice(
          json['appearance'], const ['system', 'light', 'dark'], 'system'),
      gridDensity: _validChoice(json['gridDensity'],
          const ['compact', 'comfortable', 'spacious'], 'comfortable'),
      // 反馈外观：老设置文件没有这些字段 → 默认值；未知字段一律忽略。
      feedbackLauncherStyle: _validChoice(json['feedbackLauncherStyle'],
          kFeedbackLauncherStyles, kDefaultFeedbackLauncherStyle),
      feedbackOrbIdleStyle: _validChoice(json['feedbackOrbIdleStyle'],
          kFeedbackOrbIdleStyles, kDefaultFeedbackOrbIdleStyle),
      feedbackWakeGestures: _validWakeGestures(json['feedbackWakeGestures']),
      feedbackOrbEntrance: _validChoice(json['feedbackOrbEntrance'],
          kFeedbackOrbEntrances, kDefaultFeedbackOrbEntrance),
      updateChannel: _validChoice(
          json['updateChannel'], const ['release', 'preview'], 'release'),
      feedbackWakeVisual: _validChoice(
          json['feedbackWakeVisual'], kFeedbackWakeVisuals, kDefaultFeedbackWakeVisual),
    );
  }

  static AppSettings decode(String? jsonString) {
    if (jsonString == null) return const AppSettings();
    if (jsonString.trim().isEmpty) {
      throw const AppSettingsFormatException('设置文件为空');
    }
    final dynamic decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw const AppSettingsFormatException('设置文件根节点不是对象');
    }
    return AppSettings.fromJson(decoded);
  }

  String encode() => jsonEncode(toJson());
}

/// 唤醒手势集合：字段缺失或类型不对 → 默认（双指长按）；显式空列表 → 用户全关。
List<String> _validWakeGestures(Object? value) {
  if (value is! List) return kDefaultFeedbackWakeGestures;
  return List<String>.unmodifiable(
      value.whereType<String>().where(kFeedbackWakeGestureIds.contains));
}

int _validCacheLimit(Object? value) =>
    value is int && const [256, 512, 1024].contains(value) ? value : 512;

String _validChoice(Object? value, List<String> allowed, String fallback) =>
    value is String && allowed.contains(value) ? value : fallback;

class AppSettingsFormatException implements Exception {
  const AppSettingsFormatException(this.message);
  final String message;
  @override
  String toString() => 'AppSettingsFormatException: $message';
}

class UnsupportedAppSettingsVersion extends AppSettingsFormatException {
  UnsupportedAppSettingsVersion(this.version) : super('不支持的设置版本: $version');
  final int version;
}
