fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac create_profile_keychain

```sh
[bundle exec] fastlane mac create_profile_keychain
```

Creates the CI signing keychain (no-op off CI)

### mac certificates

```sh
[bundle exec] fastlane mac certificates
```

Installs the Developer ID Application certificate via match (pass readonly:true on CI)

### mac sign

```sh
[bundle exec] fastlane mac sign
```

Signs and verifies the release binaries in builds/ with the Developer ID identity

### mac notarize_binaries

```sh
[bundle exec] fastlane mac notarize_binaries
```

Notarizes the zipped release binaries (builds/*.zip) with notarytool

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
