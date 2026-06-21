# Flashback Remote

Standalone iOS utility app for the **Flashback ONE35 V2** film camera.

- **Removes the 27-photo roll limit** — set any roll length up to 100 frames
- **Wireless file transfer** — download DNGs and JPEGs over the camera's built-in WiFi, no cable needed
- **Embedded RAW editor** — the Flashback PWA runs directly inside the app
- No Mac required, no USB, no subscription

---

## Install via SideStore

### Requirements
- iPhone running iOS 16 or later
- [SideStore](https://sidestore.io) installed (one-time setup)
- The **official Flashback app** installed and connected to your camera at least once (creates the Bluetooth bond)

### Steps

1. Install [SideStore](https://sidestore.io) on your iPhone if you haven't already
2. Open SideStore → **Sources** tab → tap **+**
3. Paste this URL and tap **Add Source**:
   ```
   https://raw.githubusercontent.com/deknared/flashback-remote/main/sidestore-source.json
   ```
4. Find **Flashback Remote** in the source → tap **Install**
5. SideStore re-signs the app with your Apple ID automatically — no developer account needed

SideStore checks for updates automatically. New releases appear in SideStore within a day.

---

## First use

1. Open the **official Flashback app** and connect it to your camera (if you haven't done this, the BLE bond won't exist and the app cannot talk to the camera)
2. Wind the camera — the ONE35 V2 only advertises over Bluetooth when the shutter is wound
3. Open **Flashback Remote** → **Camera** tab → tap **Scan for Camera**
4. The camera appears within ~5 seconds — check firmware status badge, battery, shots remaining
5. Set your roll length with the stepper (default 36, max 100)
6. Tap **Configure & Start WiFi**
   - The app authenticates over BLE, writes the roll config, and triggers the camera's WiFi hotspot
   - On first connection you may see a 2-second pause — this is normal (BLE encryption renegotiation)
7. Tap **Join Camera Network** when it appears — iOS connects to the ONE35 WiFi automatically
8. **Files** tab opens — tap **Download All** to transfer everything

---

## Firmware compatibility

The app fetches [`flashback-protocol.json`](flashback-protocol.json) from this repo on every launch and caches it for 24 hours. No app update needed when firmware changes.

| Firmware | Status |
|----------|--------|
| 0.9.6 | ✅ Confirmed working |

A coloured dot on the Camera tab shows status at a glance:
- 🟢 **Confirmed** — tested and working
- 🟡 **Untested** — in the config but not yet tested
- 🔴 **Broken** — known to fail; check for an app update
- ⚪ **Unknown** — firmware not in config yet; try it and report back

### Reporting a new firmware version

If you update your camera firmware and want to report whether the app still works:

1. Fork this repo
2. Edit [`flashback-protocol.json`](flashback-protocol.json) — add an entry for your firmware version with `"status": "confirmed_working"` or `"broken"`
3. Open a PR

All installed copies of the app pick up the change on next launch — no rebuild needed.

---

## Known unknowns

| Question | Current assumption |
|----------|-------------------|
| Does the roll limit persist across power cycles? | Probably resets — run the app before each shoot |
| Does it reset when you eject the roll? | Unknown |
| Does `filmTypeId: 1` affect the limit? | Unknown — using `1` as safe default |
| Does the BLE bond survive a camera firmware update? | Unknown — re-pair with official app if needed |
| Exact camera WiFi SSID format | Assumed `ONE35-XXXX` — app joins any SSID starting with `ONE35` |

---

## Creating a release (for repo owners)

GitHub Actions builds an unsigned IPA on every push. To create a versioned release that SideStore users can install:

```bash
git tag v1.0
git push --tags
```

This triggers the workflow to:
1. Build the IPA
2. Attach it to a GitHub Release
3. Update `sidestore-source.json` with the download URL and file size automatically

SideStore users see the new version within their next refresh.

---

## Build from source

Requires Xcode 15+ on macOS.

```bash
git clone https://github.com/deknared/flashback-remote
open flashback-remote/flashback-remote.xcodeproj
```

Connect an iPhone (must already have the official Flashback app's BLE bond), build and run.

For CI: GitHub Actions produces an unsigned IPA on every push to `main`. Download it from the **Actions** tab → latest run → **Artifacts**.

---

## Technical notes

The BLE protocol is fully reverse-engineered from the official Android APK and observed BLE traffic. Key points:

- The camera uses an encrypted BLE link. The official Flashback iOS app creates a bond during first-time setup; iOS caches the Long Term Key system-wide. This app reuses that cached key — it never extracts or transfers the key.
- On first write the link may not be encrypted yet. CoreBluetooth returns `insufficientEncryption`; the app waits 2 seconds and retries once. iOS uses the cached LTK to complete renegotiation in the background. This is exactly how the official app works.
- Roll config is a JSON payload written to characteristic `FB20` (fallbacks `FB21`/`FB22`/`FB23`): `{"filmTypeId":1,"length":36,"rollId":8372910}`. The `rollId` is randomised per write.
- The camera's WiFi hotspot is triggered by writing `0x02` to `FB01` then `0x01` to `FB04`. Files are served over HTTP from `192.168.4.1`.

**This only works on a phone that has already paired with the camera through the official app.** It cannot connect to someone else's camera.
