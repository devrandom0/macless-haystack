import 'package:flutter/material.dart';

/// A Refresh action that swaps its icon for a small progress indicator and
/// disables itself while [refreshing] - shared by the accessory history
/// page's app bar and the map marker popup so both look and behave
/// identically.
class RefreshIconButton extends StatelessWidget {
  final bool refreshing;
  final VoidCallback? onPressed;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const RefreshIconButton({
    super.key,
    required this.refreshing,
    required this.onPressed,
    this.constraints,
    this.padding = const EdgeInsets.all(8),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      constraints: constraints,
      padding: padding,
      tooltip: 'Refresh this accessory',
      color: color,
      icon: refreshing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      onPressed: refreshing ? null : onPressed,
    );
  }
}
