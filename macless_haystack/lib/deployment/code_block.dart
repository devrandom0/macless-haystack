import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CodeBlock extends StatelessWidget {
  final String text;

  /// Displays a code block that can easily copied by the user.
  const CodeBlock({
    super.key,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 50),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            padding: const EdgeInsets.only(
              left: 5,
              top: 5,
              bottom: 5,
              right: 80,
            ),
            child: SelectableText(text),
          ),
          Positioned(
            top: 0,
            right: 5,
            child: OutlinedButton(
              child: const Text('Copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 2),
                ));
              },
            ),
          ),
        ],
      ),
    );
  }
}
