// What the app needs from the browser, and nothing on other platforms.
export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
