import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('Intl.DateTimeFormat')
extension type _DateTimeFormat._(JSObject _) implements JSObject {
  external _DateTimeFormat();
  external _ResolvedOptions resolvedOptions();
}

extension type _ResolvedOptions._(JSObject _) implements JSObject {
  external String? get timeZone;
}

/// The browser's IANA time zone name.
String? browserTimeZone() => _DateTimeFormat().resolvedOptions().timeZone;

/// Leaves the app for [url] in the same tab.
void browserRedirect(String url) => web.window.location.assign(url);

/// Path and query of the page the browser is on.
String browserLocation() => web.window.location.pathname + web.window.location.search;
