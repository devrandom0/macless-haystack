import 'dart:convert';

import 'package:flutter/material.dart';

class AccessoryPrivateKeyInput extends StatelessWidget {
  final ValueChanged<String?> changeListener;

  /// Displays an input field with validation for a Base64 encoded accessory private key.
  const AccessoryPrivateKeyInput({
    super.key,
    required this.changeListener,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: TextFormField(
        decoration: const InputDecoration(
          labelText: 'Private Key (Base64)',
          helperText: 'Base64-encoded private key',
        ),
        validator: (value) {
          if (value == null || value.isEmpty) {
            return 'Private key must be provided.';
          }
          try {
            var removeEscaping = value
              .replaceAll('\\', '').replaceAll('\n', '');
            base64Decode(removeEscaping);
          } catch (e) {
            return 'Private key must be a valid Base64 key.';
          }
          return null;
        },
        onSaved: (newValue) =>
          changeListener(newValue?.replaceAll('\\', '').replaceAll('\n', '')),
      ),
    );
  }
}
