import 'package:flutter/widgets.dart';

/// Wraps the app so it can be fully restarted in-process (Phoenix pattern).
///
/// Swapping the subtree key tears down and recreates the entire widget tree,
/// including the [ProviderScope], so every provider — the database connection,
/// SharedPreferences-backed state, etc. — is rebuilt from scratch. Used after
/// restoring a backup so the freshly-imported database is reopened without the
/// user having to manually relaunch the app.
class RestartWidget extends StatefulWidget {
  const RestartWidget({super.key, required this.child});

  final Widget child;

  /// Rebuild the whole app tree from the nearest [RestartWidget] ancestor.
  static void restart(BuildContext context) {
    context.findAncestorStateOfType<_RestartWidgetState>()?._restart();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key _key = UniqueKey();

  void _restart() => setState(() => _key = UniqueKey());

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}
