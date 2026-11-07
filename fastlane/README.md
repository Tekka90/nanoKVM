fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### icons

```sh
[bundle exec] fastlane icons
```

Regenerate every app icon PNG from NanoKVM/Icon/AppIcon.svg

### test_all

```sh
[bundle exec] fastlane test_all
```

Run the unit tests on macOS and on an iOS simulator

### beta_all

```sh
[bundle exec] fastlane beta_all
```

Upload the same TestFlight build for iOS and macOS

----


## iOS

### ios test

```sh
[bundle exec] fastlane ios test
```

Run the unit tests on an iOS simulator

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Archive and upload an iOS/iPadOS build to TestFlight

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload only the App Store text metadata (no binary)

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Upload only the staged screenshots (fastlane/screenshots/ios), see scripts/screenshots/publish.sh

### ios release

```sh
[bundle exec] fastlane ios release
```

Upload a build and submit it for App Store review (iOS)

----


## Mac

### mac test

```sh
[bundle exec] fastlane mac test
```

Run the unit tests on this Mac

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Archive and upload a macOS build to TestFlight

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Upload only the staged screenshots (fastlane/screenshots/mac), see scripts/screenshots/publish.sh

### mac release

```sh
[bundle exec] fastlane mac release
```

Upload a macOS build to App Store Connect (and optionally submit it)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
