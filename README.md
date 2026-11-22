<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="">
</p>

<h1 align="center">Anne Pro for Mac</h1>

<p align="center">
  Change the lighting and layout of the <b>original Anne Pro</b> keyboard over Bluetooth,<br>
  from a modern, native macOS menu bar app.
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/thtjst/annepro-macos?label=download" alt="Latest release"></a>
  <a href="../../actions/workflows/ci.yml"><img src="https://github.com/thtjst/annepro-macos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-blue" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/thtjst/annepro-macos" alt="MIT License"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/lighting-dark.png">
    <img src="docs/screenshots/lighting-light.png" alt="Per-key lighting editor" width="780">
  </picture>
</p>

---

The official Obins Anne Pro app is long gone, and the old community Mac app ([AnnePro-mac](https://github.com/msvisser/AnnePro-mac)) no longer runs on current macOS. This is a from-scratch rewrite: **Anne Pro software for macOS** that changes the RGB backlight and key layout of the original Anne Pro over Bluetooth, on Apple Silicon (M1, M2, M3, M4…) and Intel Macs. It's built on the protocol work of earlier community projects and tested against a real keyboard.

## Features

- **Menu bar controls**: switch lighting modes (solid colours, breathing, rainbow, reactive, ripple…), brightness, and layout (Windows, Windows + arrows, Mac, Custom) in one click.
- **Per-key lighting editor**: paint keys by clicking or dragging, fill groups, use presets, ⌥-click to pick up a colour. The preview shows what the keyboard will really display.
- **Custom layout editor**: remap any key on the base and Fn layers. It won't let you upload a layout that would lock you out (no Fn or Anne key).
- **Reliable uploads**: every upload is read back from the keyboard and retried until it sticks.
- **Saved designs**: keep several lighting designs and switch between them from the menu bar.
- **Battery level** and a notification when it runs low, automatic reconnect when the keyboard wakes, Open at Login, and an option to hide the menu bar icon.
- **Update check**: shows when a new version is out (can be turned off).
- **Import / export** profiles as JSON. It also reads files exported by the old AnnePro-mac app.
- **`anne` command-line tool** for scripting and debugging.

## Screenshots

<table>
  <tr>
    <td valign="top" width="300">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-dark.png">
        <img src="docs/screenshots/menu-light.png" alt="Menu bar panel" width="300">
      </picture>
      <br><sub>Everything one click away in the menu bar</sub>
    </td>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/layout-dark.png">
        <img src="docs/screenshots/layout-light.png" alt="Custom layout editor">
      </picture>
      <br><sub>Remap keys on the base and Fn layers</sub>
    </td>
  </tr>
</table>

## Requirements

- An **original Anne Pro** (2016–2018, micro-USB). The Anne Pro 2 uses a different protocol and is not supported.
- macOS 13 Ventura or later, on Apple Silicon or Intel.
- The keyboard paired with your Mac over Bluetooth in **BLE mode**. It shows up as `ANNE_KB_L0_…` in Bluetooth settings (`L0` means BLE).

## Install

1. Download `AnnePro-x.y.z.zip` from [Releases](../../releases/latest), unzip it, and move **AnnePro.app** to Applications.
2. Open it. The app isn't notarized by Apple (it's a free hobby project), so macOS blocks it the first time:
   - **macOS 15 and later:** click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - **macOS 13–14:** right-click the app, choose **Open**, then **Open** again.
   - **Or, in Terminal:** `xattr -dr com.apple.quarantine /Applications/AnnePro.app`
3. Allow Bluetooth access when macOS asks.

Anne Pro lives in the menu bar: click the keyboard icon at the top of the screen. Opening the app again shows the same controls in a window.

Don't need it all the time? Uncheck **Show in Menu Bar**. Anne Pro then works like a normal app: open it when you want to change something, and quit it when you're done. The keyboard keeps its settings either way.

## Command-line tool

```console
$ anne status
Connected to ANNE_KB_L0_XXXX
Model:    Anne Pro
Battery:  100%
Layout:   Windows
Lighting: Cyan

$ anne mode rainbow
$ anne brightness 6
$ anne fill "#00A0FF"            # every key one colour (switches to Custom)
$ anne read-lighting mine.json   # back up your custom lighting
$ anne write-layout mac          # put the Mac layout in the Custom slot and use it
$ anne raw 09 01 08 -v           # send raw bytes, print every packet
```

Run `anne help` for everything. The first time you use it, macOS asks to give your terminal app Bluetooth access.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Looking for your Anne Pro…" forever | Make sure the keyboard is paired and connected in System Settings → Bluetooth, then press a key to wake it. |
| Keyboard not listed as `ANNE_KB_L0_…` | It's in legacy Bluetooth mode. Switch it to BLE (see the Anne Pro manual), then re-pair. |
| "Bluetooth access not allowed" | System Settings → Privacy & Security → Bluetooth → enable Anne Pro (or your terminal for `anne`). |
| Colours look dimmer than picked | The keyboard dims any key whose R+G+B exceeds 450 to 60% to protect its LEDs. The editor preview shows this. |
| Switching to Custom layout is refused | The keyboard's custom slot is empty or broken. Open the layout editor, start from a preset and send it first. |

## FAQ

**Is there still an app for the Anne Pro?**
The official Obins app for the original Anne Pro was discontinued. This app replaces it on the Mac and covers what it did: lighting modes, brightness, per-key colours and custom layouts.

**Does it work with the Anne Pro 2?**
No. The Anne Pro 2 (USB-C, 2018 and later) uses a different protocol and is configured with Obinskit or QMK. This app is for the original Anne Pro with micro-USB.

**Does it need a USB cable?**
No, everything happens over Bluetooth. The original Anne Pro can't be configured over USB.

**How do I tell which Anne Pro I have?**
The original has a micro-USB port and shows up in Bluetooth settings as `ANNE_KB_…`. The Anne Pro 2 has USB-C.

**Do my settings stay on the keyboard?**
Yes. Lighting and layouts are saved on the keyboard itself, so they keep working on other computers and when the app isn't running.

**Is there a Windows or Linux version?**
Not from this project. [anne-keyboard-windows](https://github.com/kprinssu/anne-keyboard-windows) exists for Windows, and [docs/PROTOCOL.md](docs/PROTOCOL.md) documents everything needed to build one.

**Does the app phone home?**
Only to check GitHub for a newer version once a day, which you can turn off in the menu (uncheck *Check for Updates*). Nothing about you or your keyboard is sent.

## Building from source

Only the Xcode Command Line Tools are needed (`xcode-select --install`); full Xcode works too.

```sh
swift build                  # everything
scripts/test.sh              # unit tests
scripts/build-app.sh         # universal, signed dist/AnnePro.app + zips
scripts/screenshots.sh       # regenerate the README screenshots
```

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

The project is a Swift package:

| Module | What it is |
|---|---|
| `AnneProKit` | The protocol: packets, checksum, key map, lighting and layout data. Pure Swift, fully unit tested. |
| `AnneProBluetooth` | CoreBluetooth connection: discovery, reconnects, write pacing, verified uploads. |
| `AnneProApp` | The SwiftUI menu bar app. |
| `anne` | The command-line tool. |

The wire protocol, including quirks found while testing on hardware, is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md). Release steps are in [docs/RELEASING.md](docs/RELEASING.md).

## Credits

This project would not exist without the people who reverse-engineered the keyboard:

- [msvisser/AnnePro-mac](https://github.com/msvisser/AnnePro-mac): the original macOS app (2017). The factory layouts and protocol constants come from there.
- [kprinssu/anne-keyboard-windows](https://github.com/kprinssu/anne-keyboard-windows): the Windows app, ported from the official Android app.
- [ah-/anne-key](https://github.com/ah-/anne-key): open-source firmware whose source documents the message types.

Anne Pro is a trademark of Obins. This project is not affiliated with or endorsed by Obins.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
