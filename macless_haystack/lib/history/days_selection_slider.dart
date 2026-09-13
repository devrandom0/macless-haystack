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
    // With at most 1 day of data ever fetched, there's no real range to
    // slide across - showing a "1..2" slider here would let the user pick
    // a day count that clamping (not real data) invented, reintroducing
    // the exact mismatch this range-following behavior was meant to fix.
    if (maxDays <= 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          'Only the latest location is fetched - see Settings to fetch '
          'more history.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
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
              value: numberOfDays.clamp(1, maxDays.toDouble()),
              min: 1,
              max: maxDays.toDouble(),
              label: '${numberOfDays.round()}',
              divisions: maxDays - 1,
              onChanged: onChanged,
            ),
          ),
          Text('$maxDays'),
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
