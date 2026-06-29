import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/platform_info.dart';
import 'router.dart';
import 'theme.dart';

class ClubTiviApp extends StatefulWidget {
  const ClubTiviApp({super.key});

  @override
  State<ClubTiviApp> createState() => _ClubTiviAppState();
}

class _ClubTiviAppState extends State<ClubTiviApp> {
  // Create the router per-app-instance (not as a global singleton) so a
  // RestartWidget rebuild — e.g. after restoring a backup — gets a fresh
  // GoRouter that starts at '/'. This forces the channel list to rebuild and
  // reload against the freshly-imported database instead of staying on the
  // previous route with stale navigation state.
  late final GoRouter _router = createRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'clubTivi',
      debugShowCheckedModeBanner: false,
      theme: ClubTiviTheme.dark,
      routerConfig: _router,
      builder: (context, child) {
        // Detect TV mode from the first MediaQuery context
        PlatformInfo.detectFromContext(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
