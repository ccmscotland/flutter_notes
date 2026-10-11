# Android Replacement for Logitech Options — Application Plan

**Status:** Planning draft  
**Target platform:** Android 10+ (API 29+), phones, tablets, Samsung DeX  
**Working name:** *OpenOptions* (placeholder — must not use Logitech branding)  
**Date:** 2026-10-11

---

## 1. Goal

Logitech Options / Options+ only exists for Windows and macOS. Anyone using an MX Master, MX Anywhere, MX Keys, Lift, M720 or similar device with an Android tablet, phone or DeX desktop has no way to change DPI, SmartShift, scroll direction, F-key behaviour, backlight, or button assignments.

This app is an **Android configuration and companion app** for Logitech HID++ devices. It talks the same HID++ 2.0 protocol that Options, Solaar (Linux) and logiops (Linux) use, over USB OTG (Unifying / Bolt receiver) and Bluetooth LE (direct connection).

Two usage modes, both in scope:

| Mode | Description |
|------|-------------|
| **Daily driver** | Device is paired to the Android device. App applies settings on connect, runs per-app profiles, and executes actions for diverted buttons while the device is in use. |
| **Companion configurator** | Device is normally used with a PC. User plugs the receiver into the phone via OTG (or connects over BLE) to change *on-device persistent* settings (DPI, FN swap, button remaps stored on the device, Easy-Switch hosts, pairing). |

---

## 2. What Logitech Options does, and what is achievable on Android

| Options feature | Mechanism | Android feasibility | Phase |
|-----------------|-----------|---------------------|-------|
| Detect devices, show name / model / battery | HID++ 0x0005, 0x0003, 0x1000 / 0x1004 | ✅ Full | 1 |
| Pointer speed / DPI | 0x2201 Adjustable DPI, 0x2205 Pointer speed | ✅ Full (on-device) | 1 |
| SmartShift threshold, ratchet / free-spin | 0x2110 / 0x2111 SmartShift | ✅ Full | 1 |
| Scroll direction, hi-res scrolling | 0x2121 Hi-Res Wheel | ✅ Full | 1 |
| Thumb wheel direction / invert | 0x2150 Thumb wheel | ✅ Full | 1 |
| F-keys default vs media | 0x40A2 / 0x40A3 FN inversion | ✅ Full | 1 |
| Keyboard backlight level / timeout | 0x1982 Backlight v2/v3 | ✅ Full | 1 |
| Remap a button to another *device* key (e.g. thumb → Back) | 0x1B04 Reprogrammable Keys v4 `remap` field | ✅ Full, persists on device | 2 |
| Remap a button to an Android action (Home, Recents, screenshot, media, app launch, volume) | 0x1B04 `divert` + AccessibilityService / AudioManager / Intent | ✅ While app's service is running | 2 |
| Gesture button (hold + move) | 0x1B04 divert + raw XY, gesture recognition in app | ✅ Actions limited to what Android exposes | 2 |
| Per-application settings | AccessibilityService window-change events → foreground package | ✅ | 3 |
| Low battery notifications | 0x1000 / 0x1004 events | ✅ | 3 |
| Easy-Switch: see / rename hosts, change host | 0x1814 Change Host, 0x1815 Hosts Info | ✅ | 4 |
| Unifying pairing / unpairing | HID++ 1.0 receiver registers (0xB2 / 0xB5) | ✅ USB only | 4 |
| Bolt pairing of a *new* device | Bolt pairing protocol (receiver-side BLE-style bonding) | ⚠️ Needs reverse-engineering spike | Future |
| Arbitrary keyboard shortcut injection (Ctrl+C etc.) | Options injects OS key events | ❌ Not possible on Android without root. Mitigation: remap to device-side keys via 0x1B04 and HID++ 0x1C00 where supported. | — |
| Flow (cross-computer cursor) | Host-side network protocol | ❌ Out of scope | — |
| Firmware update (DFU) | 0x00C2 DFU | ❌ Out of scope (brick risk, no update feed) | — |
| Smart Actions / macros | Host-side scripting | ⚠️ Limited to chains of Android actions | Future |

---

## 3. Transport Layer — the hard part

### 3.1 USB OTG (Unifying / Bolt receiver, or wired devices)

- Android `UsbManager` host API. Receiver enumerates as a composite HID device (VID `0x046D`; Unifying PID `0xC52B`, Bolt PID `0xC548`, plus others).
- Claim the **HID++ interface** (the one whose report descriptor contains vendor usage page `0xFF00` / `0xFF43`; on Unifying it is interface 2) with `claimInterface(intf, force = true)` so the kernel `usbhid` driver releases it. The keyboard / mouse interfaces stay with the system so input keeps working.
- Reports: `0x10` short (7 bytes), `0x11` long (20 bytes), `0x20` / `0x21` very long. Write via `controlTransfer(SET_REPORT)` or the interrupt OUT endpoint; read via a bulk/interrupt-IN reader thread using `UsbRequest`.
- Receiver multiplexing: device index `0xFF` = receiver itself (HID++ 1.0 registers), `0x01–0x06` = paired devices.
- Requires the `android.hardware.usb.host` feature and a runtime USB permission dialog per receiver (can be made persistent with an `intent-filter` + `device_filter.xml`).
- Risk: some OEM kernels refuse `force` claims on HID interfaces. Mitigation: detect and show a clear "unsupported on this phone" message; the BLE path still works.

### 3.2 Bluetooth LE (direct)

- Android **blocks** third-party apps from the standard HID over GATT service (`0x1812`); reads fail with a `BLUETOOTH_PRIVILEGED` error since Android 5. So the HID report route used by Linux is **not available**.
- Logitech devices expose a **separate vendor GATT service** `00010000-0000-1000-8000-011F2000046D` (characteristic `00010001-…`, write + notify) that carries HID++ frames outside HOGP. This is the path the app must use. The device must already be **bonded** to Android (the user pairs it normally in Settings); the app then opens its own `BluetoothGatt` to the bonded device and enables notifications on the vendor characteristic.
- Frames over BLE omit the report ID; the app prepends/strips `0x11` as needed to reuse the same codec as USB.
- Use `CompanionDeviceManager` to associate the device, get `REQUEST_COMPANION_RUN_IN_BACKGROUND` / `REQUEST_COMPANION_USE_DATA_IN_BACKGROUND`, and `startObservingDevicePresence` so the service wakes when the mouse connects.
- Permissions: `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` (API 31+), `ACCESS_FINE_LOCATION` on API 29–30.
- Bluetooth **Classic** Logitech devices (pre-2016) have no accessible channel on Android → unsupported; detect and tell the user.

### 3.3 Transport abstraction

```
interface HidppTransport {
    val events: Flow<HidppFrame>         // notifications & responses
    suspend fun send(frame: HidppFrame)
    suspend fun close()
}
class UsbReceiverTransport : HidppTransport   // one per receiver, routes by device index
class BleTransport : HidppTransport           // one per bonded device
```

A `HidppChannel` on top handles software-ID matching, timeouts/retries, HID++ 1.0 vs 2.0 detection (`0x0000` IRoot ping), and error codes.

---

## 4. Architecture

### 4.1 Technology decision

**Recommended: native Kotlin + Jetpack Compose.**

Reason: the component that must run when there is no UI — the foreground service that keeps the USB/BLE channel open, receives diverted button events, and performs AccessibilityService actions — has to be Kotlin regardless. If the UI were Flutter, the whole protocol stack would still live in a Kotlin plugin and the Flutter engine would have to be booted in the background just to show settings, which gains nothing. A pure-Kotlin app is smaller, starts faster, and avoids a platform-channel seam through the middle of the design.

**Alternative (acceptable):** Flutter UI (matches this repository's stack) over a Kotlin plugin `hidpp_core` exposing `MethodChannel`/`EventChannel`. All of sections 3, 4.3, 5 and 6 stay in Kotlin either way; only the screens in section 7 move. Decide at the end of Phase 0.

### 4.2 Module layout

```
app/                         Compose UI, navigation, DI wiring
core/hidpp/                  Pure-Kotlin HID++ codec, feature registry, no Android deps (unit-testable)
core/transport-usb/          UsbReceiverTransport
core/transport-ble/          BleTransport + CompanionDeviceManager glue
core/devices/                Known-device database (PIDs, names, button CIDs, icons)
core/settings/               Room DB: devices, profiles, per-app rules, action bindings
core/actions/                Action engine (AccessibilityService, media keys, intents, gestures)
service/                     Foreground service, connection supervisor, battery monitor
```

### 4.3 HID++ feature set (Kotlin objects, one per feature ID)

| Feature | ID | Used for |
|---------|----|----------|
| IRoot / IFeatureSet | 0x0000 / 0x0001 | Protocol version, enumerate features |
| Device FW / Name / Type | 0x0003 / 0x0005 | Model, firmware string, device kind |
| Battery (unified / status) | 0x1004 / 0x1000 / 0x1001 | Level, charging, warnings |
| Reprogrammable Keys v4 | 0x1B04 | Button list, remap, divert, raw XY |
| Report Rate | 0x8060 | Polling rate (gaming devices) |
| Adjustable DPI | 0x2201 | DPI list, current DPI |
| Pointer Speed | 0x2205 | Sensitivity |
| SmartShift / Enhanced | 0x2110 / 0x2111 | Ratchet mode, threshold |
| Hi-Res Wheel | 0x2121 | Direction, resolution, divert |
| Thumb Wheel | 0x2150 | Direction, divert |
| FN Inversion | 0x40A2 / 0x40A3 | F-key default |
| Backlight v2/v3 | 0x1982 | Level, timeout |
| Keyboard Layout | 0x4520 | Layout detection |
| Change Host / Hosts Info | 0x1814 / 0x1815 | Easy-Switch |
| Wireless Status | 0x1D4B | Link events |
| Onboard Profiles | 0x8100 | Gaming mice (read-only, later) |

Capability-driven UI: each screen section renders only if the feature exists on the device, so unknown devices still get a sensible page.

---

## 5. Data Model

```
Device            id, transport (usb|ble), serial/unitId, pid, name, lastSeen, bleAddress?, receiverIndex?
DeviceSettings    deviceId, dpi, pointerSpeed, smartShiftMode, smartShiftThreshold, wheelInverted,
                  thumbWheelInverted, hiResScroll, fnSwap, backlightLevel, backlightTimeout
Profile           id, deviceId, name, isDefault
ProfileAppRule    profileId, packageName           (profile activates when package is foreground)
ButtonBinding     profileId, controlId (CID), mode (device_default|remap_cid|android_action|gesture),
                  targetCid?, actionJson?
GestureBinding    buttonBindingId, direction (up|down|left|right|tap), actionJson
```

Settings are stored locally (Room). On every connect the service re-applies `DeviceSettings` and the active profile's bindings; device-side remaps persist in the device itself, divert bindings are re-asserted each session.

---

## 6. Action Engine (divert → Android)

| Action type | Implementation | Needs |
|-------------|----------------|-------|
| Back / Home / Recents / Notifications / Quick Settings / Lock / Screenshot / Power dialog | `AccessibilityService.performGlobalAction` | Accessibility service enabled |
| DPAD / Tab navigation (API 33+) | `GLOBAL_ACTION_DPAD_*` | Accessibility |
| Media play/pause/next/prev | `AudioManager.dispatchMediaKeyEvent` | none |
| Volume up/down/mute | `AudioManager.adjustStreamVolume` | none |
| Launch app / shortcut / URL | `Intent` from foreground service | none |
| Gesture button swipes (desktop switch, app switcher) | divert + raw XY → `dispatchGesture` or global action | Accessibility |
| Switch to Easy-Switch host N | HID++ 0x1814 | none |
| Cycle DPI | HID++ 0x2201 | none |
| Toggle SmartShift | HID++ 0x2110 | none |
| Keyboard shortcut (Ctrl+C …) | **Not possible** — offer "remap to device key" instead | — |

The AccessibilityService is optional: the app works for all on-device settings without it, and the UI explains exactly which actions need it. Google Play requires the `accessibilityservice` metadata description and a prominent in-app disclosure; the service must be a true input-assistance use case, which this is.

---

## 7. Screens

| Screen | Contents |
|--------|----------|
| **Devices** | List of known devices with connection state, transport icon, battery. "Add device" explains OTG and BLE paths. |
| **Device → Overview** | Model image, firmware, battery graph, serial, Easy-Switch host slots with rename / switch. |
| **Device → Pointer** | DPI slider with device's supported steps, pointer speed, SmartShift mode + threshold, scroll direction, hi-res, thumb wheel. |
| **Device → Keyboard** | FN swap, backlight level/timeout, layout. |
| **Device → Buttons** | Diagram of buttons from the known-device DB (fallback: list of CIDs with names from 0x1B04). Tap a button → choose Device default / Device key / Android action / Gesture. |
| **Profiles** | Per-device profile list, each with app rules. |
| **Receiver** (USB) | Paired slots, pair new (Unifying), unpair. |
| **Settings** | Enable accessibility, battery notifications, run on boot, theme, export/import settings JSON. |
| **Diagnostics** | Live HID++ frame log, raw send console, feature table dump, "copy report for issue". |

Material 3, dynamic colour, phone and tablet layouts (list–detail on ≥ 600 dp, mirroring the shell approach used in Flutter Notes).

---

## 8. Background Service

- Foreground service (`foregroundServiceType="connectedDevice"`), started on USB attach broadcast, CDM device-presence callback, or boot (if enabled).
- Supervises one `HidppChannel` per device; exponential-backoff reconnect; releases USB interface on detach.
- Persistent notification shows connected devices and battery; low-battery alert at 10 %.
- Listens to `TYPE_WINDOW_STATE_CHANGED` from the AccessibilityService to pick the profile.
- Battery-optimisation guidance screen (request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only when BLE background mode is enabled).

---

## 9. Phased Roadmap

| Phase | Duration | Deliverable | Exit criteria |
|-------|----------|-------------|---------------|
| **0 — Feasibility spike** | 2 weeks | Throwaway Kotlin app | (a) OTG: enumerate Unifying + Bolt receivers, claim HID++ interface, read device name + battery. (b) BLE: connect to bonded MX Master 3S vendor service, get name + battery. (c) Decide Compose vs Flutter UI. Document any phones that refuse the USB claim. |
| **1 — Core settings** | 4 weeks | Devices list, Overview, Pointer, Keyboard screens; settings re-applied on connect | Works on MX Master 3/3S, MX Anywhere 3, MX Keys, Lift, M720 over both transports. Unit tests for codec and every feature. |
| **2 — Buttons** | 4 weeks | Button diagram, on-device remap, divert + action engine, gesture button | All actions in §6 work; accessibility onboarding; no stuck buttons when service dies (undivert on stop). |
| **3 — Profiles & background** | 3 weeks | Per-app profiles, CDM presence, foreground service, battery notifications | Profile switch < 200 ms after app change; service survives screen off for 8 h on BLE. |
| **4 — Receiver & hosts** | 3 weeks | Unifying pair/unpair, Easy-Switch rename/switch, diagnostics screen | Pairing a second device through the phone works; diagnostics export used for bug reports. |
| **5 — Release** | 2 weeks | Play Store + F-Droid builds, docs, device-support matrix | Play review passed with accessibility disclosure; crash-free rate ≥ 99.5 % in beta. |
| **Future** | — | Bolt pairing, onboard profiles for G-series, macro chains, Wear OS battery tile | — |

---

## 10. Testing Strategy

- `core/hidpp` is pure Kotlin: table-driven tests from captured frames (Solaar's and logiops' documented examples) for every feature encode/decode.
- Fake transport that replays recorded USB/BLE sessions, so the full settings pipeline is testable in CI without hardware.
- Hardware lab checklist per release: receivers (Unifying, Bolt), devices (MX Master 3, 3S, Anywhere 3, MX Keys, MX Keys Mini, Lift, M720, Pebble), phones (Pixel, Samsung, OnePlus), one tablet with DeX.
- Safety tests: service kill → device buttons return to default (undivert); pulling the receiver mid-write leaves the device usable.

---

## 11. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| OEM blocks `claimInterface(force)` on HID interfaces | USB path unusable on some phones | Detect in Phase 0; BLE path independent; publish support matrix |
| Logitech changes the vendor GATT service on new devices | BLE path breaks for new models | Feature discovery is dynamic; diagnostics screen makes user reports actionable |
| Play Store rejects AccessibilityService use | No Android-action bindings | Service optional; clear disclosure; policy-compliant use case (input device assistance) |
| Trademark | Takedown | Neutral app name, no Logitech logos, "works with Logitech HID++ devices" wording only |
| Bricking via wrong register writes | Device damage | No DFU, no raw writes outside Diagnostics (gated behind a warning), only documented features |
| Background battery drain on BLE | Uninstalls | CDM presence instead of scanning; idle channel after 60 s with no events |

---

## 12. Phase 0 Results (2026-10-11)

Spike build from branch `ccr-c670a67e-k84qbf`, run on a phone with an MX Keys Mini and an MX Anywhere 3S bonded over Bluetooth.

| Question | Answer |
|----------|--------|
| Does the vendor GATT service exist and can an app subscribe to it? | **Yes.** Service `00010000-0000-1000-8000-011F2000046D`, characteristic `00010001-…` with read, write, write-without-response and notify. CCCD write succeeds on a bonded device. |
| What framing does it expect? | **The 18-byte HID++ long-report body only**, no report ID and no device index, sent as an ATT Write Request. 19- and 20-byte writes are rejected with GATT 0x0D `INVALID_ATTRIBUTE_LENGTH`. Replies arrive as 18-byte notifications of the same shape. This is the layout a Bolt receiver forwards to the device. |
| Does the full probe work? | **Yes.** MX Keys Mini: HID++ 4.5, name, type, battery (0x1004), firmware `RBK73.04.B0016`, 32 features enumerated. About 65 ms per request. |
| USB OTG | **Not yet tested** (no receiver attached during the runs). |
| Pitfalls found | A device bonded on several Easy-Switch channels appears once per channel address; only the live one connects, the rest fail with status 147 after 10 s. `requestMtu` sometimes never calls back on the MX Anywhere 3S; the default MTU is enough, so the app no longer requests one. |

Decision: BLE direct is a viable primary transport. Phase 1 proceeds with `BleHidppTransport` as designed, body-only framing hard-coded, and the framing experiment kept only as a diagnostics fallback.

### Phase 1 and Phase 2 spike results (2026-10-12)

| Check | Result |
|-------|--------|
| Settings writes round-trip | Backlight on/off on MX Keys Mini: write accepted, re-read matches. Backlight record decodes to 8 levels, automatic mode, 30 s / 300 s timeouts (Solaar's little-endian layout confirmed). |
| Divert a key and receive its event | Mute key (0x00E7) on MX Keys Mini and middle (0x0052) and back (0x0053) buttons on MX Anywhere 3S: `setCidReporting` accepted, `getCidReporting` confirms diverted, every press arrives as a 0x1B04 divertedButtons notification followed by the empty-set release. |
| Fire an Android action | Quick settings and Recent apps via `AccessibilityService.performGlobalAction` returned true; Volume up via `AudioManager` worked. Press-to-action latency about 5 ms after the notification. |
| Undivert | "Device default" restores the button; device confirms `diverted=false`. |
| Unsolicited events | A UnifiedBattery event arrived on its own while idle (95 %, charging), so the notification path also serves live battery. |

Decision: every unknown in the plan is now resolved on real hardware. The remaining work is product engineering: app structure, persistence, background service, per-app profiles, remapping UI, receiver support via USB OTG (still untested for lack of a receiver).

---

## 13. Reference Material

- Logitech HID++ 2.0 feature specifications (public PDFs via Logitech's developer drive, mirrored in the Solaar repository under `docs/`).
- Solaar (`pwr-Solaar/Solaar`) — feature IDs, receiver registers, device database.
- logiops (`PixlOne/logiops`) — divert / gesture handling, Hi-Res wheel, thumb wheel.
- libratbag — DPI and onboard-profile handling.
- Android docs: USB host, Companion Device Manager, AccessibilityService global actions, foreground service types.
- The MX Master's proprietary GATT service `00010000-0000-1000-8000-011F2000046D` is documented in community captures (W3C Web Bluetooth list, 2017); Android's refusal of the standard HID GATT service without `BLUETOOTH_PRIVILEGED` is documented in the Nordic DevZone thread referenced in the planning discussion.
