# Changelog

## 1.2.0

- Colour the keys from any image: drop it on the keyboard in the lighting editor, or use Presets → From an Image.
- Quick layout changes: Caps Lock → Escape, Caps Lock → Control, swap left Alt and Win, swap right Alt and Ctrl.
- Redo (⇧⌘Z) in both editors.
- Install with Homebrew: `brew tap thtjst/annepro-macos https://github.com/thtjst/annepro-macos && brew install --cask annepro`. The `anne` tool now ships inside the app.
- The update check now really runs at most once a day and remembers what it found, and only ever opens github.com pages.

## 1.1.0

- Saved lighting designs: save designs in the lighting editor and apply them from the menu bar.
- Low battery notification at 15% and 5%.
- Update check: the menu shows when a new version is available. Once a day, can be turned off.
- VoiceOver support in the lighting and layout editors.

## 1.0.1

- Rainbow and gradient presets now stay within the keyboard's LED power budget, so they look even on the keyboard instead of having some keys cut to 60%.
- Fixed reconnecting after Bluetooth is turned off and on, or the Mac wakes from sleep.

## 1.0.0

First release.

- Menu bar app: lighting modes, brightness, layout switching, battery level, Open at Login.
- Per-key lighting editor with painting, fills, presets and import/export.
- Custom layout editor for the base and Fn layers, with safeguards against locking yourself out.
- Verified uploads: read back from the keyboard and retried, fixing the truncated uploads of earlier apps.
- Option to hide the menu bar icon and use it as a regular app.
- `anne` command-line tool.
- Universal binary for Apple Silicon and Intel, macOS 13 or later.
