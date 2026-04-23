# Apple tests

## Unit (XCTest — to wire up)

`Tests/UnitTests/` — XCTest, mocks via Swift protocols (no third-party
mocking framework).

To enable, add to `clients/apple/project.yml`:

```yaml
  MadFrogVPNTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests/UnitTests
    dependencies:
      - target: MadFrogVPN
    settings:
      base:
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/MadFrogVPN.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MadFrogVPN"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

Then run `xcodegen generate` and `xcodebuild test -scheme MadFrogVPNTests`.

CI auto-detects the target — see `.github/workflows/ios.yml` (job `build`,
last step). Until target exists, that step prints "skipping".

Coverage target: 60% of `MadFrogVPN/Models/` (UI views are covered by UI
tests separately).

Priority unit tests (per ROADMAP):
- `ConfigStoreTests` — migration + Keychain read/write race
- `APIClientTests` — race-cancellation, retry logic, timeout
- `ConfigSanitizerTests` — sing-box config validation rules
- `VPNErrorMapperTests` — NSError → user-facing string mapping

## UI (XCUITest — later)

`Tests/UITests/` — onboarding → connect → disconnect → server selection
flows. NOT testing real VPN tunnel — only UI state machine.
