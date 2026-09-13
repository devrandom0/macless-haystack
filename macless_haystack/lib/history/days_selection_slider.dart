import 'dart:math';

import 'package:flutter/material.dart';

class DaysSelectionSlider extends StatelessWidget {
  /// The number of days currently selected.
  final double numberOfDays;

  /// The largest number of days back the slider can reach - normally the
  /// user's configured "days to fetch" setting, so the slider never offers
  /// a range with no data behind it.
  final int maxDays;

  /// A callback listening for value changes.
  final ValueChanged<double> onChanged;

  /// Display a slider that allows to define how many days to go back.
  const DaysSelectionSlider({
    super.key,
    required this.numberOfDays,
    required this.maxDays,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // A degenerate 1-day range can't drive a Slider (min must be < max),
    // and isn't worth a slider anyway.
    var effectiveMax = max(maxDays, 2);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text(
            'Days back',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(width: 12),
          const Text('1'),
          Expanded(
            child: Slider(
              value: numberOfDays.clamp(1, effectiveMax.toDouble()),
              min: 1,
              max: effectiveMax.toDouble(),
              label: '${numberOfDays.round()}',
              divisions: effectiveMax - 1,
              onChanged: onChanged,
            ),
          ),
          Text('$effectiveMax'),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text(
              '${numberOfDays.round()}d',
              textAlign: TextAlign.end,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
