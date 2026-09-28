# walkplay-eqloader

An app for editing parametric EQ and pushing it to Walkplay-based USB DAC dongles (e.g. the Crinear Protocol Micro) without the vendor's app. It also generates EQ from headphone measurements with AutoEQ.

Runs on Linux, Windows, macOS, Android and in the browser. This is the Flutter rewrite of the original Python/Tkinter tool, which lives on in the [`legacy-tkinter`](../../tree/legacy-tkinter) branch.

## Download

**In the browser, no install:** [devilapi.github.io/walkplay-eqloader](https://devilapi.github.io/walkplay-eqloader/) (Chrome, Edge or Opera on a desktop computer; see [Browser](#browser)). The [dev preview](https://devilapi.github.io/walkplay-eqloader/preview/) runs the latest commit.

Or get the latest build from [Releases](../../releases):

| Platform | File | Status |
|---|---|---|
| Android | `…-android.apk` | Tested |
| Linux x64 / arm64 | `…-linux-x64.tar.gz` | Tested |
| Linux arm64 | `…-linux-arm64.tar.gz` | **Untested** |
| Windows x64 | `…-windows-x64-setup.exe` (installer), `…-windows-x64.zip` (portable) | Tested |
| Windows arm64 | `…-windows-arm64-setup.exe` (installer), `…-windows-arm64.zip` (portable) | **Untested** |
| macOS (Intel + Apple Silicon) | `…-macos-universal.zip` | **Untested** |

`v1.<number>` releases (v1.1, v1.2, ...) are the regular releases. `dev-<number>` pre-releases are automatic builds of the latest commit and may be unstable.

Device support on Windows, macOS and in the browser is new and hasn't been tried on real hardware yet. If it works for you, or doesn't, please [open an issue](../../issues).

## Features

- **Visual EQ editor**: tap/click the graph to add a band, drag a handle to move it. Right-click (mouse) or long-press (touch) a handle to delete it. Values can also be typed in, and several selected bands can be edited at once.
- **Filter types**: Peaking (PK), Low Shelf (LSQ), High Shelf (HSQ), Low Pass (LP), High Pass (HP). Q can be shown as bandwidth in octaves (Settings).
- **Device**: push the EQ to any PEQ slot, load the current EQ back from the device, and enable/disable PEQ per slot.
- **Profile library**: keep named profiles in the app, load one with a tap, and see which profile is on which device slot.
- **Profile files**: save and load the `.txt` format used by EqualizerAPO and eq.hangout.audio.
- **AutoEQ**: pick a headphone/IEM model from the [AutoEq](https://github.com/jaakkopasanen/AutoEq) database and generate EQ bands plus a clip-safe preamp, or load the profile the AutoEq project already computed for it.
- **Flat reference line** on the graph: the level you hear with the EQ off, shifted by the preamp.
- **Undo/redo** for all editor changes.
- **Installable web app** that keeps working offline.
- **Phone layout**: the graph stays on top and the controls are split into EQ, Device, Profiles and Settings tabs.

## Setup

### Browser

Open the [web app](https://devilapi.github.io/walkplay-eqloader/) in Chrome, Edge or Opera on a desktop computer. It talks to the dongle through [WebHID](https://developer.mozilla.org/en-US/docs/Web/API/WebHID_API), which Firefox, Safari and mobile browsers don't support; use the Android app on phones.

Plug in the dongle, open the **Device** section and click **Connect Device**, then pick the dongle in the browser's prompt. The browser remembers the permission, so on later visits the dongle shows up after **Refresh List**.

On Linux, the browser needs the same udev rule as the Linux app (see [Linux](#linux)).

Differences from the installed app: AutoEQ can only use the online database (no local folder), and saved profile files go to your downloads folder. The profile library and settings are stored in the browser.

To install it as an app, use **Settings → Install as an app**, or the install icon in the address bar. Once loaded, it works offline, including AutoEQ models you've opened before.

### Android

Install the APK and connect the dongle over USB-C / OTG. Android asks for permission to access the USB device the first time the app uses it; allow it.

### Windows

Run the `-setup.exe` installer, or extract the portable zip anywhere and run `eqloader.exe`. No driver is needed; the dongle uses the built-in Windows HID driver.

The installer adds a Start menu entry and an uninstaller (Settings → Apps). It can install for all users or, without admin rights, just for you. Running a newer installer upgrades an existing installation. The installer isn't code-signed, so Windows SmartScreen may warn "Windows protected your PC"; click **More info → Run anyway**.

Installers are only built for `v1.<number>` releases; `dev-<number>` builds come as the portable zip only.

### macOS

Extract the zip and move `eqloader.app` to Applications. The app isn't signed, so the first time, right-click it and choose **Open** to get past Gatekeeper.

### Linux

Extract the archive and run `eqloader` from the extracted folder.

Raw HID access needs a udev rule, so the app can talk to the dongle without root:

```
sudo cp linux/99-walkplay-hid.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then replug the dongle. The rule file is [`linux/99-walkplay-hid.rules`](linux/99-walkplay-hid.rules) in this repository.

File dialogs use `zenity` (or `kdialog`), which most desktops already have.

## Usage

Plug in the dongle and click **Refresh List** (F5); it appears in the Device list. In the browser, click **Connect Device** first. Select it to use it for all device actions. With several Walkplay devices, pick the right one or enter its PID.

On phones and small screens, **Push EQ to Device** and **Load EQ from Device** are also in the top bar, so they're reachable from every tab.


### Building an EQ

1. Tap the graph to place a band, then drag it, or type exact values in the **Selected Filter** panel. Changes apply immediately.
2. Pick the filter type in **Type**.
3. To edit several bands at once, Ctrl-/Shift-click them in the **Filters** list (long-press on touch); a changed field applies to all selected bands.
4. Set **Slot** and **Preamp** and click **Push EQ to Device**. You're asked to confirm before the slot is overwritten.

The dashed **FLAT** line on the graph is the level with the EQ off. The preamp lowers everything you hear, so the line moves the opposite way: with a −6 dB preamp it sits at +6 dB. Where the curve is above it, the EQ is louder than no EQ. Toggle it with **FLAT** in the graph's corner.

### Preamp and buffer

The Protocol Micro always attenuates its output by a fixed 5 dB, set as **Settings → Hardware buffer** (default `-5`). The device only stores the preamp beyond that, in whole dB: a preamp of −4.4 dB needs no extra attenuation, −9.6 dB is stored as 5 dB extra. **Load EQ from Device** reports the resulting preamp (stored value + buffer), so an exact preamp only survives through a saved profile file. If your device has no such buffer, set it to `0`.

### Max filters

**Settings → Max filters** (default `8`) is the number of PEQ bands the device stores. Pushes are padded with inert 0 dB bands, because otherwise the device fills unused slots with copies of the last band. If the EQ has more bands than this, you're warned first: the device would silently drop the extras.

### AutoEQ

1. Click **Compute AutoEQ** (Ctrl+Shift+A).
2. The first time, choose **Download Online Database** (the AutoEq measurements on GitHub) or **Choose Local Folder...** with measurement `.txt`/`.csv` files. The choice is remembered.
3. Search for your model and select it. The same model often has measurements from several sources, shown in brackets. Downloads are cached. **Browse File Instead...** uses a single local file, **Change Database...** switches the source.
4. Pick a target: flat, a target from AutoEq's library (Harman, diffuse field, ...), or your own target file.
5. The generated bands and preamp replace the current EQ. Review them, then push.

> **Note:** Computing AutoEQ yourself is an experimental feature. It works, but results can differ from what autoeq.app or hangout.audio produce for the same measurement. For a well-tested result, use **Load Pre-computed AutoEQ** instead.

**Load Pre-computed AutoEQ** (Ctrl+Shift+L) skips the optimizer: pick a model from the online database the same way, and it loads the `ParametricEQ.txt` the AutoEq project computed for that measurement. If there are several (one per target), you pick one. This only works for models from the online database.

The AutoEQ database is fetched from GitHub, so AutoEQ needs an internet connection; everything else works offline.

### Profile library

The **Library** panel (the **Profiles** tab on phones) keeps named profiles in the app.

- **Save to Library** (bookmark icon, Ctrl+Shift+S) stores the current EQ under a name. The profile you're editing is marked with a check until you change it.
- Tap a profile to load it (undoable). Its menu has **Rename**, **Export to File** and **Delete**.
- **Import File to Library** adds a `.txt` profile.
- Pushing records which profile went to which slot, and **Load EQ from Device** recognizes a library profile on the device. The **Device** panel lists this per slot for the selected dongle.

### Profile files and backups

- **Load Profile from File** loads a `.txt` profile. OFF bands, zero-gain bands and duplicate bands are dropped.
- **Save Profile to File** saves the current EQ and preamp.
- To back up the device, use **Load EQ from Device**, then **Save Profile to File** or **Save to Library**.

### Settings

**Settings** (the gear icon; a tab on phones) has the flat reference line, Q as bandwidth, **Max filters**, **Hardware buffer**, installing the web app, the **Log** (device messages, plus diagnostics to paste into an issue) and **About** (version and links to this repository).

**Get Slot / Version** (Ctrl+G) shows the dongle's firmware version, active slot and what was last written to that slot.

### Enabling / disabling the EQ

**PEQ Enable / Disable** switches the device EQ on or off for a slot without changing what's stored, e.g. for A/B comparisons. Not all devices support this.

### Keyboard shortcuts

Shortcuts are also shown when hovering over a button.

| Shortcut | Action |
|---|---|
| Ctrl+Z | Undo |
| Ctrl+Y / Ctrl+Shift+Z | Redo |
| Ctrl+B | Add Band |
| Ctrl+D | Delete Band |
| Ctrl+Shift+D | Delete All |
| Ctrl+E | Load EQ from Device |
| Ctrl+S | Save Profile to File |
| Ctrl+Shift+S | Save to Library |
| Ctrl+O | Load Profile from File |
| Ctrl+Shift+A | Compute AutoEQ |
| Ctrl+Shift+L | Load Pre-computed AutoEQ |
| Ctrl+P | Push EQ to Device |
| F5 | Refresh List |
| Ctrl+G | Get Slot / Version |
| Ctrl+Shift+E | Enable PEQ |
| Ctrl+Shift+X | Disable PEQ |

## Profile format

The EqualizerAPO / eq.hangout.audio `.txt` format. Decimal commas and points both work.

```
Preamp: -6,0 dB
Filter 1: ON PK Fc 1000,0 Hz Gain 3,5 dB Q 1,000
Filter 2: ON LS Fc 80,0 Hz Gain -2,0 dB Q 0,707
Filter 3: OFF PK Fc 100,0 Hz Gain 0,0 dB Q 1,000
```

Filter types: `PK`, `LS`/`LSC`/`LSQ`, `HS`/`HSC`/`HSQ`, `LP`, `HP`. OFF bands and peaking/shelf bands with 0 dB gain are treated as disabled.

## Supported hardware

Walkplay-vendor HID devices (VID `0x3302`). Tested on the **Crinear Protocol Micro** (PID `0xC20F`). Other Walkplay dongles may work; please open an issue if yours behaves differently.

## Command line

The Flutter app has no CLI yet. For pushing and pulling profiles from scripts, use `eqloader.py` from the [`legacy-tkinter`](../../tree/legacy-tkinter) branch.

## Building from source

Needs the [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel).

```
flutter pub get
flutter test
flutter run                      # run on this machine
flutter build apk --release      # or: linux, windows, macos, web
```

Each desktop platform has to be built on that platform. Linux builds need `clang cmake ninja-build pkg-config libgtk-3-dev`.

Releases are published by running the **Release** workflow by hand (Actions → Release → Run workflow); it builds every platform, tags the next `v1.<number>` and updates the web app ([`release.yml`](.github/workflows/release.yml)). Every push to `flutter-rewrite` builds all platforms and publishes a `dev-<commit number>` pre-release ([`dev-release.yml`](.github/workflows/dev-release.yml)), and the web app to the [dev preview](https://devilapi.github.io/walkplay-eqloader/preview/) ([`preview.yml`](.github/workflows/preview.yml)). Both sites are served by GitHub Pages from the `gh-pages` branch.
