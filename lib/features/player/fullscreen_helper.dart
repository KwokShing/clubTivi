import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Manages true fullscreen mode across platforms:
/// - Windows/macOS/Linux: uses window_manager to enter/exit OS-level fullscreen
/// - iOS: rotates to landscape and hides system UI
/// - Android: hides system UI (immersive sticky)
class FullscreenHelper {
  static bool _isFullscreen = false;

  static bool get isFullscreen => _isFullscreen;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Enter true fullscreen.
  static Future<void> enterFullscreen() async {
    if (_isFullscreen) return;
    _isFullscreen = true;

    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(true);
      } else if (Platform.isIOS) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        // `immersiveSticky` is an Android-only mode; on iOS it leaves the status
        // bar drawn (and garbled across a rotation). Hiding every overlay via
        // `manual` is the supported way to get a true fullscreen surface.
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const [],
        );
      } else if (Platform.isAndroid) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } catch (e) {
      // Roll the flag back, otherwise [exitFullscreen]'s guard would treat the
      // window as fullscreen forever and refuse to restore it.
      _isFullscreen = false;
      debugPrint('[Fullscreen] Failed to enter fullscreen: $e');
    }
  }

  /// Exit fullscreen and restore the normal window / orientation.
  ///
  /// The platform call is issued directly rather than from a post-frame
  /// callback. Registering a post-frame callback does not schedule a frame, and
  /// the main caller is `dispose()` as the player route is left — by which
  /// point the UI may be idle and no further frame guaranteed. There is nothing
  /// to gain by deferring a platform channel message anyway.
  static Future<void> exitFullscreen() async {
    if (!_isFullscreen) return;
    _isFullscreen = false;

    try {
      if (_isDesktop) {
        await windowManager.setFullScreen(false);
      } else if (Platform.isIOS) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      } else if (Platform.isAndroid) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (e) {
      debugPrint('[Fullscreen] Failed to exit fullscreen: $e');
    }
  }
}
