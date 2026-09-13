import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class Hyperlink extends StatelessWidget {
  /// The target url to open.
  final String target;

  /// The display text of the hyperlink. Default is [target].
  final String _text;

  /// Displays a hyperlink that can be opened by a tap.
  const Hyperlink({
    super.key,
    required this.target,
    text,
  })  : _text = text ?? target;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: _text,
      // The child Text below already renders _text - without this, a
      // screen reader announces the same label twice (once from here,
      // once from the Text's own implicit semantics).
      excludeSemantics: true,
      child: InkWell(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
        onTap: () {
          launchUrl(Uri.parse((target)));
        },
      ),
    );
  }
}
