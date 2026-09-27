import 'package:flutter/foundation.dart';

import 'accessory/accessory_model.dart';
import 'callbacks.dart';

/// Tracks which accessories currently have a refresh in flight, shared by
/// every place a user can trigger one - the accessory list's swipe action,
/// the map marker popup, and the history page's app bar - so refreshing the
/// same accessory from two of them at once is a no-op, while refreshing a
/// different accessory is never blocked by it.
class RefreshCoordinator extends ValueNotifier<Set<String>> {
  RefreshCoordinator(this._loadLocationUpdates) : super(<String>{});

  final LoadLocationUpdatesCallback _loadLocationUpdates;

  bool isRefreshing(String accessoryId) => value.contains(accessoryId);

  /// Refreshes [accessory] via the dashboard's single-accessory path
  /// ([_loadLocationUpdates]). A second call for the same accessory while
  /// one is already in flight is a no-op; a different accessory's refresh
  /// runs independently and is never blocked by it. The try/finally
  /// guarantees the in-flight flag - and so any spinner bound to
  /// [isRefreshing] - always clears, even if the refresh throws.
  Future<void> refresh(Accessory accessory) async {
    if (value.contains(accessory.id)) {
      return;
    }
    value = {...value, accessory.id};
    try {
      await _loadLocationUpdates(accessory);
    } finally {
      value = {...value}..remove(accessory.id);
    }
  }
}
