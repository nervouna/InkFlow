# Apple project foundation

`project.yml` is the canonical XcodeGen specification. The current aggregate
target is deliberately non-product: macOS, iOS container, keyboard extension,
shared adapter, and test targets are added only with their real implementations.

Generated `.xcodeproj` files are ignored. Signing identity and bundle prefix
belong in `Config/Signing.local.xcconfig`, created from the checked-in example.
