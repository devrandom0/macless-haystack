import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macless_haystack/widgets/refresh_icon_button.dart';

void main() {
  testWidgets('shows the refresh icon and calls onPressed when tapped', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshIconButton(
          refreshing: false,
          onPressed: () => tapped++,
        ),
      ),
    ));

    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byTooltip('Refresh this accessory'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh this accessory'));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('shows a progress indicator and disables itself while refreshing',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RefreshIconButton(
          refreshing: true,
          onPressed: () => tapped++,
        ),
      ),
    ));

    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    var button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
  });
}
