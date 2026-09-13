import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RefreshAction extends StatefulWidget {
  final AsyncCallback callback;

  /// Long-press action for forcing a fetch straight from Apple, bypassing
  /// the endpoint's own freshness cache. Null hides this behavior (no
  /// onLongPress at all) rather than just doing nothing on long-press.
  final AsyncCallback? onForceRefresh;

  /// A new accessory can be created or an existing one imported manually.
  const RefreshAction({super.key, required this.callback, this.onForceRefresh});

  @override
  State<StatefulWidget> createState() {
    return _RefreshingWidgetState();
  }
}

class _RefreshingWidgetState extends State<RefreshAction> {
  // Guards against a double-tap (or a long-press racing a tap) firing two
  // overlapping fetches - especially important for onForceRefresh, which
  // bypasses the endpoint's own freshness cache and hits Apple directly.
  bool _busy = false;

  Future<void> _run(AsyncCallback action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var button = FloatingActionButton(
      heroTag: null,
      onPressed: _busy ? null : () => _run(widget.callback),
      child: const Icon(Icons.refresh),
    );
    if (widget.onForceRefresh == null) {
      return Tooltip(message: 'Refresh', child: button);
    }
    // FloatingActionButton's own `tooltip` param installs its own
    // long-press gesture recognizer internally (it wraps itself in a
    // Tooltip), which wins the gesture arena against an outer
    // GestureDetector's onLongPress before it ever fires - so the tooltip
    // lives here instead, in manual trigger mode, and no longer competes.
    return Tooltip(
      message: 'Refresh (long-press to force a fresh fetch from Apple)',
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: _busy
            ? null
            : () {
                HapticFeedback.mediumImpact();
                _run(widget.onForceRefresh!);
              },
        child: button,
      ),
    );
  }
}
