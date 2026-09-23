# TS Tracker — status & TODO

> **Sept 2026 — TS Tracker 2 shipped.** The all-assembly, SQ-Tracker-style
> editor (`asm/v2/`, `make tracker2`) replaced the C editor in v2.0: plan and
> per-phase results in [`docs/redesign-plan.md`](docs/redesign-plan.md), user
> manual in [`docs/manual-v2.md`](docs/manual-v2.md). The C tracker below is
> **retired** (`make tracker-classic` still builds it; `docs/manual.md` is its
> manual). The player (`src/pt3_player.c`) is unchanged.

## TS Tracker 2 — backlog

- [x] **PT2 import** — converted on load (`asm/v2/pt2conv.asm`, reference
      `tools/pt2conv.py`). PT2's per-channel noise becomes the row's noise (the
      last channel wins when two differ on one row); PT2 volume 0 becomes 1;
      "stop slide" has no PT3 form and is dropped.
- [x] **Undo** — one level, whole pattern (SYM+U; again = redo). The snapshot
      lives in the unused top of the song slot, so it is unavailable only when
      the song fills the slot to within 1.5 KB.
- [x] **Per-channel copy/paste** (CAPS+SYM+C / CAPS+SYM+V).
- [x] **TS-PICO native file loading** (`asm/v2/pico.asm`, 2026-09-23) — with
      Gus Pane's TPI ROM the tape calls already reach the Pico; the editor now
      pages the 16K EXROM correctly, sets the TPI system variables, sends
      "TPI:" commands byte for byte like the ROM, and **P** on the start
      screen browses the SD card's raw `.pt3` files (`FMODE=RAW` + `REWIND`,
      then the usual scan: the Pico serves the files as a tape). Save writes
      a raw file when the song came from the card. The directory grew to 64
      entries with a scrolling cursor. Verified by `tools/v2_pico_test.py`
      against a fake Pico; **not yet on hardware**.
- [ ] Hardware verification on a real TS2068 (the suites run in ZEsarUX).
      For the TS-PICO in particular, check on the machine:
      1. `SAVE "TPI:SDCARD"`, mount the release `.tap`, `LOAD ""` the editor,
         **S**: the scan lists the songs (skipping is now "ask for the next
         header", no VERIFY), a song loads without a rewind prompt, SYM+S
         saves into the `.tap` without a "start recording" prompt.
      2. **P**: the start screen must show `TS-PICO TPI BIOS nn`; the card's
         `.pt3` files must appear (header per file: first 10 characters of
         the name, its size). If the list is empty or `Pico error nn` shows,
         `FMODE=RAW` does not serve the directory as a tape on this firmware:
         try `SAVE "TPI:FMODE=RAW"` + `LOAD "" CODE 53248` in BASIC to see
         what a raw-mode LOAD returns, and adjust `sd_begin` / the scan.
      3. A raw save (`SAVE TO SD CARD`) must create `NAME    nn` in the
         current folder; the program then sends `FMODE=TAP`.
      4. A quit must leave `TP_MODE` as it was found.

## Verification recipe

`make tracker2` and `make tracker2-demo SONG="songs/3BIT - Kenotron - KENO50 (Paradox version).pt3"`,
then `tools/v2_codec_test.py`, `tools/v2_arrange_test.py <dir>`,
`tools/v2_instr_test.py <dir>`, `tools/v2_phase4_test.py <dir>`,
`tools/v2_phase6_test.py <dir>`, `tools/v2_pt2_test.py`,
`tools/v2_pico_test.py <dir>` and, alone, `tools/v2_tape_test.py <dir>`
(`<dir>` without spaces: the emulator's screenshot command needs that). All
must pass before a release.

---

# The retired C editor (v1.2) — history

Work on the tracker (`src/tracker.c`). The player (`src/pt3_player.c`) is
shipped and stable. For how the editor is built, see `docs/architecture.md`;
for emulator-verification lore see `docs/zesarux-screenshots.md`.

## Current status (June 2026)

The editor is feature-complete for single-song authoring and editing:

- **No-tape authoring** — splash → `N`ew song drops into an empty pattern.
- **Decoded-model editing** — all patterns decoded in RAM; edits are instant and
  lossless across pattern switches; **no manual commit**. The PT3 byte stream is
  regenerated on demand (`rebuild_song`) only for play/save.
- **Save to tape** — `W` rebuilds + writes a fresh CODE block via the EXROM
  SA-BYTES trampoline; 8-char name + auto-incrementing 2-hex version suffix.
- **Denser grid** — 16 visible rows with yellow/cyan beat-line banding.
- **In-editor playback** — `A` play song, `L` loop current pattern.
- **Per-cell sample** — `U` cycles Oct/Vol/**Smp**; Smp mode sets a note's
  instrument number.
- **Instrument editors** — `E` sample / `T` ornament: full-fidelity edit of
  every byte/line, create/resize (in-slot append + rebuild). Per-cell sample
  AND ornament assignment via `U` (Oct/Vol/Smp/Orn); ornaments preserved
  (3-byte cell kept via bitfield, so MAX_PATTERNS still 14).
- **Tone/Noise toggles** — the sample editor's `TN` column + `T`/`N` keys flip
  the mixer bits, so "clean tone vs. noisy snare" is one key (no hex needed).
- **Help** — `K` shows a full key reference. (Save=`W`, Help=`K`; `S`/`H` are
  the C#/G# piano keys.)

Its known issues (14-pattern cap, ~170 B headroom, PT2 view-only) and its
backlog were resolved by, or moved into, TS Tracker 2.

## Sound editor overhaul (in progress, funded by the Phase-1 RAM reclaim)

- [x] **Phase 1 — per-line noise pitch + envelope display** — the sample editor
      now decodes `b0`: an `Ns` column shows the per-line noise pitch (`b0` bits
      1-5, the offset added to the master noise base, which defaults to 0 so it
      sets AY noise period 0-31 directly), CAPS+↑/↓ nudge it on the cursor line,
      and a `TNE` indicator shows the hardware-envelope enable (`b0` bit0). Noise
      pitch reads `--` on a line whose noise is muted.
- [x] **Phase 2 — tempo/speed editing** — the Song Info hub (the screen you land
      on per song and return to from the pattern view) edits the song's default
      speed (`song[100]`, PT3 delay = frames/row, higher = slower) with CAPS+↑/↓.
      It's in the header below `base_pat_off`, so `rebuild_song` preserves it and
      the next play (A) uses it. (Per-pattern `C_DELAY`/SPCCOMS 0x09 still TODO --
      it needs the Phase-3 FX store.)
- [x] **Phase 3a — pattern-FX: master noise period** — a sparse FX store (in BSS,
      keyed by pat/row/chan; no `cell_t`/model change) now captures the noise
      command (0x20-0x3F) the decoder used to drop, the encoder re-emits it, and
      `U` cycles a new **Noise** mode (Oct/Vol/Smp/Orn/**Noi**) to author it (2-hex
      0-31) on any note/rest cell. Insert/delete/clear keep FX row-aligned.
      Verified: author noise 0x15 on a C-4 -> rebuilt slot = `35 74 D0`.
- [~] **Phase 3b — pattern-FX: hardware envelope** — IMPLEMENTED but DEFERRED on
      branch `phase3b-envelope-deferred`. Authors envelope SHAPE + 16-bit PERIOD
      (SETENV 0xB2-0xBF) and EOff (0xB0) on the 3a FX store; `U` cycles two new
      modes EnS/EnP. It compiles and round-trips, but the code is ~1.9 KB, which
      would drop the song slot from 7168 B to ~5600-5900 B (≈ the original
      pre-RAM-opt size). Deferred by decision to keep the song slot. To ship:
      reclaim slot first (the RAM review's Phase-2 `-Cs--opt-code-size` ~+450 B,
      and/or a smaller MAX_FX), then rebase the branch and re-budget PTX_ORIGIN.
      (Heads-up from research: `decode_channel_row` assumes the 2-byte ESAM form
      (0x10-0x1F); the 0x11-0x1F + envelope form is 4 bytes — scan real songs for
      it before shipping the envelope decode, it could desync the decoder.)

## To consider — ideas from the origin programs

From **A.Y. Tracker** / **Sound Tracker 1.1** (`origin/`). Not committed scope.

- [ ] **Position-list / labelled-loop editor** — expose PT3's loop-position byte
      and let the user reorder/repeat patterns. (Pattern *content* is editable;
      the song's *arrangement* is not yet.)
- [ ] **Compile to standalone playback `.tap`** — PTxPlay + a song + a tiny
      BASIC `RANDOMIZE USR <init>: PAUSE 0` stub that auto-plays on load. No
      firmware change; use `tzxtools` to assemble. "Drop a `.pt3` in, get a
      self-contained chip-tune cassette."
- [ ] **More confirmation prompts** for destructive actions (clear-channel
      already confirms; abandon-edits-on-switch is now moot — edits persist).
- [ ] **`O`/`P`/`Q`/`CAPS` cursor alt** to CAPS+5/6/7/8 — but `O`/`P` are now
      pattern prev/next, so this needs a rebind.

Presentation notes (keep): the TIMEX banner / status-banner / INVERSE-hotkey
idiom (cribbed from `nofile.tap`, shared by A.Y. Tracker) is period-correct.
Coloured volume bars from the player are worth reusing for live-playback preview.

## Done

- [x] PT3 pattern decoder + scrollable pattern view; cell-level cursor
- [x] Piano note entry (`Z..M`), octave select (`1`-`8`) with retune
- [x] Note preview through the AY on entry; volume-per-cell entry (`U` + `0..F`)
- [x] Rest event (`ENTER`); clear note (`SPACE`); clear channel (`9`)
- [x] Insert / delete row (`I` / `CAPS+0`); jump-to-pattern (`F`); jump-to-row-0 (`R`)
- [x] In-editor play song (`A`) / loop pattern (`L`)
- [x] Splash screen; **`N`ew song** (no tape needed)
- [x] **Save-back** — encoder, whole-song rebuild, tape SA-BYTES, editor wiring
- [x] **Decoded-model rearchitecture** — model is source of truth, auto-rebuild,
      no manual commit; empty-row-0 emits a REST instead of refusing
- [x] **Denser grid (16 rows) + beat-line banding**
- [x] **Help page** (`K`, full key reference); Save/Help moved off the piano
- [x] **Per-cell sample + ornament assignment** (`U`: Oct/Vol/Smp/Orn)
- [x] **Full-fidelity instrument editors** — `E` sample / `T` ornament: edit /
      create / resize; ornaments preserved (bitfield keeps MAX_PATTERNS=14)
- [x] **Tone/Noise toggles** — `TN` column + `T`/`N` keys in the sample editor
      (mixer bits verified vs CHREGS; polarity confirmed on real tunes)
- [x] Shared `pt_engine` module; memory reclamation (~1.6 KB freed); PTX_ORIGIN
      raised `$D700→$DAC0` to fund the editor
- [x] Free-memory display; smart incremental redraw
