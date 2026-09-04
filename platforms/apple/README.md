# Apple frontends

`project.yml` is the only editable Xcode project definition. It generates a
shared Swift static adapter, a macOS InputMethodKit application, an iOS host
application, an iOS keyboard extension, and macOS unit tests.

The macOS input method and iOS keyboard extension are the only targets that
initialize InkFlow. The iOS host is an enablement screen and does not link the
engine. Both IME processes retain one runtime for their process lifetime and
create or close sessions as controllers come and go.

## Generate and verify

Build the three production-core slices and deploy the canonical schema before
generating the project:

```sh
./platforms/apple/Scripts/build-core.sh
./platforms/apple/Scripts/stage-schema.sh
xcodegen generate --spec platforms/apple/project.yml --project platforms/apple
```

Run the complete signing-disabled acceptance gate with:

```sh
./tools/verify/apple.sh
```

The gate builds macOS arm64 and iOS Simulator arm64. It also packages an iOS
device arm64 core slice, but it does not sign, install, launch, or exercise a
physical device.

## Generated boundaries

- `Generated/InkFlowEngine.xcframework` contains three self-contained static
  slices. Each slice merges the InkFlow wrapper, librime, yaml-cpp, LevelDB,
  OpenCC, and marisa before the XCFramework is assembled.
- `Generated/Schema` is deployed from `schemas/source`. It is a read-only build
  resource, not another editing surface.
- User data and staging data are created under platform-writable Application
  Support and Caches locations at runtime.
- `InkFlow.xcodeproj`, all generated resources, native products, and DerivedData
  are ignored.

## Signing configuration

The checked-in project has no Team ID. `Config/Base.xcconfig` supplies a neutral
bundle-ID prefix. For an explicitly chosen local team or prefix, copy
`Config/Signing.local.xcconfig.example` to the ignored
`Config/Signing.local.xcconfig` and edit the copy. The repository never chooses
or inspects a signing identity.

The iOS extension requests no open access, App Group, or network permission.
macOS candidate presentation uses the system `IMKCandidates` panel.
