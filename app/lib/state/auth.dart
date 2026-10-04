import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../platform/browser.dart';
import '../platform/native.dart';

sealed class AuthState {
  const AuthState();
}

/// Android only: no server has been chosen yet.
class NeedsServer extends AuthState {
  const NeedsServer();
}

/// A server is known but nobody is signed in. On the web this is only seen
/// for a moment, while the browser is sent to the login page.
class SignedOut extends AuthState {
  const SignedOut(this.serverUrl);

  final String serverUrl;
}

class SignedIn extends AuthState {
  const SignedIn({required this.serverUrl, required this.user, required this.api});

  final String serverUrl;
  final User user;
  final ApiClient api;
}

final authProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// The API client of the signed-in user. Only read this below the sign-in gate.
final apiProvider = Provider<ApiClient>((ref) {
  final auth = ref.watch(authProvider).value;
  if (auth is! SignedIn) throw StateError('not signed in');
  return auth.api;
});

final userProvider = Provider<User>((ref) {
  final auth = ref.watch(authProvider).value;
  if (auth is! SignedIn) throw StateError('not signed in');
  return auth.user;
});

class AuthController extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() => kIsWeb ? _restoreWeb() : _restoreAndroid();

  String get _webOrigin => Uri.base.origin;

  Future<AuthState> _restoreWeb() async {
    final api = ApiClient(baseUrl: _webOrigin, onUnauthenticated: _redirectToLogin);
    try {
      final user = await api.me();
      return await _signedIn(_webOrigin, api, user);
    } on ApiException catch (error) {
      if (error.isUnauthenticated) return SignedOut(_webOrigin);
      rethrow;
    }
  }

  void _redirectToLogin() {
    final redirect = Uri.encodeQueryComponent(browserLocation());
    browserRedirect('/auth/login?redirect=$redirect');
  }

  Future<AuthState> _restoreAndroid() async {
    final credentials = await Native.getCredentials();
    if (credentials == null) return const NeedsServer();
    final api = _deviceClient(credentials.serverUrl, credentials.token);
    try {
      final user = await api.me();
      return await _signedIn(credentials.serverUrl, api, user);
    } on ApiException catch (error) {
      if (error.isUnauthenticated) return SignedOut(credentials.serverUrl);
      rethrow;
    }
  }

  ApiClient _deviceClient(String serverUrl, String token) => ApiClient(
    baseUrl: serverUrl,
    token: token,
    onUnauthenticated: () async {
      // The token was revoked: forget it and go back to the sign-in screen.
      await Native.clearCredentials();
      state = AsyncData(SignedOut(serverUrl));
    },
  );

  /// A brand-new account starts in UTC; move it to this device's time zone.
  Future<AuthState> _signedIn(String serverUrl, ApiClient api, User user) async {
    if (user.timezone == 'UTC') {
      try {
        final zone = kIsWeb ? browserTimeZone() : await Native.timeZone();
        if (zone != null && zone != 'UTC' && (await api.habits()).isEmpty) {
          user = await api.updateMe(timezone: zone);
        }
      } on Exception {
        // Not worth failing a sign-in over; it can be set in Settings.
      }
    }
    return SignedIn(serverUrl: serverUrl, user: user, api: api);
  }

  /// Android: checks that [url] is a habitd server and moves on to sign-in.
  Future<void> setServer(String url) async {
    var serverUrl = url.trim();
    while (serverUrl.endsWith('/')) {
      serverUrl = serverUrl.substring(0, serverUrl.length - 1);
    }
    if (!serverUrl.contains('://')) serverUrl = 'https://$serverUrl';
    await ApiClient(baseUrl: serverUrl).checkMeta();
    state = AsyncData(SignedOut(serverUrl));
  }

  /// Android: forgets the chosen server.
  void changeServer() => state = const AsyncData(NeedsServer());

  /// Android: runs the login in a Custom Tab and stores the device token.
  Future<void> signIn() async {
    final current = state.value;
    if (current is! SignedOut) return;
    final serverUrl = current.serverUrl;

    final random = Random.secure();
    final verifier = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');

    final result = await FlutterWebAuth2.authenticate(
      url: '$serverUrl/auth/login?client=app&code_challenge=$challenge',
      callbackUrlScheme: 'habitd',
    );
    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) {
      throw const ApiException(0, 'no_code', 'The sign-in did not complete.');
    }

    final exchanged = await ApiClient(baseUrl: serverUrl).exchangeCode(
      code: code,
      codeVerifier: verifier,
      deviceName: await Native.deviceName(),
    );
    await Native.saveCredentials(serverUrl, exchanged.token);
    final api = _deviceClient(serverUrl, exchanged.token);
    state = AsyncData(await _signedIn(serverUrl, api, exchanged.user));
    await Native.refreshWidgets();
  }

  Future<void> signOut() async {
    final current = state.value;
    if (current is! SignedIn) return;
    try {
      await current.api.logout();
    } on ApiException {
      // Signing out locally still has to work when the server is unreachable.
    }
    if (kIsWeb) {
      browserRedirect('/auth/login');
      return;
    }
    await Native.clearCredentials();
    state = AsyncData(SignedOut(current.serverUrl));
  }

  void setUser(User user) {
    final current = state.value;
    if (current is SignedIn) {
      state = AsyncData(SignedIn(serverUrl: current.serverUrl, user: user, api: current.api));
    }
  }
}
