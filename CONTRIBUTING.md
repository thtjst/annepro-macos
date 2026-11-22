# Contributing

Bug reports, fixes and ideas are welcome. Open an issue first for bigger changes, so we can agree on the approach.

## Building

You need macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode works too.

```sh
swift build              # build everything
scripts/test.sh          # unit tests
scripts/build-app.sh     # dist/AnnePro.app
scripts/screenshots.sh   # regenerate README screenshots
```

To try changes against a keyboard, the `anne` tool is the quickest loop: `swift run anne status -v` prints every packet. The first run asks to give your terminal Bluetooth access.

## Where things live

- `Sources/AnneProKit`: the protocol, with no I/O. New protocol knowledge goes here, with a test.
- `Sources/AnneProBluetooth`: the CoreBluetooth connection, pacing and verified uploads.
- `Sources/AnneProApp`: the SwiftUI app.
- `docs/PROTOCOL.md`: what we know about the keyboard. If you discover something on real hardware, please add it there and say how you found it.

## Notes

- Keep the app buildable with only the Command Line Tools. That's why it uses `LocalState` instead of `@State` (see `KeyboardView.swift`).
- Be careful with anything that writes a layout. A layout without Fn and Anne keys locks the user out of the keyboard's own settings.
