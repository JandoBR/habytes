import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  bool get isUnauthenticated => status == 401;

  @override
  String toString() => message;
}

/// The habitd JSON API. On the web the session cookie authenticates the
/// requests; on Android a device [token] does.
class ApiClient {
  ApiClient({required this.baseUrl, this.token, this.onUnauthenticated, http.Client? client})
    : _http = client ?? http.Client();

  final String baseUrl;
  final String? token;

  /// Called when the server no longer accepts the credential.
  final void Function()? onUnauthenticated;
  final http.Client _http;

  static const _uuid = Uuid();

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri);
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 20)),
      );
    } on Exception {
      throw const ApiException(0, 'network', 'Could not reach the server.');
    }

    final dynamic json;
    try {
      json = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      throw ApiException(response.statusCode, 'bad_response', 'Unexpected response from the server.');
    }
    if (response.statusCode >= 400) {
      final error = json is Map ? json['error'] : null;
      final exception = ApiException(
        response.statusCode,
        error is Map ? error['code'] as String? ?? 'error' : 'error',
        error is Map
            ? error['message'] as String? ?? 'Request failed.'
            : 'Request failed (${response.statusCode}).',
      );
      if (exception.isUnauthenticated) onUnauthenticated?.call();
      throw exception;
    }
    return json;
  }

  // Meta and user

  /// Checks that [baseUrl] is a habitd server.
  Future<void> checkMeta() async {
    final meta = await _send('GET', '/api/v1/meta');
    if (meta is! Map || meta['name'] != 'habitd') {
      throw const ApiException(0, 'not_habitd', 'That address is not a habitd server.');
    }
  }

  Future<User> me() async => User.fromJson(await _send('GET', '/api/v1/me'));

  Future<User> updateMe({String? timezone, int? weekStart}) async => User.fromJson(
    await _send('PATCH', '/api/v1/me', body: {'timezone': ?timezone, 'week_start': ?weekStart}),
  );

  /// Trades the one-time code from the app login for a device token.
  Future<({String token, User user})> exchangeCode({
    required String code,
    required String codeVerifier,
    required String deviceName,
  }) async {
    final json = await _send(
      'POST',
      '/auth/token',
      body: {'code': code, 'code_verifier': codeVerifier, 'device_name': deviceName},
    );
    return (token: json['token'] as String, user: User.fromJson(json['user']));
  }

  Future<void> logout() => _send('POST', '/auth/logout');

  // Habits

  Future<List<Habit>> habits({String archived = 'all'}) async {
    final json = await _send('GET', '/api/v1/habits', query: {'archived': archived}) as List;
    return json.map((h) => Habit.fromJson(h as Map<String, dynamic>)).toList();
  }

  Future<Habit> createHabit({
    required String name,
    required String description,
    required HabitKind kind,
    required Schedule schedule,
    List<int>? weekdays,
    required int goal,
  }) async => Habit.fromJson(
    await _send(
      'POST',
      '/api/v1/habits',
      body: {
        'name': name,
        'description': description,
        'kind': kind.name,
        'schedule': schedule.name,
        'weekdays': weekdays,
        'goal': goal,
      },
    ),
  );

  Future<Habit> updateHabit(String id, Map<String, Object?> changes) async =>
      Habit.fromJson(await _send('PATCH', '/api/v1/habits/$id', body: changes));

  Future<void> deleteHabit(String id) => _send('DELETE', '/api/v1/habits/$id');

  Future<void> reorderHabits(List<String> ids) =>
      _send('PUT', '/api/v1/habits/order', body: {'ids': ids});

  /// Creates or rotates the habit's webhook and returns its URL.
  Future<String> createWebhook(String id) async =>
      (await _send('POST', '/api/v1/habits/$id/webhook'))['webhook_url'] as String;

  Future<void> deleteWebhook(String id) => _send('DELETE', '/api/v1/habits/$id/webhook');

  // Entries

  Future<TodayView> today(String date) async =>
      TodayView.fromJson(await _send('GET', '/api/v1/today', query: {'date': date}));

  /// Raw values by date for one habit, over an inclusive range of at most 366 days.
  Future<Map<String, int>> entries({
    required String habitId,
    required String from,
    required String to,
  }) async {
    final json =
        await _send('GET', '/api/v1/entries', query: {'from': from, 'to': to, 'habit_id': habitId})
            as List;
    return {for (final entry in json) entry['date'] as String: entry['value'] as int};
  }

  Future<EntryStatus> increment(String habitId, String date, int delta) async =>
      EntryStatus.fromJson(
        await _send(
          'POST',
          '/api/v1/habits/$habitId/entries/$date/increment',
          body: {'op_id': _uuid.v7(), 'delta': delta},
        ),
      );

  Future<EntryStatus> setValue(String habitId, String date, int value) async =>
      EntryStatus.fromJson(
        await _send('PUT', '/api/v1/habits/$habitId/entries/$date', body: {'value': value}),
      );

  // Tokens

  Future<List<TokenInfo>> tokens() async {
    final json = await _send('GET', '/api/v1/tokens') as List;
    return json.map((t) => TokenInfo.fromJson(t as Map<String, dynamic>)).toList();
  }

  /// Creates an API token and returns its secret, which is shown only once.
  Future<String> createToken(String name, {int? expiresInDays}) async {
    final json = await _send(
      'POST',
      '/api/v1/tokens',
      body: {'name': name, 'expires_in_days': ?expiresInDays},
    );
    return json['token'] as String;
  }

  Future<void> revokeToken(String id) => _send('DELETE', '/api/v1/tokens/$id');
}
