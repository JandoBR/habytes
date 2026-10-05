import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Kotlin side of the Android app: the credential store it shares with
/// the widget, and widget refreshes. Every call is a no-op on
/// other platforms.
class Native {
  const Native._();

  static const _channel = MethodChannel('habitd/native');

  static bool get available => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> saveCredentials(String serverUrl, String token) async {
    if (!available) return;
    await _channel.invokeMethod('saveCredentials', {'serverUrl': serverUrl, 'token': token});
  }

  static Future<({String serverUrl, String token})?> getCredentials() async {
    if (!available) return null;
    final result = await _channel.invokeMapMethod<String, String>('getCredentials');
    final serverUrl = result?['serverUrl'];
    final token = result?['token'];
    if (serverUrl == null || token == null) return null;
    return (serverUrl: serverUrl, token: token);
  }

  /// Also clears the widget's cache and outbox.
  static Future<void> clearCredentials() async {
    if (!available) return;
    await _channel.invokeMethod('clearCredentials');
  }

  /// Fetches today's habits and redraws the widgets.
  static Future<void> refreshWidgets() async {
    if (!available) return;
    try {
      await _channel.invokeMethod('refreshWidgets');
    } on PlatformException {
      // The widget retries on its own schedule.
    }
  }

  /// Asks for permission to show notifications, which reminders need.
  static Future<void> requestNotifications() async {
    if (!available) return;
    try {
      await _channel.invokeMethod('requestNotifications');
    } on PlatformException {
      // Without it reminders stay silent; nothing else depends on it.
    }
  }

  /// The device's IANA time zone name.
  static Future<String?> timeZone() async {
    if (!available) return null;
    return _channel.invokeMethod<String>('getTimeZone');
  }

  static Future<String> deviceName() async {
    if (!available) return 'Device';
    return await _channel.invokeMethod<String>('getDeviceName') ?? 'Android device';
  }
}
