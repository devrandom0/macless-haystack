import 'package:flutter/material.dart';
import 'package:macless_haystack/item_management/new_item_action.dart';

class NoAccessoriesPlaceholder extends StatelessWidget {

  /// Displays a message that no accessories are present.
  /// 
  /// Allows the user to quickly add a new accessory.
  const NoAccessoriesPlaceholder({ super.key });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.sell_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'There\'s nothing here yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Add an accessory to get started.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add accessory'),
            onPressed: () =>
                const NewKeyAction().showCreationSheet(context),
          ),
        ],
      ),
    );
  }
}
