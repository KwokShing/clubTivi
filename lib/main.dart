import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/restart_widget.dart';

void main() async {
  // Catch all uncaught async errors — prevent app crash
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();

      // Initialize window_manager for desktop platforms (Windows/macOS/Linux)
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        await windowManager.ensureInitialized();
      }

      // Catch Flutter framework errors (rendering, layout, etc.)
      FlutterError.onError = (details) {
        debugPrint('[FlutterError] ${details.exceptionAsString()}');
        // Don't crash — just log
      };

      runApp(
        const RestartWidget(child: ProviderScope(child: ClubTiviApp())),
      );
    },
    (error, stack) {
      // Uncaught async errors land here instead of crashing
      debugPrint('[Uncaught] $error');
      debugPrint('$stack');
    },
  );
}
