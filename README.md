# AppMixer

A menu bar mixer for macOS, in Liquid Glass. Click the knob in the menu bar:

- **Quiet:** just your output device and volume, like the system volume HUD.
- **Something playing:** every app making sound appears under the speaker with its own volume and mute.
  Right-click an app to send it to a different output (e.g. music on AirPods, a call on speakers).
- **Mic in use:** the input device and level appear too.
- **Multi-output:** when two or more outputs are connected (e.g. MacBook speakers + AirPods), a switch
  plays apps on all of them at once. Each device gets its own section and volume, and each app can be turned
  off per device, e.g. music on both, a call only on the AirPods.
- **Bluetooth batteries:** AirPods left / right / case (and other headsets), with a green ⚡ while charging.

Click a device name to switch speakers or microphones, and either speaker icon to mute.
System sounds (charging chime, screenshot shutter, alerts, Siri) are never listed.
Right-click the panel for "Show battery levels", "Reset all apps" and "Quit".

Requires **macOS 14.2+** (uses Core Audio process taps, no audio driver to install).
Runs on Apple silicon and Intel Macs.

## Download

Get the latest `AppMixer-<version>.dmg` from [Releases](../../releases), open it and drag AppMixer to Applications.

The app isn't signed with an Apple Developer ID, so the first launch is blocked: open
**System Settings › Privacy & Security** and click **Open Anyway** next to AppMixer (once).
The first time you change an app's volume, allow audio capture when macOS asks.

## Build from source

```bash
./build.sh          # universal app in build/AppMixer.app
./build.sh --dmg    # plus dist/AppMixer-<version>.dmg
open build/AppMixer.app
```

## How it works

- Apps at 100% on the system output are left alone.
- Change an app's volume, mute it, or pick another output and AppMixer creates a **process tap** for that app
  (which silences its normal output), plus a private aggregate device that plays the tapped audio
  on the chosen output at the chosen gain.
- Helper processes (Chrome Helper, Safari's WebKit GPU process) are grouped under their app.
- Settings are remembered per app (by bundle ID) and re-applied when the app plays again.
- Battery levels come from the accessory power sources macOS publishes (the same data as the Bluetooth menu),
  with `system_profiler` as a backup. The AirPods case only reports while its lid is open.

## Multi-output

With the switch on, every app that's playing is tapped and sent to all connected outputs through one private
aggregate device (first device is the clock master, the others use drift compensation), minus the devices you
turned it off on. Each device gets its own left/right channels. Virtual devices (e.g. loopback drivers) aren't
offered. Alerts and apps that aren't playing stay on the system output. Bluetooth headphones play roughly
0.15–0.25 s behind wired or built-in speakers, so in the same room you'll hear an echo; devices should share a
sample rate.

## Debug flags

- `--preview` opens the panel in the middle of the screen and keeps it open
  (`--preview-quiet` and `--preview-mic` force those states, `-previewBackdrop white|black` adds a backdrop,
  `-previewCharging YES` fakes charging AirPods, `-previewKnob YES` shows the slider knob).
- `--devicetest <logfile>` nudges the output and input volume by 10%, reads it back, and restores it.
- `--selftest <bundleID|pid> <volume> <seconds> <logfile>` taps one app and logs in/out peak levels
  (add `-selftestOutputs "Device A,Device B"` to play it on several devices at once).

## Known limits

- If audio capture permission is denied, tapped apps go silent; reset them with "Reset all apps".
- Tapped audio adds a few milliseconds of latency.
- Not yet tested with output devices running at a different sample rate from the tapped app.

## Per-tab volume (browsers)

macOS hands each browser's audio to AppMixer as one stream, so tabs can't be separated at the system level.
The **AppMixer Tabs** extension (in `Extension/`) scales each tab's audio inside the page instead
(`<audio>`, `<video>` and Web Audio), and reports tabs to AppMixer over `127.0.0.1:47300`.
Tabs then appear indented under their browser in the menu bar panel. The extension's toolbar
popup gives the same sliders without AppMixer.

**Chrome / Brave / Edge:** open `chrome://extensions` (or `brave://extensions`), turn on Developer mode,
click "Load unpacked" and choose the `Extension` folder.

**Safari:** the extension is unsigned (no Apple Developer team set up), so:
1. Safari › Settings › Advanced › turn on "Show features for web developers".
2. Safari › Settings › Developer › turn on "Allow unsigned extensions" (resets each time Safari quits).
3. Open `build/AppMixer Tabs.app` once, then enable AppMixer Tabs in Safari › Settings › Extensions
   and allow it on all websites.

To rebuild the Safari app after changing `Extension/`, regenerate it with
`xcrun safari-web-extension-converter` (see `SafariExtension/`) and build in Xcode with "Sign to Run Locally".

Tests: open `tests/page-volume.html` in a browser (or headless Chrome) — it should list 15 PASS lines.
