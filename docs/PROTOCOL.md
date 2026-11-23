# Anne Pro (original) Bluetooth LE protocol

This describes how the original Anne Pro (2016–2018, micro-USB) is configured over Bluetooth LE, as implemented in `AnneProKit` and `AnneProBluetooth`. Facts are marked with where they come from:

- **[msv]**: [msvisser/AnnePro-mac](https://github.com/msvisser/AnnePro-mac)
- **[kp]**: [kprinssu/anne-keyboard-windows](https://github.com/kprinssu/anne-keyboard-windows), a port of the official Android app
- **[ak]**: [ah-/anne-key](https://github.com/ah-/anne-key) firmware source
- **[hw]**: observed on a real keyboard (firmware as shipped, macOS 27, Apple Silicon) while building this project

## Hardware

The keyboard has three chips: a TI CC2541 Bluetooth chip, an STM32 key controller, and an STM32 LED controller **[ak]**. The Bluetooth chip relays app messages to the key controller over a serial link, and the key controller forwards lighting messages to the LED controller. Most of the quirks below come from this relay.

## GATT

| | UUID | Use |
|---|---|---|
| Service | `F000FFC0-0451-4000-B000-000000000000` | Settings channel (TI's OAD service, repurposed) **[msv][kp]** |
| Characteristic | `F000FFC1-…` | Keyboard → host, notify **[msv][kp]** |
| Characteristic | `F000FFC2-…` | Host → keyboard, write with and without response **[hw]** |
| Battery service | `180F` / `2A19` | Standard battery level, readable **[hw]** |

The keyboard advertises as `ANNE_KB_L0_xxxx` in BLE mode (`L0`) **[hw][kp]**. It's normally already connected to macOS as a HID keyboard. `retrieveConnectedPeripherals(withServices:)` finds it, and apps share that link.

## Framing

Every message is `[type, length, operation, data…]`, where `length = data.count + 1` **[ak]**. A reply uses the same type and sets the high bit on the operation (`op | 0x80`) **[msv][ak]**.

Payloads too big for one 20-byte packet are split into chunks **[msv][kp]**:

```
[type, totalLength + 1, op, chunkLength + 2, chunkCount, chunkIndex, chunk…]
```

- **Host → keyboard:** 14-byte chunks, each packet zero-padded to 20 bytes **[kp]**.
- **Keyboard → host:** 8-byte chunks in 14-byte notifications. Packets are reused buffers, so bytes past `chunkLength` are stale and must be ignored **[hw][msv]**.

## Message types

| Type | Value | **[ak]** |
|---|---|---|
| System | 2 | |
| BLE | 6 | Bluetooth chip control (host slots, legacy mode). Not used here. |
| Keyboard | 7 | Layouts |
| LED | 9 | Lighting |

## Commands

| What | Send | Reply | Notes |
|---|---|---|---|
| Device info | `02 01 01` | `02 … 81`, chunked, 14 bytes | `[deviceType=1, model=2, 12-byte id]` **[msv][ak][hw]** |
| Set lighting mode | `09 02 01 <mode>` | `09 02 81 <mode>` | See modes below **[msv][hw]** |
| Get lighting mode | `09 01 08` | `09 02 88 <mode>` | **[msv][hw]** |
| Set brightness | `09 04 02 01 <1–10> 00` | `09 02 82 <mode>` | **[msv][hw]**. There's no way to read brightness back: `09 04 05 00 00 00` gets no answer **[hw]**. |
| Upload custom lighting | `09 D7 03 …` chunked, 214 bytes | `09 02 83 80` | `80` = accepted **[msv][kp][hw]** |
| Download custom lighting | `09 01 09` | `09 D7 89 …` chunked, 214 bytes | **[msv][hw]** |
| Custom lighting id | `09 01 0A` | `09 … 8A` | Not used **[msv]** |
| Set layout | `07 02 03 <layout>` | none seen | 1 Windows, 2 Windows + arrows, 3 Mac, 128 Custom **[msv][hw]** |
| Get layout | `07 01 04` | `07 02 84 <layout>` | **[msv][hw]** |
| Upload custom layout | `07 91 02 …` chunked, 144 bytes | `07 02 82 80` | **[msv][hw]** |
| Download custom layout | `07 01 05` | `07 91 85 …` chunked, 144 bytes | **[msv][hw]** |

### Lighting modes

| Value | Mode **[ak][msv]** |
|---|---|
| 0 | Off |
| 1–9 | Red, yellow, green, cyan, blue, purple, pink, orange, white |
| 10–12 | France, Italy, Argentina flags |
| 13 | Breathing through the rainbow |
| 14 | Rainbow rolling across the board |
| 15 | Reactive: pressed keys light up and fade |
| 16 | Reactive: a new colour each press |
| 17 | Ripple: a pressed key's row and column light up |
| 18 | All keys cycle colours |
| 128 | Custom (per-key colours) |

## Payloads

The firmware addresses keys through a **70-slot matrix**. The ANSI board has 61 keys; slots `40, 53, 54, 59, 60, 62, 63, 64, 65` have no key and are sent as zeros **[msv][kp]**. Slots run left to right, top to bottom, so Esc is 0, Enter is 41, right Shift 55, Space 61, Fn 67, Anne 68 and right Ctrl 69.

Both payloads start with a 4-byte header `[0, 0, crcHigh, crcLow]`. The CRC is **CRC-16/MODBUS** (reflected poly `0xA001`, init `0xFFFF`) over everything after the header **[msv][kp]**. The official app ships it as two lookup tables; it's the same algorithm.

- **Lighting (214 bytes):** header + 70 × `[R, G, B]`.
- **Layout (144 bytes):** header + 70 base-layer key codes + 70 Fn-layer key codes. Codes are USB HID usage IDs, plus `254` = Fn and `250` = Anne. The layout must contain exactly one Fn and one Anne key, at the same position in both layers **[msv][kp]**. Fn + R/T/Y/U/B are reserved by the firmware **[msv]**.

A keyboard that has never had a custom layout returns all zeros for it **[hw]**. Switching to the Custom layout then would disable every key, so the app checks the stored layout before switching.

## Not reachable over Bluetooth

The anne-key firmware source documents two more LED controller commands. On stock firmware the key controller doesn't pass them through from Bluetooth: no acknowledgement ever comes back, while regular mode changes on the same path are acknowledged **[hw]**.

- **SetIndividualKeys** (`09 … 0B CA <count> [<slot> <R> <G> <B> <mode>]…`): lights individual keys without saving them. It would allow a live preview while editing. Tested as a single packet, in chunked form, and with mode 1 (on) and 2 (flash).
- **ConfigCmd** (`09 04 05 <theme> <speed> <brightness>`): "next theme/speed/brightness". Its reply would carry the current brightness and animation speed. Tested with `00 00 00` and `00 01 00`.

So there's no way to read brightness or set animation speed from an app.

## Quirks found on hardware

These explain the "uploads sometimes stop halfway" problem in earlier apps.

1. **LED power budget.** A key whose `R + G + B > 450` is stored and shown at 60%, rounded down per channel. For example, `FF D9 00` becomes `99 82 00`, and white becomes `99 99 99`. The threshold was measured exactly: 450 is kept, 451 is dimmed. Read-backs must be compared against the dimmed values.
2. **Slow uploads get truncated.** A few seconds after connecting, the keyboard moves to a slow, power-saving connection interval (about 350 ms per confirmed write). An upload sent as confirmed writes then takes about 6 s, and the keyboard often keeps only the first ~34 bytes while still acknowledging with `80`. Unconfirmed writes with a ~20 ms gap finish in about 0.4 s and were stored correctly every time in testing. That's also what the official app did **[kp]**.
3. **Back-to-back uploads get truncated.** An upload sent less than about a second after the previous one is mostly dropped while the keyboard is still storing the first. Uploads are spaced 2.5 s apart.
4. **First message after idle can be lost.** When nobody has typed for a while, the first message (or its reply) may be dropped or garbled while the key controller wakes up. A device-info round trip before an upload wakes it; setters without a confirmation are re-sent.
5. **The acknowledgement isn't proof.** `80` means the Bluetooth chip and key controller accepted the transfer, not that it was stored intact. Always read back and compare.
6. **The keyboard sleeps and drops the link.** Expect disconnects ("connection timed out") and reconnect when it reappears as connected to macOS.
