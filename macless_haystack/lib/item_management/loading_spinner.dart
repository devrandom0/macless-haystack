import 'package:flutter/material.dart';

class LoadingSpinner extends StatelessWidget {

  /// Displays a centered loading spinner.
  const LoadingSpinner({ super.key });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Padding(
        padding: const EdgeInsets.only(top: 20),
        child: CircularProgressIndicator(
          // primaryColor resolves to colorScheme.surface in the dark theme,
          // the same as the scaffold background, making the spinner invisible.
          color: Theme.of(context).colorScheme.primary,
          semanticsLabel: 'Loading. Please wait.',
        ),
      )],
    );
  }
}
