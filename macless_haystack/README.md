# OpenHaystack Mobile
Porting OpenHaystack to Mobile

# About OpenHaystack
OpenHaystack is a project that allows location tracking of Bluetooth Low Energy (BLE) devices over Apples Find My Network.

# Development
This project is written in [Dart](https://dart.dev/), using the cross platform development framework [Flutter](https://flutter.dev/). This allows the creation of apps for all major platforms using a single code base.

## Requisites
To develop and build the project the following tools are needed and should be installed.

- [Flutter SDK](https://docs.flutter.dev/get-started/install)
- [Android SDK / Studio](https://developer.android.com/studio/) (for Android)
- (optional) IDE Plugin (e.g. for [VS Code](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter))

To check the installation run `flutter doctor`. Before continuing review all displayed errors.


## Getting Started
First the necessary dependencies need to be installed. The IDE plugin may take care of this automatically.
```bash
$ flutter pub get
```

The endpoint URL is no longer hardcoded in source; it's read from the app's settings at runtime (see [user_preferences_model.dart](lib/preferences/user_preferences_model.dart)), so you can point the running app at your own endpoint from its Settings screen instead of editing the code.

To run the debug version of the app start a supported emulator and run
```bash
$ flutter run
```

When the app is running a new key pair can be created / imported in the app.

## Project Structure
The project follows the default structure for flutter applications. The `android`, `linux` and `web` folders contain native projects for the specified platform. Native code can be added here for example to access special APIs.

The business logic and UI can be found in the `lib` folder. This folder is furthermore separated into modules containing code regarding a common aspect.
The business logic for accessing and decrypting the location reports is separated in the `findMy` folder for easier reuse.

## Building
This project currently supports Android, Linux and web targets.
The launcher icons are already generated and checked in, so to create a distributable application package just run
```bash
$ flutter build [linux|apk|web]
```
The resulting build artifacts can be found in the `build` folder. To deploy the artifacts to a device consult the platform specific documentation.

Alternatively, `make build` (from the repo root) builds the server image and the Android APK; the APK build still needs a local Flutter SDK, since Docker can't produce a signed/installable APK.
