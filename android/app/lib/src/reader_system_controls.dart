import 'package:flutter/services.dart';

/// Screen-awake and window brightness, through one method channel.
///
/// These are the two reader settings that cannot live in the core: they touch
/// the OS. They go through a platform channel rather than a pub package, so
/// Stage 7 adds no dependency — and every call degrades to a no-op when no
/// handler is installed (host tests, desktop runs), because a reader that
/// throws because it cannot dim the screen is not usable.
class ReaderSystemControls {
  ReaderSystemControls({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('comic/reader');

  final MethodChannel _channel;

  bool _supported = true;
  bool get supported => _supported;

  Future<bool> setKeepScreenAwake(bool enabled) =>
      _invoke('setKeepScreenAwake', {'enabled': enabled});

  /// 0.05..=1.0; null restores the system brightness.
  Future<bool> setBrightness(double? level) =>
      _invoke('setBrightness', {'level': level});

  Future<bool> _invoke(String method, Map<String, Object?> args) async {
    if (!_supported) return false;
    try {
      await _channel.invokeMethod<bool>(method, args);
      return true;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException {
      return false;
    }
  }
}
