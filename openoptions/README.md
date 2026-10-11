# OpenOptions — Phase 0 spike

Android companion/configuration app for Logitech HID++ devices (an Android replacement for Logitech Options).
The plan is in [`docs/plans/logi-options-replacement-android.md`](../docs/plans/logi-options-replacement-android.md).

This directory is a self-contained Gradle project. It lives inside the `flutter_notes` repository for now and
should move to its own repository once the spike passes.

## Modules

| Module | What it is |
|--------|------------|
| `core/hidpp` | Pure Kotlin HID++ 1.0 / 2.0 codec, request/response channel, feature discovery, and the `DeviceName`, `DeviceFwVersion` and battery features. No Android dependencies; fully unit-tested with a scripted fake device. |
| `app` | The spike UI plus the two transports: `UsbHidppTransport` (USB host, receiver or wired device) and `BleHidppTransport` (Logitech vendor GATT service on a bonded BLE device). |

## What the spike has to prove

Phase 0 exit criteria from the plan:

1. **USB OTG**: enumerate a Unifying or Bolt receiver, claim its HID++ interface, and read the name, type,
   firmware and battery of every paired device.
2. **BLE**: connect to a bonded MX-series device over the vendor GATT service and read the same.
3. Record which phones refuse the forced USB interface claim, and which BLE framing (with or without the
   report ID byte) the vendor service expects.

## Running it

Build locally (`./gradlew :app:assembleDebug`) or download the `openoptions-spike-debug` artifact from the
**Build OpenOptions** GitHub Actions run, then sideload `app-debug.apk`.

**USB**: plug the receiver into the phone through a USB OTG adapter. Accept the "open OpenOptions Spike?"
prompt (or tap *Refresh USB devices*, then *Probe*). The log shows every HID interface, which one was
claimed, and every HID++ frame in both directions.

**BLE**: pair the mouse or keyboard in Android's Bluetooth settings first. In the app, grant the Bluetooth
permission, tap *Refresh bonded devices*, then *Probe* next to the device. The app tries the frame format
without a report ID first, then with one, and logs which worked.

Use **Copy log to clipboard** and paste the log into an issue. A successful probe prints a line such as

```
probe [01] MX Master 3S · Mouse · HID++ 4.5 · 72%, Good, Discharging · Firmware MPM26.01.B001A · 12 features
```

## Tests

```
./gradlew :core:hidpp:test
```
