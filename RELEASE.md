# Manifold release process

Manifold `0.1.0` is an internal TestFlight release. Simulator CI is necessary,
but it is not the release gate: the uploaded build must be installed from
TestFlight and exercised on a physical iPhone before the `0.1.0` tag is cut.

## Prerequisites

- A physical iPhone or iPad running iOS/iPadOS 18 or newer, unlocked with
  Developer Mode on.
- Xcode signed into an Apple Developer account that can manage
  `com.manifoldkit.Manifold` and the `group.com.manifoldkit.apps` App Group.
- The Manifold app record created in App Store Connect for that bundle ID.
- `DEVELOPMENT_TEAM` set to the Apple Developer team ID. Do not store account
  credentials, API keys, or the team ID in this repository.

## Build gates

Run the complete simulator and macOS gate:

```bash
make build
make test
```

With the device connected, discover the Xcode destination identifier with the
Devices and Simulators window or `xcodebuild -project Manifold.xcodeproj
-scheme Manifold -showdestinations`, then run the signed UI-test gate:

```bash
make device-test IOS_DEVICE_ID='<device-udid>' DEVELOPMENT_TEAM='<team-id>'
```

## Archive and upload

The app version and build number live in `project.yml`. App Store Connect will
reject a reused build number, so increment `CURRENT_PROJECT_VERSION` before a
replacement upload while keeping `MARKETING_VERSION` at `0.1.0`.

```bash
make testflight-upload \
  IOS_DESTINATION='platform=iOS Simulator,name=<available-simulator>' \
  IOS_DEVICE_ID='<device-udid>' \
  DEVELOPMENT_TEAM='<team-id>'
```

The supported upload target reruns both test gates before it creates the signed
archive under the ignored `.artifacts/` directory and uploads it with Xcode's
authenticated account. Wait for App Store Connect processing to finish and
assign the build to the internal tester group.

## Physical-device acceptance

Install the uploaded build from TestFlight, not from Xcode, then record the
device model, iOS version, build number, tester, and result in the release PR.

- [ ] Fresh install reaches chat without a bootstrap failure.
- [ ] A session can be created, renamed, switched, and restored after relaunch.
- [ ] A supported model or cloud endpoint can be configured and produces a
      streamed reply; cancel and regenerate also complete correctly.
- [ ] API credentials survive relaunch in Keychain and are removed by delete.
- [ ] Microphone permission copy appears and denial does not break the composer.
- [ ] Tool approval supports approve-once, deny, and always-allow behavior.
- [ ] The theme picker updates the chat surface and survives normal navigation.
- [ ] The Ask Manifold App Intent reaches the running app and handles an
      unavailable model without losing the request.
- [ ] Background/foreground transitions and one force-quit/relaunch preserve
      data without a crash or blank root view.
- [ ] No release-blocking fault, hang, data loss, or credential leak is found.

Only after every item passes:

```bash
git tag -s 0.1.0 -m 'Manifold 0.1.0'
git push origin 0.1.0
```

If any item fails, leave the tag uncreated, fix forward in a PR, increment the
build number, and upload a replacement TestFlight build. Expire the superseded
build in App Store Connect once the replacement is available.
