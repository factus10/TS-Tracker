# TS Tracker v2 — SQ-Tracker-style interface, all-assembly rewrite

*Assessment, interface design, memory map and phased plan. Written 2026-09-22 on
branch `claude/ts-tracker-interface-redesign-1ca94e`. Companion proof of
concept: `asm/ui_poc.asm` (`make asm-poc`).*

| SQ-Tracker (Spectrum, 1993) — the target idiom | TS Tracker v2 proof of concept, running on the emulated 2068 |
| --- | --- |
| ![SQ-Tracker pattern editor](screenshots/sq-tracker-reference.png) | ![v2 PoC pattern editor](screenshots/v2-poc-pattern-editor.png) |

---

## 1. Where we are (measured)

The shipped editor (`src/tracker.c`, v1.2) works, but it is boxed in on every
side by the way it is built:

| Fact | Value | Source |
| --- | ---: | --- |
| Editor source | 2,819 lines of C (z88dk / SDCC) | `wc -l` |
| Compiled image | **21,577 B** (`$8000`–`$D449`) | this build |
| PTxPlay (PT3-only), separate CODE block | 2,275 B (`$D500`) | Makefile |
| Decoded song model | 8,064 B at `$6000` (14 patterns × 576 B) | `tracker.c` |
| Song slot (`$DE00`–`$FAFF`) | **7,424 B** | Makefile |
| Headroom for new editor code | ≈ 180 B before the map has to move again | `$D449` vs `$D500` |
| Full rebuild | **3 min 44 s** (SDCC at `-SO3 --max-allocs-per-node200000`) | `time make tracker` |

How the UI is drawn today: every character goes through the ROM's `RST $10`
print routine with AT/INK/PAPER/INVERSE control codes, and every key is polled
with `IN` followed by a "wait until released" loop. That has three visible
consequences:

- **Redraws are slow.** A 16-row grid repaint is ~500 ROM prints; the ROM print
  path alone measures 12 frames (0.2 s) for that area on the 2068 (§2), and v1
  adds INVERSE/PAPER toggling and per-cell logic on top. Whenever the cursor
  crosses the window edge the whole grid re-paints; you can see it.
- **No auto-repeat.** Holding a cursor key moves one row. Getting from row 0 to
  row 63 is 63 key presses.
- **Only note + sample are visible in the grid.** Volume, ornament and noise are
  hidden behind the `U` mode-cycle (Oct → Vol → Smp → Orn → Noi), which also
  steals the hex letters from the piano while active.

Structurally, the arrangement (position list, loop point) is not editable, there
is no copy/paste/transpose, playback cannot follow the cursor, and the PT3
command column (glissando, portamento, vibrato, envelope, speed) is not
represented in the model at all.

Every one of these is fixable in C in isolation. The problem is that the image
is full: the last round of features had to *buy* their bytes by shrinking the
song slot (`PTX_ORIGIN` went `$D700 → $DAC0 → $D500`), and the hardware-envelope
editor is already parked on a branch because its 1.9 KB would cut the slot back
to ~5.6 KB. The June optimisation review (`docs/optimization-review.md`) got
the easy 4 KB back (CRT diet, PT3-only PTxPlay) and concluded that hand-tuning
individual C functions has poor return: SDCC's output for this kind of
byte-bashing code is fragmented across hundreds of small blocks.

## 2. Should it be rewritten in machine code? Yes — for RAM first, feel second

The 2068 has 64 KB and we need four things in it at once: the screen (6.9 KB),
the editor, the decoded model, and the PT3 song slot. Only one of those is
elastic — the editor — and in C it costs ~22 KB. A comparable Spectrum tracker
written in assembly (SQ-Tracker's editor, Pro Tracker 3, Sound Tracker) is
8–13 KB *including* its player. That is the whole argument: the C toolchain is
spending roughly 12 KB of RAM on codegen overhead, and that 12 KB is exactly
what the song slot and a richer UI need.

### What the proof of concept shows

`asm/ui_poc.asm` is the proposed pattern-editor screen written from scratch in
sjasmplus: three menu bars with hot-key letters, info line, boxed three-channel
grid (15 rows, cursor row pinned to the centre, beat rows brightened), a
per-cell detail panel, position strip and hint bar. It renders straight into
the display file using the ROM font at `$3C00`, reads the keyboard matrix
directly, auto-repeats (0.3 s delay, then 20 steps/s), navigates a six-field
cursor across the three channels, and has SPACE/ENTER/DELETE/octave editing
primitives over a dummy 64-row pattern.

| Metric | v1 (C) | v2 PoC (asm) |
| --- | ---: | ---: |
| Code + data for the screen/keyboard layer | ≈ 5–6 KB (`show_pattern` 2,845 B + `draw_*`/`put_*`/`key_*` helpers, per the optimisation review) | **2,015 B** for a richer screen (2,223 B with the two benchmark aids) |
| Full 15-row grid repaint (**measured**, FRAMES counter, ZEsarUX TS2068) | ROM `RST $10` path: **12.2 frames ≈ 0.20 s** (same 15×32 area, AT+PAPER codes per row, plain glyphs — v1 adds INVERSE toggles and per-cell logic on top) | **3.6 frames ≈ 0.06 s**, unoptimised: `put_char` still saves/restores four register pairs per glyph; ~1.5–2 frames is realistic |
| Build time | 3 m 44 s | 0.004 s |
| Key auto-repeat | none | yes (tunable constants) |
| Fields visible per cell | note, sample | note, sample, envelope, ornament, volume, command |

The PoC is verified in ZEsarUX (TS2068 machine): boots from its own `.tap`
(`tools/mktap.py`), draws correctly, single-step and held cursor moves behave,
SPACE writes a note, ENTER a rest. Press `B` for the renderer benchmark and `N`
for the ROM-print benchmark (results on the hint row). It is not a tracker yet:
no PT3 codec, no PTxPlay, no tape, dummy data. Its job was to answer "is the step-up real?" —
it is.

### Projected v2 footprint

| Component | Estimate | Basis |
| --- | ---: | --- |
| Screen + keyboard + menus + pattern editor | 3.0 KB | PoC is 2.0 KB with editing stubs |
| PT3 decoder + encoder + rebuild | 1.2 KB | C versions are 2,016 B of SDCC output; ~40 % in asm is typical |
| Sample / ornament editors | 1.5 KB | C: `se_draw` + `show_instr_editor` + `instr_resize` = 2,048 B |
| Tape I/O, directory, save prompt | 1.2 KB | trampolines are already asm; UI shrinks |
| Position editor, help, strings, tables | 1.5 KB | |
| PTxPlay (PT3-only) linked in the same binary | 2.3 KB | today's 2,275 B; drops the second CODE block and `ptxplay_addrs.h` |
| **Total** | **≈ 10.5–11 KB** | vs 23.9 KB (21.6 KB C image + 2.3 KB PTxPlay) today |

That frees ≈ 13 KB. Spent on the song slot it takes the slot from 7.4 KB to
≈ 20 KB; spent on the model it doubles the pattern count. See §4.

### What a rewrite does *not* fix, and the risks

- **The AY and PT3 stay the same.** No new sounds appear; the gains are RAM,
  UI density and responsiveness.
- **Correctness of the codec.** `decode_channel_row` / `encode_channel` /
  `rebuild_song` were verified byte-for-byte in June. Porting them is the one
  place a bug would silently corrupt songs. Mitigation in §6: the C encoder
  becomes the reference oracle in an automated round-trip test.
- **Effort.** Roughly 5–7 k lines of assembly across four phases. Each phase
  below ends in a loadable tape, so there is never a long dark period.
- **Two code bases during the transition.** Keep `src/tracker.c` building as
  `tracker-classic` until v2 reaches feature parity, then retire it. The player
  (`pt3_player.c`) is untouched throughout.

### Alternative considered: hybrid (C logic + asm renderer)

Rewriting only the screen/keyboard layer in asm and calling it from C would
recover ~3 KB and the responsiveness, but SDCC's codegen for the codec,
editors and tape UI is the bulk of the image, the 4-minute build stays, and the
song slot barely moves. It also means maintaining a C↔asm calling convention
around IX and the CRT. Not recommended.

**Recommendation: full assembly rewrite, phased, PTxPlay linked into the same
binary, the C tracker kept alongside until parity.**

## 3. Interface design — SQ-Tracker idiom, adapted to PT3 and 32 columns

SQ-Tracker's screen is three regions: a block of menu strips at the top, a
boxed grid with the cursor row held in the middle and the pattern scrolling
under it, and a dense status panel underneath. Its data model differs from ours
(99 single-channel patterns combined per position; 26 lettered samples) so we
borrow the *layout and behaviour*, not the file format — PT3 stays, because
that is what every player and Vortex Tracker understand.

### Screen map (32 × 24)

```
row  0   [ SONG ] Play Loop New Save Ld Quit      menu strip 1 (hot letters bright yellow)
row  1   [ EDIT ] Ins Del Copy Pste Trns Clr      menu strip 2
row  2   [ GOTO ] Pat Posn Smp Orn Help           menu strip 3
row  3   Pos 03/12 Pat 05/14 Spd 06 Oct 4         info line (values bright white)
row  4   Rw│A   seovc│B   seovc│C   seovc         column header
row  5   ┐
  …      │  15 grid rows; the cursor row is ALWAYS screen row 12 (centred)
row 19   ┘
row 20   ──┴─────────┴─────────┴─────────         rule
row 21   Sm 02 Or 1 Vl A En . Free 12345          cursor-cell detail + free bytes
row 22   Posn 00 01 02 [03] 04 05 ..  L=03        position strip, loop point
row 23   ▐ hint / prompt / confirmation bar ▌      inverse cyan
```

Rows 22–23 are used (we own the display file; the BASIC "lower screen" does
not exist for us).

### The cell: `NNN SEOVC` — nine characters per channel

| Column | Field | Display |
| --- | --- | --- |
| 0–2 | Note | `C-4`, `A#3`; `---` empty; `R--` rest (PT3 release) |
| 4 | Sample 0–31 | one base-32 character `1…9 A…V`, `.` = none — Vortex Tracker's convention |
| 5 | Envelope 0–F | hex digit, `.` = none |
| 6 | Ornament 0–F | hex digit, `.` = none |
| 7 | Volume 0–F | hex digit, `.` = unchanged |
| 8 | Command 1–9 | hex digit, `.` = none; parameters shown/edited on the detail row |

`2 + 1 + 9 + 1 + 9 + 1 + 9 = 32`, which is exactly SQ-Tracker's arithmetic.

Colours (SQ palette): black paper; row numbers yellow, bright on beat rows
(every 4th); notes green, bright on beat rows; cursor row bright white; the
cursor *field* black-on-white; separators white.

### Cursor and keys

The cursor has a row, a channel and a **field**. Input is field-aware, which
removes the `U` mode-cycle entirely:

| Field under cursor | Keys |
| --- | --- |
| Note | piano `Z S X D C V G B H N J M` + `,` (C of next octave); `1–8` set octave (and retune an existing note); ENTER = rest; SPACE = clear |
| Sample / Env / Orn / Vol / Cmd | `0–9 A–F` (`G–V` for samples ≥ 16) type the value directly; SPACE clears |

| Always | |
| --- | --- |
| CAPS + 5 / 6 / 7 / 8 | left / down / up / right — with auto-repeat; joystick does the same |
| CAPS + 1 (EDIT) / CAPS + 0 (DELETE) | insert row / delete row (all three channels) |
| SYMBOL SHIFT + letter | the menu-strip commands: SYM+P Play, SYM+L Loop pattern, SYM+N New, SYM+S Save, SYM+D Load/Dir, SYM+Q Quit, SYM+I/X Ins/Del row, SYM+C/V Copy/Paste pattern, SYM+T Transpose, SYM+Z Clear, SYM+F Go to pattern, SYM+O Position editor, SYM+E/R Sample/Ornament editor, SYM+H Help |
| O / P | previous / next pattern (kept from v1 — they sit on the top row and are not piano keys) |

Using SYMBOL SHIFT for commands gives every plain letter back to the piano (v1
had to move Save and Help off `S`/`H`) and is exactly what the menu strips
document on screen. The strips are a live legend, not a mouse target — the
2068 has no mouse; the joystick moves the cursor.

### Screens beyond the pattern editor

- **Position editor** (SYM+O) — SQ's `Position / Replay / Delete / Insert /
  Add`: the PT3 position list as a horizontal strip (row 22 already previews
  it), with insert/delete/replace of a position, set loop point (`L=`), and
  *create new pattern* (SQ's `Create Patt.`). This is the arrangement editing
  v1 never had.
- **Sample and ornament editors** (SYM+E / SYM+R) — same content as today's
  full-fidelity editors (every byte, `TN` mixer toggles, `Ns` noise pitch,
  create/resize) re-skinned in the new renderer, plus SQ's `Length` / `Repeat`
  (loop) fields in the header and a live preview note on SPACE.
- **Playback** — play song from the current position, loop current pattern,
  and **follow mode**: the grid scrolls under the fixed cursor row while the
  song plays, per-channel mute on `1 2 3` (SQ's `O- ON/OF`), a small
  three-channel VU in the menu-strip gutter (v1's player already has the bars).
- **Song / info screen** — PT3 title and author (editable), speed, positions,
  loop; the tape directory and New/Load/Save flow as today.

### Keeping what already works

The splash → `N`ew / `S`can → directory → edit flow, tape names with the
auto-incrementing version suffix, the confirm-before-clear idiom, the free-RAM
counter and the 60→50 Hz playback divider all carry over. The TIMEX banner
gives way to the menu strips, but the title screen keeps the period look.

## 4. Memory map for v2

Verified from the HOME ROM listing (`NEW` at `$0D7F`–): the 2068 keeps its
**BASIC machine stack at `$6000`–`$61FF`** (`MSTBOT` = `$6200`), the dispatcher
above it, `CHANS` at `$6840` and the BASIC program (`PROG`) at `$6856`. The v1
editor overwrote all of this with its model at `$6000`, which is why it never
returned to BASIC cleanly. Two options:

**Plan A — clean return to BASIC (recommended to start)**

| Region | Range | Size | Notes |
| --- | --- | ---: | --- |
| Display file + attributes | `$4000–$5AFF` | 6,912 | |
| Printer buffer → keyboard/UI scratch | `$5B00–$5BFF` | 256 | unused by us otherwise |
| System variables, SYSCON | `$5C00–$5FFF` | 1,024 | keep |
| BASIC stack, dispatcher, loader | `$6000–$69FF` | 2,560 | keep intact → `Quit` returns to BASIC |
| FX side-table, tape directory, editor state, clipboard | `$6A00–$7FFF` | 5,632 | today's BSS, moved out of the code image |
| **v2 code + tables + PTxPlay** | `$8000–$AAFF` | 11,008 | one CODE block |
| **Decoded model** | `$AB00–$CAFF` | 8,192 | 14 patterns × 576 B (3-byte cells) |
| **PT3 song slot** | `$CB00–$FAFF` | **12,288** | vs 7,424 today |
| Our stack, ROM tape workspace, UDG | `$FB00–$FFFF` | 1,280 | SP = `$FF00` |

**Plan B — reset on quit (what v1 effectively does)** — model at `$6000–$7FFF`,
song slot `$AB00–$FAFF` = **20,480 B**. One constant apart from Plan A; can be
switched later once we know how much slot real users need.

Open point: the PoC uses a 4-byte cell (note, sample, env|orn, vol|cmd) so the
command column is representable; that is 768 B per pattern (14 patterns =
10.5 KB, slot 9.7 KB under Plan A). Alternative: keep v1's 3-byte cell and the
sparse FX side table, and store commands there. Decide in Phase 1 once the
codec is ported; both fit.

## 5. Phased plan — every phase ends in a loadable tape

| Phase | Deliverable | Size est. | Notes |
| --- | --- | ---: | --- |
| **0 — done** | `asm/ui_poc.asm`: renderer, keyboard, cursor, auto-repeat, mock edit ops; `tools/mktap.py`; `make asm-poc` | 2.0 KB | this branch |
| **1** | **Playable editor.** Real cell model + PT3 decoder/encoder/rebuild ported to asm; PTxPlay assembled into the same binary; `New song`; Play / Loop pattern; field-aware editing; insert/delete row; octave; help page | +4.5 KB | codec parity test (§6) is the gate |
| **2** | **Tape + arrangement.** Port the EXROM LD-BYTES/SA-BYTES trampolines and directory scan; Save with filename prompt + version suffix; Song/info screen; **position editor** (insert/delete/replace/loop/create pattern) | +2.0 KB | first tape that can replace v1 for authoring |
| **3** | **Instrument editors** re-skinned: samples (with `TN`, `Ns`, envelope flag, Length/Repeat) and ornaments; create/resize; preview note | +1.5 KB | port `instr_resize` / `instr_ensure_private` logic |
| **4** | **SQ parity extras:** copy/paste pattern, transpose channel/pattern (`tUP/tDN`), clear pattern, follow-cursor playback with mute keys and VU, PT3 command column with parameter entry, hardware envelope (un-parks the deferred Phase-3b work) | +1.5 KB | |
| **5** | Manual + README refresh, screenshots, release bundle; retire `tracker.c` (player unchanged) | — | |

Total ≈ 11.5 KB, inside the `$8000–$AAFF` budget with ~0.5 KB spare; if it
runs over, the model start moves up a page — a one-line change.

## 6. How we keep it correct

- **Codec oracle.** The v1 C encoder is the reference. A host-side harness
  (`tools/`) loads the same song into v1 and v2 in ZEsarUX via ZRCP, runs each
  program's rebuild, dumps the song slot with `save-binary`, and diffs. Every
  song in `songs/` must round-trip identically before Phase 1 ships. The same
  harness later checks that v2 saves load in the standalone player and in
  Vortex Tracker II.
- **Fast iteration.** sjasmplus assembles in milliseconds; `make asm-poc`
  already builds a tape. ZEsarUX is driven headlessly: `smartload` from a
  space-free path, key presses by poking the keyboard matrix
  (`set-ui-io-ports`), `save-screen` for screenshots, breakpoints +
  `get-tstates-partial` for timing. All of this is now documented in the
  project memory and reusable.
- **Second emulator + hardware.** Fuse for a second opinion on tape edge cases;
  TS-PICO in tape mode on the real 2068 for each phase's release tape.
- **Reference library.** `~/Documents/Projects/TS2068 Ref Library` supplies the
  verified ROM entry points, keyboard matrix, AY port map and the "(unverified)"
  discipline; the ROM listing settled the stack-location question above.

## 7. Decisions needed before Phase 1

1. **Go / no-go on the full assembly rewrite.** Recommendation: go.
2. **Memory Plan A (clean BASIC return, 12 KB slot) or Plan B (reset on quit,
   20 KB slot).** Recommendation: A first; it is one constant to switch.
3. **Row numbers decimal (SQ, `00–63`) or hex (v1, `00–3F`).** The PoC uses
   decimal. Either is trivial.
4. **Menu commands on SYMBOL SHIFT + letter** (recommended; frees the piano)
   vs plain letters as in v1.
5. **Keep `tracker.c` building as `tracker-classic`** until v2 reaches Phase 3
   parity (recommended), or freeze it at v1.2 in `release/` only.

## Appendix — files on this branch

| Path | Purpose |
| --- | --- |
| `asm/ui_poc.asm` | Phase-0 proof of concept (sjasmplus) |
| `tools/mktap.py` | Wrap a raw binary in a `.tap` with a ROM-BASIC loader (also used for extra CODE blocks) |
| `Makefile` → `make asm-poc` | assembles `build/asm/ui_poc.{bin,sym,lst,tap}` |
| `docs/screenshots/v2-poc-pattern-editor.png` | PoC running in ZEsarUX |
| `docs/screenshots/v2-mockup-pattern-editor.png` | pixel mockup rendered with the ROM font |
| `docs/screenshots/sq-tracker-reference.png` | SQ-Tracker screen (zxart.ee #156612) |
