# Serial Protocol Reference — v2 & v3 Boot Loaders (Complete Command Set)

This document is a practical, byte-level reference for **every** low-level serial
command the Bernina Artista 180 understands, written for someone building a
serial application that talks to the machine.

> **Scope: this covers both the v2 and v3 boot loaders.** The command layer is,
> byte for byte, the **same** across both ROMs — the 19 commands, their
> arguments, their replies and every status byte are identical. The two ROMs
> differ only in a handful of places around the handshake and the version
> banner:
>
> - **v2** — BIOS version 1.10 / "Mai 97", `V` byte `0B`. This is the ROM in the
>   dump that identifies as `NMMV02.08`.
> - **v3** — BIOS version 1.20 / "July 97", `V` byte `0C`.
>
> See **§0 — Differences between the v2 and v3 boot loaders** for the complete
> list. Where a command's behaviour or reply differs between the two ROMs, the
> difference is called out inline.

It complements the two existing documents:

- [SerialProtocol-old.md](SerialProtocol-old.md) — the original field notes,
  describing the commands that were observed on the wire.
- [HighLevel.md](HighLevel.md) — the higher-level operations (embroidery
  sessions, file transfer) built on top of these primitives.

Everything here was reconstructed from the boot ROMs. The authoritative sources
are the rewritten-in-C boot ROMs — in particular the command dispatcher
`state_idle()` and the state machine `serial_service()`:

- **v3**: `sim_h83003/bernina_artista180/bootrom/boot.c`.
- **v2**: `sim_h83003/bernina_artista180/v2bootrom/boot.c`, with the wire
  behaviour captured in `v2bootrom/protocol_v2.json`.

> **Where these commands run.** The same routine that decodes these commands in
> the boot ROM (`serial_service`) is also called by the running application
> through its main loop (boot ROM vector *slot 1*). So this command set is live
> **both** while the boot ROM is waiting for firmware **and** while the normal
> sewing/embroidery application is running. This is why a host can read memory,
> checksum, and write while the machine is in normal use.

---

## 0. Differences between the v2 and v3 boot loaders

The v3 boot loader is a near-exact superset of v2. The 19 commands, their
arguments, their replies and every status byte are **identical**. The two ROMs
differ only in the version banner and in a few handshake behaviours.

| Area | v2 boot loader | v3 boot loader |
| --- | --- | --- |
| `I` banner | `BiosVersion: 1.10` / `Mai 97` | `BiosVersion: 1.20` / `July 97` |
| `V` version byte | `0B` | `0C` |
| SCI0 (embroidery) arm of the handshake | **absent** — boot ROM only brings up and listens on SCI1 | **present** — polls SCI0 silently as well as SCI1 |
| Line errors during the handshake | **not cleared** each round | **cleared silently** each round |
| Handshake reply with a latched line error | `EBM!` (stray `!`) | `EBM` |

### Why the two behavioural differences matter

**1. SCI0 handshake path.** The v3 ROM brings up *both* serial channels and its
handshake matches the `EB` claim on SCI0 **silently** as well as on SCI1. That
means a v3 host tool can capture the machine by blindly sending `EB` on either
channel. The v2 ROM only ever brings up and listens on **SCI1** (the PC port)
during boot, so you **must** talk to it on SCI1 and it is good practice to wait
for the `BOS` announcement first (see §10). The embroidery-module bridge (`T`
command and the internal port bridge, §7) is the same on both ROMs and still
works once the application is running — only the *boot handshake* is SCI1-only
on v2.

**2. Line errors during the handshake.** A latched receive error
(framing / overrun / parity) is the ordinary state of a serial line at
power-up. v3 clears it silently on every handshake round, so it recovers and
answers a clean `EBM`. v2 does not, so a v2 machine that latches an error at
reset answers the `EB` handshake with an **extra `!` byte** (`EBM!` instead of
`EBM`), and on real H8/3003 hardware a latched overrun (ORER) stops the receiver
until it is cleared — so a v2 machine can be **deaf for the entire handshake
window** and then boot its application. This makes v3 more robust to a noisy
line at connect time. Mitigation on v2: drive a clean idle line before
connecting, and if the handshake misbehaves, power-cycle and retry rather than
assuming the machine is absent.

Because `V` and the `I` banner move together, **`V` is the reliable way to tell
the two ROMs apart over the wire**: `V0B` = v2, `V0C` = v3.

---

## 1. Line settings

| Setting | Value |
| --- | --- |
| Framing | N, 8, 1 (8 data bits, no parity, 1 stop bit) |
| Flow control | None (CTS/DTR/RTS ignored) |
| Start-up baud | 19200 |
| Fast baud | 57600 (switch with the `J` command, see §7) |

The machine has two physical serial channels (SCI0 and SCI1). SCI1 is the PC
port; SCI0 reaches the embroidery module.

- **v3** initialises and listens on **both** channels during boot.
- **v2** initialises and listens on **SCI1 only** during boot — it never brings
  SCI0 up.

The `T` command and the internal port bridge (used for embroidery-module
sessions) are present and unchanged on both ROMs; for ordinary use you talk to
the PC port and everything below applies as written.

---

## 2. Wire conventions (read this first)

These rules apply to **all** commands. Get them right once and every command
below behaves predictably.

### 2.1 Every byte you send is echoed

The machine echoes each character it accepts, one at a time, and only echoes
traffic that *you* sent. **Send the next byte only after you have read the echo
of the previous one.** A command's reply therefore always begins with the
command letter itself, because the letter is echoed before the handler runs.

Two commands deviate: `K` echoes `O` instead of the letter, and any unknown
letter is echoed as `Q` (see §2.4).

### 2.2 Addresses and data are ASCII hex

- An **address** is 6 hex characters = a 24-bit address, most significant nibble
  first. Example: `200100`.
- A **data byte** is 2 hex characters.
- A **length/count** is 6 hex characters.
- Hex letters are **upper case** (`0`–`9`, `A`–`F`). Lower-case hex is not
  accepted as a digit.

### 2.3 Reply / status bytes

Commands that report an outcome end with a single status byte:

| Byte | Meaning |
| --- | --- |
| `O` (0x4F) | Success / OK |
| `N` (0x4E) | Negative — operation refused or verify failed |
| `V` (0x56) | Verify/flash failure — target is not writable flash, or programming did not verify |

### 2.4 Error bytes and how to recover

If something goes wrong you will see one of three bytes come back **in place of
the echo you expected**:

| Byte | Cause | What to do |
| --- | --- | --- |
| `Q` (0x51) | Unknown command letter (also a rejected handshake/confirm byte) | Resync with `RF?` (§2.5) |
| `?` (0x3F) | A non-hex character was sent where a hex digit was expected; the command is aborted back to idle | The machine is already back at idle; resend the command |
| `!` (0x21) | Serial line error (framing / overrun / parity) — a NAK | Resync with `RF?`, then resend |

> On v2 the `!` NAK is also what you may see appended to the boot handshake
> reply (`EBM!`) when a line error was latched at power-up — see §0 and §10.

### 2.5 `RF?` — the resync / "are you there?" trick

`RF?` is **not** a real command. It is a `R` (read) command that you
deliberately abort:

```
R   -> starts a read
F   -> a valid hex digit (accepted, echoed)
?   -> not a hex digit -> the machine echoes '?' and returns to idle
```

The net effect: the machine echoes `RF?` and its protocol state is reset to
idle. Use it to:

- **Probe** whether the machine is listening (you get `RF?` echoed back).
- **Recover** after any `Q` / `?` / `!` — send `RF?`, waiting for each character
  to be echoed, then resume.

---

## 3. Command summary

19 command letters are decoded. Case is significant.

| Letter | Name | Purpose | §  |
| --- | --- | --- | --- |
| `r` | Read byte | Read 1 byte, returned as hex | §4.1 |
| `R` | Read block | Read 32 (0x20) bytes, returned as hex | §4.2 |
| `N` | Dump block | Read 256 bytes as **raw binary** | §4.3 |
| `L` | Checksum | 32-bit sum of a memory range | §4.4 |
| `w` | Write byte | Write 1 byte to RAM/registers, with read-back verify | §5.1 |
| `W` | Write stream | Write a run of bytes to RAM/registers | §5.2 |
| `Z` | Flash byte | Program one byte into flash | §6.1 |
| `M` | Modify flash | Stream bytes into flash from an address | §6.2 |
| `P` | Download | Bulk firmware loader (`PB` bank / `PS` sector) | §6.3 |
| `J` | Baud rate | Change the serial bit rate | §7 |
| `T` | To PC port | `TrME` — switch the protocol onto SCI1 | §7 |
| `I` | Identify | Send the BIOS identification banner | §8.1 |
| `V` | Version | Report the BIOS version byte | §8.2 |
| `K` | Ack / ping | Reply `O`, do nothing else | §8.3 |
| `Y` | Confirm | Wait for a host `Q` and raise the "confirmed" flag | §8.4 |
| `S` | Start app | Jump to the application (primary entry) | §9.1 |
| `G` | Go | Jump to the application (alternate entry) | §9.2 |
| `X` | Reset | Restart the boot ROM | §9.3 |
| `H` | Halt | Stop the machine but keep serving the link | §9.4 |

Any other letter → the machine replies `Q`.

---

## 4. Reading memory

### 4.1 `r` — Read one byte (hex)

```
Send:     r AAAAAA
Receive:  <echo> DD O
```

- `AAAAAA` — 6 hex address digits.
- `DD` — the byte at that address, as 2 hex characters.
- Ends with `O`.

Example:

```
r200100   ->  ...echoes... "4EO"      (byte at 0x200100 is 0x4E)
```

> The region **0x204000–0x207FFF is walled off** and always reads back as `FF`
> through `r` and `R`.

### 4.2 `R` — Read 32 bytes (hex)

Identical to `r` but returns a fixed **32 bytes** (0x20) as 64 hex characters,
then `O`.

```
Send:     R AAAAAA
Receive:  <echo> <64 hex chars> O
```

`R200100` returns the application identity block (version, language,
manufacturer). On the v2 machine the version field reads `NMMV02.08`; a v3
machine returns its own firmware version/language/manufacturer strings, e.g.:

```
R200100  ->  "53524D5630332E30312000467269747A204765676175662041470D004F637420O"
```

This is the workhorse for reading structured data (version strings, status
words, function-call return blocks). It always returns exactly 32 bytes even if
you only care about the first few.

### 4.3 `N` — Dump 256 bytes (raw binary)

```
Send:     N AAAAAA
Receive:  <echo> <256 raw bytes> O
```

Unlike `R`, the 256 bytes come back as **raw binary**, not hex — twice the data
in a quarter of the wire bytes. This is what you use to pull large memory images
quickly. Terminate the block on the trailing `O`.

- There is **no** 0x204000–0x207FFF guard on `N`; it reads straight through.
- When downloading a large range, use `N` repeatedly for full 256-byte pages and
  switch to `R`/`r` for a trailing remainder of ≤ 32 bytes.

Example:

```
N0240F5  ->  "LisaV45Rev8..... ... Cs021...........................O"
```

### 4.4 `L` — Checksum a range

```
Send:     L AAAAAA NNNNNN
Receive:  <echo> SSSSSSSS O
```

- `AAAAAA` — 6 hex start address.
- `NNNNNN` — 6 hex byte count.
- `SSSSSSSS` — the 32-bit arithmetic sum of those bytes, as 8 hex characters.

Example:

```
L0240D5000360  ->  "00004CC9O"     (sum of 0x360 bytes from 0x0240D5 = 0x4CC9)
```

Use it to verify a download landed intact without reading the whole range back.

> If the start address is inside the walled-off 0x204000–0x207FFF window, the
> reply is the sentinel `AFAFAFAF` — a value no real range sums to — so you can
> tell it apart from a genuine result.

---

## 5. Writing RAM and registers

These two commands write to ordinary memory (RAM, I/O registers). They do **not**
program flash — for that see §6. Writing registers is also how you invoke
on-machine function calls (see the "Invoke Machine Function Call" section of
[SerialProtocol-old.md](SerialProtocol-old.md)).

### 5.1 `w` — Write one byte (with verify)

```
Send:     w AAAAAA DD
Receive:  <echo> O|N
```

- Writes byte `DD` to address `AAAAAA`, then **reads it straight back**.
- Replies `O` if the read-back matches, `N` if it does not (e.g. you wrote to
  ROM or to a non-writable address).

Example:

```
w0201E101  ->  ...echoes... "O"      (wrote 0x01 to 0x0201E1, verified)
```

### 5.2 `W` — Write a stream of bytes

```
Send:     W AAAAAA DD DD DD ... ?
Receive:  <echo of everything, including the final ?>
```

- After the 6-digit address, keep sending data bytes as 2-hex-character pairs.
- The address auto-advances after each byte.
- **Terminate by sending any non-hex character** — `?` by convention. The
  machine echoes it and returns to idle.
- Streaming mode does **not** send an `O`/`N` per byte and gives **no final
  status**. If you need confirmation, follow up with a `R`/`r` read or an `L`
  checksum.

Example:

```
WFFFED00061?  ->  writes 0x00,0x61 starting at 0xFFFED0, then '?' ends it
```

> **Practical pattern.** Use `W` to reach the next 256-byte boundary, then switch
> to the bulk `PS` uploader (§6.3) for aligned pages. This mirrors what the
> original PC software does.

---

## 6. Programming flash

Flash is the machine's code/firmware memory. It cannot be written in place a
byte at a time; the boot ROM reads a whole 256-byte page into RAM, patches it,
and reprograms the page. Only the Atmel-A4 part on this machine is programmable;
other identified parts report a failure.

> ⚠️ **These commands modify firmware.** A bad write can leave the machine
> unbootable. Do not use them unless you are deliberately reprogramming the
> device and have a recovery path (the boot ROM download loop, §10).

### 6.1 `Z` — Program one byte into flash

```
Send:     Z AAAAAA DD
Receive:  <echo> O|V
```

- Reads the page containing `AAAAAA`, patches in byte `DD`, and reprograms the
  whole page.
- `O` = programmed and verified. `V` = the bank is not writable flash, or
  programming did not verify.
- Interrupts are masked for the whole operation (code memory cannot be read
  while it is being programmed).

### 6.2 `M` — Modify: stream bytes into flash

```
Send:     M AAAAAA DD DD DD ... <non-hex>
Receive:  <echo ...>  (V on a non-flash bank)
```

- After the address, stream data bytes as 2-hex pairs; the address auto-advances.
- The page under the cursor is held in RAM and only committed to flash when the
  address crosses into the next page — so a run of edits inside one page costs a
  single programming cycle.
- **End the command by sending any non-hex character.** That is not an error: it
  commits the final, partially filled page. There is no other way to stop `M`.
- A bank that is not the Atmel-A4 part replies `V`.

Use `Z` for a single byte; use `M` to edit a contiguous run.

### 6.3 `P` — Bulk download (firmware loader)

`P` is the reason the whole protocol exists. A second letter picks the form:

#### `PS` — one sector (page)

```
Send:     PS SSSS
          (machine replies) O E
Send:     <256 raw bytes>
          (machine replies) O | V
```

- `SSSS` — 4 hex digits; the target address is `SSSS << 8` (page-aligned).
- The machine sends `O` ("ready") then `E` ("send the page").
- You send exactly **256 raw bytes**.
- The machine replies `O` on success, `V` on verify failure.
- If the target is ordinary RAM (not flash), the page is simply stored there and
  acknowledged with `O`.

Example (matches the original software):

```
PS028F   ->  machine: "OE"
             host:    <256 bytes>
             machine: "O"
```

#### `PB` — a whole bank (streaming)

```
Send:     PB BB
          (machine replies) O
Loop:
          (machine) E
          host:     Y  <256 raw bytes>      -> program next page
             or:    <anything but Y>         -> stop
          (machine) O | V   (status of the *previous* page; see note)
End:      (machine) N
```

- `BB` — 2 hex digits; the target address is `BB << 16` (start of a 64K bank).
- The machine streams pages for as long as you answer `Y`. Answer with anything
  else (e.g. `N`) to stop.
- For the Atmel-A4 part, page receive and programming are pipelined, so the
  `O`/`V` status you read is for the **previous** page, not the one you just
  sent. Account for this one-page lag when checking results.
- A bank that does not identify as writable flash replies `V` and stops.

`PB` is for reflashing an entire bank; `PS` is for a single page or for loading
data into RAM.

> The v2 ROM's own firmware image checksums to `H'00FD5AA5`, and a v3-era host
> burner reflashed this ROM (206,492 bytes) over the link with **no change**
> needed — the download path is identical across both ROMs.

---

## 7. Changing baud rate and channel

### `J` — Change baud rate

```
Send:     J DD
          (machine switches rate, then) "BOS"  (at the NEW rate)
          host must re-handshake with "EB" at the new rate (see §10)
```

- `DD` — 2 hex digits written directly into the SCI bit-rate register (BRR).
- After switching, the machine announces itself with `BOS` at the **new** rate
  and waits for the host to re-establish contact (`EB`).
- **Fail-safe:** if the host does not follow within the window, the machine
  reverts to the default rate (BRR `0x11`, 19200) and keeps announcing `BOS`
  until contact is re-made. A bad divisor cannot strand the link — *as long as
  you are quick to re-handshake.*

BRR values (assuming the machine's 11.0592 MHz clock, SMR async ÷1):

| `J` argument | Baud |
| --- | --- |
| `J02` | 115200 |
| `J05` | 57600 |
| `J08` | 38400 |
| `J11` | 19200 (default) |
| `J23` | 9600 |
| `J47` | 4800 |

Typical use: after connecting at 19200, send `J05` to move to 57600, then
immediately re-handshake.

### `T` — Switch the protocol onto the PC port (`TrME`)

```
Send:     T r M E
Receive:  <echo of each> ; on the final 'E' the protocol moves to SCI1
```

- The four characters `TrME` must arrive in order; each is echoed. Any wrong
  character replies `N`.
- On the final `E`, after a short settling delay, the protocol is switched onto
  SCI1 (the PC port).

> The higher-level strings you may see in captures decompose into these
> primitives:
> - `TrMEJ05` = `TrME` (ensure the PC channel) + `J05` (go to 57600).
> - `TrMEYQ`  = `TrME` + `Y` `Q` (the confirm command, §8.4).
>
> Embroidery-module sessions are built on `TrME` plus the internal port bridge
> (the same on both ROMs); see [HighLevel.md](HighLevel.md) for the
> session-level view.

---

## 8. Identity, status and handshaking

### 8.1 `I` — Identify

```
Send:     I
Receive:  <echo> "BERNINA Electronic AG\r" "BiosVersion: X.YY\r" "<month> 97\r"
```

Three CR-terminated strings. Handy as a human-readable "who are you". The version
and month depend on the ROM:

- **v2**: `BiosVersion: 1.10` / `Mai 97`.
- **v3**: `BiosVersion: 1.20` / `July 97`.

### 8.2 `V` — Version byte

```
Send:     V
Receive:  <echo> XX
```

- `XX` — the BIOS version byte as 2 hex characters:
  - **`0B`** on v2 (corresponds to `1.10`).
  - **`0C`** on v3 (corresponds to `1.20`).
- No trailing status byte.
- This is the cleanest one-byte way to tell a v2 ROM from a v3 ROM over the wire.

### 8.3 `K` — Ack / ping

```
Send:     K
Receive:  O
```

Replies `O` and changes nothing. Unlike `RF?`, it does not touch the protocol
state — a clean, side-effect-free "are you alive?".

### 8.4 `Y` — Confirm

```
Send:     Y
Send:     Q
Receive:  <echo Y> <echo Q>       (sets the internal "confirmed" flag)
       or <echo Y> N              (if the second byte was not Q)
```

- After `Y`, the machine waits for the host to send `Q`. On `Q` it echoes it and
  raises a sticky "confirmed" flag that the application can test; anything else
  replies `N`.
- Seen on the wire as part of `EBYQ` / `TrMEYQ` during connection and session
  setup.

---

## 9. Execution control

> ⚠️ These commands change what code is running. `S`/`G` hand control to the
> application and do not return; `X` restarts the boot ROM; `H` stops normal
> operation. Use them deliberately.

### 9.1 `S` — Start the application

```
Send:     S
Receive:  S            (then the machine jumps to the application; no return)
```

Jumps to the application's **primary** entry (the same entry the boot sequence
uses). Sends its own `S` acknowledgement first.

### 9.2 `G` — Go (alternate entry)

```
Send:     G
Receive:  G            (then the machine jumps; no return)
```

Hands control to the application through its **alternate** entry (the longword at
0x200004). The `G` is echoed before control is given away.

### 9.3 `X` — Reset the boot ROM

```
Send:     X
Receive:  X            (then the boot ROM restarts from the top)
```

Masks interrupts and re-enters the boot sequence. After this the machine behaves
as if freshly powered for protocol purposes: it re-announces `BOS` and expects a
fresh handshake (§10). Reverts to the default baud (19200).

### 9.4 `H` — Halt

```
Send:     H
Receive:  H            (machine halts; link stays alive)
```

Stops normal operation (interrupts masked) but keeps servicing the serial link
forever — so the download/command protocol still works, but nothing else runs.

---

## 10. Connecting from cold (handshake)

When the machine powers on (or after `X`), the boot ROM:

1. Brings the bus and the serial channel(s) up at **19200**.
   - **v3** initialises **both** SCI0 and SCI1.
   - **v2** initialises **SCI1 only** — it does not bring SCI0 up.
2. Sends `BOS` (0x42 0x4F 0x53).
   - **v3** polls both channels; **v2** listens on SCI1 only.
3. Offers the link to a host for a fixed window (500 rounds).

To **claim the link**, send `EB`:

- On the PC port (SCI1) each matched character is echoed; a wrong byte draws a
  `Q` and restarts the match (this is why an idle-in-handshake machine answers
  `Q` to stray bytes).
- **v3** matches `EB` on whichever channel completed the match (SCI0 or SCI1).
- **v2** matches `EB` on **SCI1 only**.

> **v2 caveat — do not talk blind.** Because v2 has no SCI0 handshake arm and
> does not clear line errors during the handshake (§0), you should **wait for the
> `BOS` announcement on SCI1 before sending `EB`**, and drive a clean idle line
> beforehand. A line error latched at reset can make a v2 machine answer with a
> stray `!` (`EBM!`) or, on real hardware, go deaf for the whole handshake
> window. v3 clears the error silently and answers a clean `EBM`.

What happens next depends on whether a host grabbed the link and whether the
application flash holds a valid program:

| Situation | Machine sends | Result |
| --- | --- | --- |
| No host connects, app is valid | `BOS` then `N` → **`BOSN`** | Boots into the application (normal power-on) |
| Host connects, or app is invalid | `BOS` then `M` → **`BOSM`** | Stays in the boot ROM download loop, ready for firmware |

So:

- **`BOSN`** at 19200 = the machine is about to run its application normally.
- **`BOSM`** = the machine is sitting in the bootloader waiting for commands
  (your recovery entry point for reflashing via `PB`/`PS`).

Because the application also services this command set (§ intro), you do **not**
have to be in the bootloader to read/checksum/write/switch baud — you only need
the bootloader for programming flash from a cold, non-booting state.

### Baud-change handshake, end to end

```
(at 19200)  machine: "BOS" ...
host:       "EB"                       -> claim the link (SCI1; SCI1-only on v2)
host:       "J05"                      -> request 57600
(rate changes) machine: "BOS"          -> now at 57600
host:       "EB"                       -> re-claim at the new rate, quickly
```

> **Timing warning.** After the rate change the machine announces `BOS` at the
> new rate and gives you only a short window to re-handshake. Miss it and the
> machine falls back to 19200 and announces `BOS` periodically; if it drops all
> the way back it may be unrecoverable without a power cycle.

---

## 11. Recipes

**Probe / resync**

```
RF?              -> expect "RF?" echoed back = machine is listening
K                -> expect "O"                = machine is alive (no state change)
```

**Identify the firmware (and tell v2 from v3)**

```
I                -> banner: BERNINA Electronic AG / BiosVersion / month
                    v2: 1.10 / Mai 97      v3: 1.20 / July 97
R200100          -> application identity strings (32 bytes hex; "NMMV02.08" on v2)
V                -> BIOS version byte: "0B" = v2   "0C" = v3
```

**Dump a large memory range**

```
for each 256-byte page:  N <addr>     -> 256 raw bytes + O
final ≤32-byte remainder: R <addr> or r <addr>
verify:                   L <start> <len>  and compare the 32-bit sum
```

**Write a few settings, then a full page**

```
w AAAAAA DD          -> single verified byte, expect O
W AAAAAA DD DD ... ? -> a short run up to the next page boundary
PS SSSS -> O E -> <256 bytes> -> O   -> the aligned page
```

**Reflash a bank (from the bootloader, BOSM state)**

```
PB BB
loop: read E, send "Y"+256 bytes, read O/V (note the one-page lag)
stop: send a non-Y byte, read N
```

**Go faster**

```
EB   (claim; SCI1-only on v2) -> J05 -> BOS (57600) -> EB (re-claim, quickly)
```

---

## 12. Quick reference card

```
Reads       r AAAAAA            -> DD O                 (1 byte hex)
            R AAAAAA            -> 32 bytes hex + O
            N AAAAAA            -> 256 raw bytes + O
            L AAAAAA NNNNNN     -> SSSSSSSS O           (32-bit sum)

Writes      w AAAAAA DD         -> O|N                  (verified)
            W AAAAAA DD... ?    -> (echo only)          (stream, ? ends)

Flash       Z AAAAAA DD         -> O|V                  (1 byte)
            M AAAAAA DD... <nx> -> (V if not flash)     (stream, non-hex ends)
            PS SSSS -> OE -> 256 bytes -> O|V           (one page)
            PB BB   -> O -> {E, Y+256} ... -> N         (whole bank)

Link        J DD                -> BOS (new rate), re-handshake
            T r M E             -> switch to PC port (SCI1)
            EB                  -> claim link (handshake; SCI1-only on v2)

Info        I                   -> identity banner (v2: 1.10/Mai 97, v3: 1.20/July 97)
            V                   -> version byte: "0B" (v2)  vs  "0C" (v3)
            K                   -> O                     (ping)
            Y then Q            -> confirm flag

Control     S / G               -> start application (no return)
            X                   -> restart boot ROM
            H                   -> halt (link stays alive)

Resync      RF?                 -> reset protocol state to idle

Status/err  O=ok  N=negative  V=verify/flash-fail
            Q=unknown cmd  ?=bad hex digit  !=line error(0x21)

v2 vs v3    V0B/1.10/Mai 97 = v2      V0C/1.20/July 97 = v3
            v2 handshake is SCI1-only and does not clear line errors
```
