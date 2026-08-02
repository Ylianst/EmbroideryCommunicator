# Embroidery Communicator — Flutter Porting Plan

This document describes how to port the existing **Embroidery Communicator** (a Windows-only
C# / WinForms application located in `../EmbroideryCommunicatorLegacy`) to a cross-platform
**Flutter** application targeting **Windows, macOS, Linux, and Web** (no mobile).

The application talks to a **Bernina Artista 180** embroidery machine over an **RS-232 serial
port** (typically via a USB-to-serial adapter), and can optionally talk to the machine over the
network through a Node.js **relay** running on a Raspberry Pi.

---

## 1. What the Legacy Application Does

### 1.1 Feature inventory

| Feature | Legacy source | Notes |
|---|---|---|
| Auto-detect serial ports (hot-plug) | `ComPortMonitor.cs` | Uses Windows WMI (`Win32_DeviceChangeEvent`) — Windows-only |
| Connect to machine over serial | `SerialStack.cs` | 19200 baud default, can switch to 57600 baud |
| Connect to machine over network | `NetworkStack.cs`, `TcpStack.cs` | Talks to a TCP relay (`relay/Relay.js`) |
| Read machine / firmware info | `SerialStack.ReadAllFirmwareInfoAsync` | Version, language, manufacturer, date, PC-card presence |
| List embroidery files (module + PC card) | `SerialStack.ReadEmbroideryFilesAsync` | Names, attributes, storage location |
| Preview pattern thumbnail | `ReadEmbroideryFilePreviewAsync` | 72×62 monochrome bitmap |
| Upload `.EXP` file to machine | `WriteEmbroideryFileAsync` | Adds trailing `0x8081` "Stop" if missing |
| Download `.EXP` file from machine | `ReadEmbroideryFileAsync` | Strips trailing `0x8081` on save |
| Delete file from machine / PC card | `DeleteEmbroideryFileAsync` | |
| Render full stitch pattern | `ExpFileParser.cs`, `EmbroideryViewerForm.cs`, `StitchData.cs` | GDI+ drawing of stitches |
| Memory dump (whole machine memory → file) | `MemoryDumpForm.cs`, `DownloadMemoryAsync` | Advanced feature |
| Live debug (serial traffic view) | `DebugForm.cs` | Advanced feature |
| Serial capture / analysis | `SerialCaptureForm.cs` | Advanced feature |
| Raw memory viewer | `MemoryWindow.cs` | Advanced feature |
| Persist last COM port / settings | `RegistryHelper.cs` | Windows Registry — Windows-only |
| Preview thumbnail cache | `SerializeCacheAsync` / gzip | Registry-stored gzip blob |

### 1.2 Core protocol (must be preserved exactly)

The value of this project is the reverse-engineered serial protocol, documented in
`../EmbroideryCommunicatorLegacy/docs/`:

- `SerialProtocol.md` — low-level byte protocol (echo-per-character, `R`/`N`/`W`/`PS`/`L`
  commands, `RF?` reset, baud-rate detection & switching, embroidery-session start/stop).
- `HighLevel.md` — high-level flows (list files, preview, download, upload, delete).
- `ExpFormat.md` — `.EXP` stitch file format.
- `TcpProtocol.md` — relay framing (`[MessageType:4][RequestID:8][PayloadLength:8][Payload:N]`).

**These documents are the specification for the Dart port.** The protocol logic must be
translated faithfully; timing details (echo waiting, baud-switch confirmation windows) matter
because the machine can enter an unrecoverable state if the handshake is mishandled.

### 1.3 Code size (translation effort indicator)

| File | Lines | Role |
|---|---|---|
| `SerialStack.cs` | ~4400 | Low-level protocol + high-level machine operations (the heart) |
| `NetworkStack.cs` | ~2800 | Same high-level ops over the TCP relay |
| `MainForm.cs` | ~2200 | Main UI |
| `EmbroideryViewerForm.cs` | ~1200 | Stitch pattern viewer |
| `SerialCaptureForm.cs` | ~1070 | Capture tooling |
| `TcpStack.cs` | ~800 | TCP relay framing |
| `DebugForm.cs` | ~640 | Traffic debug view |
| `ExpFileParser.cs` / `StitchData.cs` | ~450 | `.EXP` parsing + model |
| Dialogs / helpers | ~1500 | About, details, sum, memory, registry, port monitor |

Note: `SerialStack` and `NetworkStack` **duplicate** the high-level operations. The port should
refactor this into a single high-level layer over a pluggable transport (see §3.2).

---

## 2. Platform Capability Matrix

The single biggest architectural driver is **how each platform accesses a serial port**.

| Capability | Windows | macOS | Linux | Web |
|---|---|---|---|---|
| Direct serial via `flutter_libserialport` | ✅ | ✅ | ✅ | ❌ (no dart:ffi) |
| Serial via **Web Serial API** | — | — | — | ✅ (Chromium browsers only) |
| **Change baud rate on open port** | ✅ | ✅ | ✅ | ❌ (must close & reopen) |
| Port enumeration | ✅ | ✅ | ✅ | ✅ (user-granted ports only) |
| Hot-plug events | polling / native | polling / native | polling / native | `connect`/`disconnect` events |
| Raw TCP to relay (`dart:io` Socket) | ✅ | ✅ | ✅ | ❌ (browsers can't do raw TCP) |
| Network to relay via **WebSocket** | ✅ | ✅ | ✅ | ✅ (requires relay to expose WS) |

### 2.1 Consequences of the matrix

1. **Baud switching is desktop-only.** The user explicitly does not want baud switching on Web.
   The Web Serial API cannot change baud on an open port anyway. On Web we therefore either:
   - open the port at a **fixed 19200 baud** and never switch (slower but safe), **or**
   - require the user to use the network/relay path.
   The transport abstraction (§3.2) exposes a `canChangeBaud` capability flag so the high-level
   layer skips the `TrMEJ05` fast-baud upgrade on Web.

2. **Raw TCP relay works only on desktop.** For Web relay access, the relay must expose a
   **WebSocket** endpoint. This is a relay-side addition (small change to `relay/Relay.js`) and
   is called out as optional in the phased plan.

3. **Web serial is Chromium-only** (Chrome/Edge/Opera). Firefox/Safari do not implement Web
   Serial. This is a browser limitation to document in the UI, not something Flutter can fix.

---

## 3. Target Architecture (Flutter / Dart)

### 3.1 High-level layering

```
┌───────────────────────────────────────────────────────────┐
│  UI layer (Flutter widgets)                                │
│  screens/  +  widgets/  +  state (Riverpod/Provider)       │
└───────────────────────────────────────────────────────────┘
                 │ calls (async) / listens (streams)
┌───────────────────────────────────────────────────────────┐
│  MachineController  (high-level machine operations)        │
│  connect, listFiles, readPreview, download, upload, delete │
│  — port of the shared logic in SerialStack/NetworkStack    │
└───────────────────────────────────────────────────────────┘
                 │ uses
┌───────────────────────────────────────────────────────────┐
│  Transport abstraction  (interface)                        │
│  send(bytes) / stream<bytes> in / capabilities             │
├──────────────┬───────────────┬────────────────────────────┤
│ DesktopSerial│  WebSerial     │  RelayTransport            │
│ (libserial-  │  (Web Serial   │  (TCP on desktop /         │
│  port + FFI) │   JS interop)  │   WebSocket on web)        │
└──────────────┴───────────────┴────────────────────────────┘
                 │ operates on
┌───────────────────────────────────────────────────────────┐
│  Domain / model + codec                                    │
│  ExpFile, EmbroideryPattern, StitchPoint, FirmwareInfo,    │
│  EmbroideryFile, protocol command encoders/decoders        │
└───────────────────────────────────────────────────────────┘
```

### 3.2 The `Transport` abstraction (key refactor)

Legacy `SerialStack` and `NetworkStack` re-implement every high-level operation. We collapse
this into **one** `MachineController` that talks to a `Transport` interface:

```dart
abstract class Transport {
  Future<void> open();
  Future<void> close();
  Stream<Uint8List> get incoming;   // bytes from machine/relay
  Future<void> send(Uint8List data);

  // Capability flags used by MachineController to adapt behavior
  bool get supportsBaudChange;      // false on Web Serial
  bool get isRelay;                 // relay speaks the high-level TCP framing
  Future<void> setBaudRate(int baud); // no-op / throws when unsupported
}
```

Implementations:

- **`DesktopSerialTransport`** — wraps `flutter_libserialport`. Supports baud change and port
  enumeration on Windows/macOS/Linux.
- **`WebSerialTransport`** — JS interop over the Web Serial API (`package:web` + `dart:js_interop`).
  `supportsBaudChange == false`; opens at a fixed baud.
- **`RelayTransport`** — implements the relay's TCP message framing (`TcpProtocol.md`).
  Uses `dart:io` `Socket` on desktop and a `WebSocket` on Web. `isRelay == true`, so the
  high-level layer skips per-character echo handling (the relay does that itself).

> Because the relay exposes a *different, higher-level* protocol than the raw serial link, the
> `MachineController` needs two internal command paths: **raw serial** (byte-level echo protocol)
> and **relay** (request/response framing). Keep the *public* operation API identical so the UI
> does not care which transport is active — mirroring how the legacy UI switched between
> `SerialStack` and `NetworkStack`.

### 3.3 Concurrency model

The legacy code uses `async`/`await` plus a background command queue (`ProcessCommandQueueAsync`)
and a blocking read loop (`BlockingReadLoopAsync`). This maps cleanly onto Dart:

- Incoming bytes → a broadcast `Stream<Uint8List>`.
- A `StreamController`-backed **command queue** processes one command at a time (the protocol is
  strictly request/response with per-character echo).
- Use `Completer<CommandResult>` in place of C#'s `TaskCompletionSource`.
- The protocol is **I/O-bound**, not CPU-bound, so it can run on the main isolate. If large
  memory dumps or `.EXP` parsing cause jank, offload those to an isolate via `compute()`.

### 3.4 Replacing platform-specific pieces

| Legacy (Windows-only) | Flutter replacement |
|---|---|
| `RegistryHelper.cs` (Registry) | `shared_preferences` (works on all four targets incl. Web) |
| `ComPortMonitor.cs` (WMI events) | Desktop: periodic `SerialPort.availablePorts` diff + optional native watcher. Web: `navigator.serial` `connect`/`disconnect` events |
| `System.Drawing` / GDI+ rendering | `CustomPainter` + `dart:ui` (`Canvas`, `Path`) for stitch rendering; `dart:ui` `decodeImageFromPixels` for the 72×62 preview bitmap |
| `System.IO.Ports.SerialPort` | `flutter_libserialport` (desktop) / Web Serial (web) |
| WinForms dialogs & controls | Flutter widgets (Material 3, or `fluent_ui` for a Windows-native look) |
| File open/save dialogs | `file_picker` / `file_selector` (native on desktop, download/upload on Web) |
| `System.IO.Compression` (gzip cache) | `dart:io`/`archive` package `GZipCodec` |

---

## 4. Recommended Packages

| Concern | Package | Platforms |
|---|---|---|
| Desktop serial | `flutter_libserialport` | Win/macOS/Linux |
| Web serial | `dart:js_interop` + `package:web` (thin custom wrapper) | Web |
| Relay TCP | `dart:io` `Socket` | Win/macOS/Linux |
| Relay WebSocket | `web_socket_channel` | all |
| State management | `flutter_riverpod` (or `provider`) | all |
| Settings persistence | `shared_preferences` | all |
| File picking / saving | `file_selector` (+ `file_picker` fallback) | all |
| Compression (cache) | `archive` | all |
| Logging | `logging` | all |
| Windows-native styling (optional) | `fluent_ui` | Win (falls back to Material elsewhere) |

Avoid packages that pull in mobile-only or platform-locked plugins.

---

## 5. Proposed Project Structure

```
EmbroideryCommunicator/                (Flutter app root — this folder)
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── app.dart                        # MaterialApp, routing, theme
│   ├── domain/
│   │   ├── models/
│   │   │   ├── embroidery_file.dart
│   │   │   ├── firmware_info.dart
│   │   │   ├── stitch.dart             # StitchPoint / StitchType / EmbroideryPattern
│   │   │   └── enums.dart              # SessionMode, StorageLocation, ConnectionState
│   │   └── exp/
│   │       ├── exp_parser.dart         # port of ExpFileParser.cs
│   │       └── exp_writer.dart         # trailing 0x8081 handling
│   ├── transport/
│   │   ├── transport.dart              # abstract Transport
│   │   ├── desktop_serial_transport.dart
│   │   ├── web_serial_transport.dart
│   │   ├── relay_transport.dart
│   │   └── port_discovery.dart         # enumeration + hot-plug
│   ├── protocol/
│   │   ├── machine_controller.dart     # high-level operations (shared)
│   │   ├── serial_commands.dart        # R/N/W/PS/L encoders + parsers
│   │   ├── command_queue.dart          # sequential request/response engine
│   │   └── relay_protocol.dart         # TcpProtocol.md framing
│   ├── state/
│   │   └── ... (Riverpod providers)
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── main_screen.dart        # port of MainForm
│   │   │   ├── viewer_screen.dart      # port of EmbroideryViewerForm
│   │   │   ├── memory_dump_screen.dart
│   │   │   ├── debug_screen.dart
│   │   │   └── settings_screen.dart
│   │   └── widgets/
│   │       ├── embroidery_file_tile.dart
│   │       ├── stitch_painter.dart     # CustomPainter for patterns
│   │       └── preview_thumbnail.dart  # 72×62 bitmap rendering
│   └── services/
│       ├── settings_service.dart       # shared_preferences
│       └── preview_cache.dart          # gzip cache
├── test/
│   ├── exp_parser_test.dart
│   ├── serial_commands_test.dart
│   └── relay_protocol_test.dart
└── platform folders (windows/ macos/ linux/ web/)
```

---

## 6. Phased Implementation Plan

Each phase is independently demonstrable and testable. Protocol correctness is front-loaded
because it is the highest-risk area.

### Phase 0 — Project bootstrap
- `flutter create` with `--platforms=windows,macos,linux,web`.
- Add packages, set up theming, state management, and CI (build all four targets).
- Establish an app shell with a placeholder main screen.

### Phase 1 — Domain & `.EXP` codec (pure Dart, no I/O)
- Port `StitchData.cs` → models, `ExpFileParser.cs` → `exp_parser.dart`, and the trailing
  `0x8081` add/strip logic → `exp_writer.dart`.
- **Unit test against real `.EXP` files** from the legacy `releases/` samples; assert stitch
  counts and bounding boxes match the C# parser.
- Deliverable: load a local `.EXP` and render it with `StitchPainter` — no machine needed.

### Phase 2 — Transport abstraction + desktop serial
- Define `Transport`, implement `DesktopSerialTransport` on `flutter_libserialport`.
- Port `port_discovery.dart` (enumeration + polling-based hot-plug).
- Deliverable: enumerate ports, open/close, echo raw bytes; verified on Win/macOS/Linux.

### Phase 3 — Low-level serial protocol engine
- Port the byte-level protocol from `SerialProtocol.md` / `SerialStack.cs`:
  echo-per-character send, `RF?` reset/recovery, `R`/`N`/`W`/`PS`/`L` commands, checksummed
  block reads/writes, baud-rate detection, and the `TrMEJ05`/`EBYQ` fast-baud upgrade
  (**desktop only**, gated by `supportsBaudChange`).
- Port embroidery-session start/stop (`TrMEYQ` / `TrME`) with the safety guards documented in
  `SerialProtocol.md` (never double-open a session, honor the confirmation windows).
- Extensive unit tests using a **mock transport** that replays captured traffic from
  `SerialCapture.md` / `docs`.

### Phase 4 — High-level machine operations
- Port to `MachineController`: firmware/PC-card read, list files (module + PC card),
  read preview, download file, upload file (with trailing-stop insertion), delete file.
- Port the preview thumbnail decode (72×62 monochrome) and stitch rendering.
- Deliverable: full end-to-end connect → list → preview → download/upload → delete on desktop.

### Phase 5 — Main UI parity
- Port `MainForm` (connection bar, port menu, file lists for module + PC card, details pane)
  and `EmbroideryViewerForm` (pattern viewer with zoom/pan and color-change stepping).
- Settings via `shared_preferences`; preview cache via gzip service.

### Phase 6 — Web target
- Implement `WebSerialTransport` (Web Serial JS interop), fixed baud, `supportsBaudChange=false`.
- Handle browser permission model (user gesture to request a port) and `connect`/`disconnect`
  hot-plug events. Document Chromium-only support in the UI.
- Verify all Phase 4/5 operations work over Web Serial at the fixed baud.

### Phase 7 — Network relay (optional / advanced)
- Implement `RelayTransport` (TCP via `dart:io` on desktop).
- Port `NetworkConnectionDialog` and wire relay as an alternative transport.
- For Web relay support, add a **WebSocket** endpoint to `relay/Relay.js` and a
  `web_socket_channel`-based relay transport.

### Phase 8 — Advanced tooling (optional)
- Port Memory Dump, Live Debug traffic view, Serial Capture, and raw Memory Viewer.
- These are power-user features; schedule after core parity.

### Phase 9 — Polish & release
- Per-platform packaging: MSIX (Windows), DMG/notarization (macOS), AppImage/deb (Linux),
  static hosting (Web).
- App icons, about box, licenses, and user documentation update.

---

## 7. Key Porting Challenges & Mitigations

1. **Protocol timing safety.** The machine can become unrecoverable if the baud-switch
   confirmation (`EBYQ` after `BOS`) is late, or if an embroidery session is double-opened.
   *Mitigation:* translate the timing/guard logic literally; add integration tests with a mock
   machine; keep the recovery/`RF?` paths intact.

2. **Web Serial limitations.** No baud change on an open port, Chromium-only, permission-gated.
   *Mitigation:* capability flag on the transport; fixed baud on Web; clear UI messaging;
   relay/desktop as fallbacks.

3. **No raw TCP in browsers.** The existing relay uses raw TCP.
   *Mitigation:* keep raw TCP for desktop; add an optional WebSocket endpoint to the relay for
   Web.

4. **De-duplicating `SerialStack`/`NetworkStack`.** They duplicate high-level logic.
   *Mitigation:* single `MachineController` over the `Transport` abstraction (§3.2).

5. **Rendering without GDI+.** `System.Drawing` is unavailable.
   *Mitigation:* `CustomPainter`/`Canvas` for stitches; `decodeImageFromPixels` for previews.

6. **Hot-plug detection cross-platform.** WMI is Windows-only.
   *Mitigation:* poll `availablePorts` on desktop (cheap), use Web Serial events on Web,
   optionally add native watchers later.

7. **Endianness / binary handling.** Dart `Uint8List` + `ByteData` replace C# `byte[]`/`BitConverter`.
   Be explicit about big-endian fields (relay framing) and the HEX/binary command encodings.

---

## 8. Testing Strategy

- **Unit tests (pure Dart):** `.EXP` parse/write round-trips against real sample files; command
  encoders/decoders; relay framing.
- **Mock-transport integration tests:** replay captured serial traffic (from the `docs/` captures)
  to validate the protocol engine without hardware.
- **Manual hardware validation:** against a real Bernina Artista 180 for connect, list, preview,
  download, upload, delete, and baud switching (desktop).
- **Cross-platform smoke tests:** build & launch on Windows/macOS/Linux/Web in CI.

---

## 9. Out of Scope / Non-Goals

- Mobile (Android/iOS) targets.
- Baud-rate switching on Web (intentionally omitted).
- Changing the machine-side protocol or the `.EXP` format.
- Rewriting the relay in Dart (only an optional WebSocket endpoint is added for Web support).

---

## 10. Summary

The port is dominated by faithfully translating the reverse-engineered protocol in
`SerialStack.cs` (guided by the excellent `docs/` specifications) into a Dart
`MachineController` sitting on a pluggable `Transport`. A clean transport abstraction lets one
high-level implementation serve **desktop serial**, **Web Serial**, and the **network relay**,
while capability flags cleanly handle the platform differences — most importantly, that
**baud switching is desktop-only** and Web has no raw TCP. Front-loading the `.EXP` codec and
protocol engine (with mock-transport tests) de-risks the hardest part before any UI work begins.
