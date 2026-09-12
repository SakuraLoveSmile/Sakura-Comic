import 'dart:convert';

/// AppSettings schema version 1.
///
/// Drives appearance theme mode, shelf grid density, auto metadata sync,
/// and maximum disk cache budget.
class AppSettings {
  static const String stateKey = 'app_settings';
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final bool autoSyncMetadata;
  final int cacheLimitMiB;
  final String appearance; // 'system', 'light', 'dark'
  final String gridDensity; // 'compact', 'comfortable', 'spacious'

  const AppSettings({
    this.schemaVersion = currentSchemaVersion,
    this.autoSyncMetadata = true,
    this.cacheLimitMiB = 512,
    this.appearance = 'system',
    this.gridDensity = 'comfortable',
  });

  AppSettings copyWith({
    int? schemaVersion,
    bool? autoSyncMetadata,
    int? cacheLimitMiB,
    String? appearance,
    String? gridDensity,
  }) {
    return AppSettings(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      autoSyncMetadata: autoSyncMetadata ?? this.autoSyncMetadata,
      cacheLimitMiB: cacheLimitMiB ?? this.cacheLimitMiB,
      appearance: appearance ?? this.appearance,
      gridDensity: gridDensity ?? this.gridDensity,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'autoSyncMetadata': autoSyncMetadata,
        'cacheLimitMiB': cacheLimitMiB,
        'appearance': appearance,
        'gridDensity': gridDensity,
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
