# Real-machine verification TODO

Each item lists what we believe, why it's uncertain, and how to check
it. Bring a serial capture (see [SerialCapture.md](SerialCapture.md)) for every
session so results are reproducible.

Priority: **P1** = could cause data corruption / failed transfers; **P2** =
correctness of an edge case; **P3** = nice-to-have confirmation.

---

## Firmware version gating (v2 / v3 / v4)

- [ ] **P1 — Does a v2 module (`NMMV02.08`, code `0x0208`) ever report a
  non-zero extra-data length?** On download we read the two 4-byte length fields
  at `0x028F40` (`fileData` len @+0, `fileExtra` len @+4). Our v2 path
  (`_isLegacyV2Module` in `lib/protocol/machine_controller.dart`) assumes a v2
  module reports **extra length 0** and treats any trailer as absent. Confirm on
  a real v2 machine that `[0x028F40+4..+8]` is `00 00 00 00` for every design.
  If it is non-zero, we need to decide what those bytes are.
- [ ] **P1 — Extra-data trailer on fw `>= 3.09`.** We decrypt the trailer with
  `DesignCipher` and strip an 8-byte frame header on download, and
  frame+encrypt on upload. Verify a real v3.09+/v4 round-trip: download a design
  with colour/settings, re-upload it, confirm the machine shows identical
  colours. Capture the raw trailer bytes for at least one design so we can
  validate the cipher offline.
- [ ] **P2 — fw `>= 2.10` but `< 3.09` (mid v3) extra region.** For this band we
  currently attach the trailer **raw** (no decrypt). Confirm whether such a
  machine actually returns any extra bytes, and if so whether they are plaintext.
- [ ] **P2 — Version banner → code parsing.** `parseVersionCode` turns
  `NMMV0x.xx` into BCD-hex (`NMMV03.01` → `0x0301`). Confirm the banner text of
  each real machine we can reach (sewing `SRMV…`, module `NMMV…`) matches, and
  that the `0x200100` block field order (version, [language on sewing],
  manufacturer, date) is right.

## Boot-loader / handshake (v2 vs v3)

- [ ] **P1 — v2 power-up handshake.** v2 brings up **SCI1 only** and does **not**
  clear latched line errors during the handshake, so it can prepend a `!`
  (line-error NAK). Our engine (`serial_protocol_engine.dart`,
  `_sendAndWaitForEcho`) skips a single leading `!`. Confirm a real v2 machine
  connects, and check whether more than one `!` can appear (would need the skip
  to loop).
- [ ] **P2 — `V` version byte.** Expect `0x0B` on v2 and `0x0C` on v3. Confirm
  over the wire; it's the cheapest one-byte way to tell the ROMs apart.
- [ ] **P3 — Auto-baud / `J` baud switch (19200 ↔ 57600).** Confirm the speed
  upgrade still works on v2 (the boot ROM default is `BRR 0x11` = 19200).

## Low-level capability probes (BEAGLink internals we deliberately skip)

- [ ] **P2 — `0x24040` / `0x24004` reads (Gate A, fw `>= 2.10`).** We read
  these capability/settings registers only on `>= 2.10` and skips them
  on v2. EC never touches them because it drives the high-level machine-function
  layer instead. Confirm from a v3/v4 capture that these reads are **not**
  required for list/download/upload to succeed (i.e. they really are internal
  bookkeeping). If a flow fails without them, we may need to replicate them.
- [ ] **P3 — `0x24044` open probe / `0x24048` extra block address.** Same as
  above but for the `>= 3.09` gate. Confirm EC's staged-block approach
  (`0x028F40`/`0x028F48`) yields the same design bytes obtained via `0x24048`.

## Design data & cipher

- [ ] **P1 — EXP body is plaintext on the wire.** We do **not** decrypt the main
  design body (only the `>= 3.09` extra trailer and the on-disk `.BE` format use
  the cipher). Verify a downloaded body parses as EXP without decryption
  ([ExpFormat.md](ExpFormat.md)).
- [ ] **P1 — Upload block layout.** `createMainDataBlock` writes 2 bytes + 166
  nulls + 4-byte data length + 4-byte extra length + body (ensured `80 81`
  terminated) + extra, to `0x028E98`; preview to `0x024480`; then block-size
  `0x02409D`, attribute `0xA4` @ `0x0240B9`, filename @ `0x0240D5`, store via
  function `0x0201`. Confirm a real upload is accepted and the design is usable
  on the machine. (Note: the bernina reference swaps the two length fields — we
  believe our order is correct; a real upload settles it.)
- [ ] **P2 — Filename length limit.** We reject names `>= 15` chars.
  Confirm the real limit and that we truncate/validate the same way.

## High-level flows

- [ ] **P2 — File listing paging.** We move through pages with functions
  `0x0031` → `0x0061` → `0x00C1` for 27 files/page. Confirm on a machine with
  `> 27` and `> 54` designs.
- [ ] **P2 — Delete timing.** `deleteEmbroideryFile` waits `deleteDelay` (6 s)
  after function `0x0801`. Confirm the delay is sufficient (and not excessive)
  on real hardware; likewise `storeDelay` (5 s) after `0x0201`.
- [ ] **P2 — PC Design Card path.** Confirm card-present detection (`0xFFFED9`
  bit 0), source-select function `0x0051`, and list/download/upload from the
  1 MB Personal Design Card.
- [ ] **P3 — Preview bitmap.** 558-byte preview at `0x02452E + 0x22E*(id%27)`;
  confirm it renders identically to the machine's own thumbnail.