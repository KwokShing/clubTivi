import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Manages true fullscreen mode across platforms:
/// - Windows/macOS/Linux: uses window_manager to enter/exit OS-level fullscreen
/// - iOS: rotates to landscape and hides system UI
/// - Android: hides system UI (immersive sticky)
class FullscreenHelper {
  static bool _isFullscreen = false;

  static bool get isFullscreen => _isFullscreen;

  /// Enter true fullscreen.
  static Future<void> enterFullscreen() async {
    if (_isFullscreen) return;
    _isFullscreen = true;

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.setFullScreen(true);
    } else if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// Exit fullscreen and restore normal window/orientation.
  /// Uses a post-frame callback on desktop to avoid conflicts with widget disposal.
  static void exitFullscreen() {
    if (!_isFullscreen) return;
    _isFullscreen = false;

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Schedule after the current frame to avoid conflicts with route transitions
      WidgetsBinding.instance.addPostFrameCallback((_) {
        windowManager.setFullScreen(false);
      });
    } else if (Platform.isIOS) {
      // Setting portrait + landscape at once leaves the app momentarily in the
      // last fullscreen orientation (landscape) before iOS snaps it to
      // portrait — a visible two-step rotation. Lock to portrait first so iOS
      // rotates straight back in one step, then (once that's applied) re-allow
      // the full set so the user can still rotate freely afterwards.
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]).then((_) {
        // Re-allow the full set after the portrait rotation has settled so the
        // user can still rotate freely (and the iOS system rotation lock is
        // respected). The brief delay prevents the re-enable from racing the
        // rotation and bringing back the landscape flash.
        Future.delayed(const Duration(milliseconds: 350), () {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        });
      });
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }
}
