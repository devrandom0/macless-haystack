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
  @override
  Widget build(BuildContext context) {
    var button = FloatingActionButton(
      heroTag: null,
      onPressed: () {
        widget.callback.call();
      },
      tooltip: widget.onForceRefresh == null
          ? 'Refresh'
          : 'Refresh (long-press to force a fresh fetch from Apple)',
      child: const Icon(Icons.refresh),
    );
    if (widget.onForceRefresh == null) {
      return button;
    }
    return GestureDetector(
      onLongPress: () {
        HapticFeedback.mediumImpact();
        widget.onForceRefresh!.call();
      },
      child: button,
    );
  }
}
