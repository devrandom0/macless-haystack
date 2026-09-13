import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_dto.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:share_plus/share_plus.dart';

import 'package:universal_html/html.dart' as html;

import 'package:flutter/foundation.dart' show kIsWeb;

class ItemExportMenu extends StatelessWidget {
  /// The accessory to export from
  final Accessory accessory;

  /// Displays a bottom sheet with export options.
  ///
  /// The accessory can be exported to a JSON file or the
  /// key parameters can be exported separately.
  const ItemExportMenu({
    super.key,
    required this.accessory,
  });

  /// Shows the export options for the [accessory].
  void showKeyExportSheet(BuildContext context, Accessory accessory) {
    showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (BuildContext context) {
          return SafeArea(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              children: [
                ListTile(
                  title: const Text('Export'),
                  trailing: IconButton(
                    tooltip: 'What are these keys?',
                    onPressed: () {
                      _showKeyExplanationAlert(context);
                    },
                    icon: const Icon(Icons.info_outline),
                  ),
                ),
                ListTile(
                  title: const Text('Export all accessories (JSON)'),
                  onTap: () async {
                    var accessories =
                        Provider.of<AccessoryRegistry>(context, listen: false)
                            .accessories;
                    await _exportAccessoriesAsJSON(accessories);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export accessory (JSON)'),
                  onTap: () async {
                    await _exportAccessoriesAsJSON([accessory]);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export hashed advertisement key (Base64)'),
                  onTap: () async {
                    var advertisementKey =
                        await accessory.getHashedAdvertisementKey();
                    SharePlus.instance.share(
                      ShareParams(text: advertisementKey),
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export advertisement key (Base64)'),
                  onTap: () async {
                    var advertisementKey =
                        await accessory.getAdvertisementKey();
                    SharePlus.instance.share(
                      ShareParams(text: advertisementKey),
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export private key (Base64)'),
                  subtitle: const Text('Anyone with this key can decrypt '
                      'this accessory\'s locations'),
                  onTap: () async {
                    var confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Share the private key?'),
                            content: Text(
                                'This is the secret that decrypts '
                                '"${accessory.name}"\'s location reports. '
                                'Anyone who receives it can track this '
                                'accessory too - only share it somewhere '
                                'you trust.'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(dialogContext)
                                      .colorScheme
                                      .error,
                                ),
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('Share'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (!confirmed || !context.mounted) return;
                    var privateKey = await accessory.getPrivateKey();
                    SharePlus.instance.share(
                      ShareParams(text: privateKey),
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
          );
        });
  }

  /// Export the serialized [accessories] as a JSON file.
  ///
  /// The OpenHaystack export format is used for interoperability with
  /// the desktop app.
  Future<void> _exportAccessoriesAsJSON(List<Accessory> accessories) async {
    const filename = 'accessories.json';
    // Convert accessories to export format
    List<AccessoryDTO> exportAccessories = [];
    for (Accessory accessory in accessories) {
      String privateKey = await accessory.getPrivateKey();

      List<String> additionalPrivateKeys =
          await accessory.getAdditionalPrivateKeys();

      exportAccessories.add(AccessoryDTO(
          id: int.tryParse(accessory.id) ?? 0,
          colorComponents: [
            accessory.color.r / 255,
            accessory.color.g / 255,
            accessory.color.b / 255,
            accessory.color.a,
          ],
          name: accessory.name,
          privateKey: privateKey,
          icon: accessory.rawIcon,
          isActive: accessory.isActive,
          additionalKeys: additionalPrivateKeys));
    }
    JsonEncoder encoder = const JsonEncoder.withIndent('  '); // format output
    String encodedAccessories = encoder.convert(exportAccessories);

    if (kIsWeb) {
      final blob =
          html.Blob([encodedAccessories], 'application/json', 'native');
      final url = html.Url.createObjectUrlFromBlob(blob);

      html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();

      html.Url.revokeObjectUrl(url);
    } else {
      // Create temporary directory to store export file
      Directory tempDir = await getTemporaryDirectory();
      String path = tempDir.path;

      // Create file and write accessories as json

      File file = File('$path/$filename');

      await file.writeAsString(encodedAccessories);
      // Share export file over os share dialog

      SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: filename),
      );
    }
  }

  /// Show an explanation how the different key types are used.
  Future<void> _showKeyExplanationAlert(BuildContext context) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Key overview'),
          content: const SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Private Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Secret key used for location report decryption.'),
                Text('Advertisement Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Shortened public key sent out over Bluetooth.'),
                Text('Hashed Advertisement Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Used to retrieve location reports from the endpoint.'),
                Text('Accessory:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('A file containing all information about the accessory.'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Export accessory',
      onPressed: () {
        showKeyExportSheet(context, accessory);
      },
      icon: const Icon(Icons.ios_share),
    );
  }
}
