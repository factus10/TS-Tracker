# TS Tracker — TODO

Outstanding work on the tracker (`src/tracker.c`). The player
(`src/pt3_player.c`) is shipped and stable; items here only affect the
editing app.

## Splash + first screen

- [ ] **Splash screen** — full-screen launch state ahead of the
      current scan-prompt. TIMEX banner across the top (matching
      our existing style), the project name and version centred,
      and "**a 64K Software production**" attribution near the
      bottom. Press any key (or wait N seconds) to proceed to the
      first menu.
- [ ] **"New song" on the first screen** — alongside `S`can / `Q`uit,
      add `N`ew which jumps straight into an empty pattern view
      (no tape required). The directory becomes the second possible
      destination from the splash, not the only one.

## In progress: save-back

Edits in `pattern_view` currently disappear when the user switches
patterns or quits. The save-back project makes them persist into the
song slot at `TAPE_SONG_BASE` and writes the rebuilt song to a fresh
tape block. Phasing:

1. **Encoder** — `pattern_view` → PT3 channel byte stream, with
   skip-count compression and stateful sample / volume / ornament
   tracking. Build a round-trip test (decode → encode → decode, diff).
2. **Whole-song rebuild** — re-emit pattern table + concatenated
   pattern data in place inside the song slot, fixing up every
   downstream offset. Verify the rebuilt blob still plays via the
   `pt3-player.tap`.
3. **Tape SA-BYTES** — write a fresh CODE block via the EXROM
   page-in trampoline (mirror of the existing LD-BYTES path).
   8-char filename from the user, with an auto-incrementing 2-digit
   hex version suffix appended (`MYSONG 01`, `MYSONG 02`, …).
4. **Editor wiring** — `S` to save, dirty flag, switch-warning
   prompt, version counter.

**Save-time constraint:** refuse if any active channel has an empty
row 0 — PT3 always reads commands for row 0, so an empty cell there
isn't representable. Cursor jumps to the offending cell.

## Editor UX backlog

- [ ] Hex sample entry — right cursor column edits the sample digit
      instead of the note
- [ ] Octave-shift current cell up / down as a separate operation
      from setting the base octave (currently the same key does both)
- [ ] Live playback while editing — PTxPlay running against the
      current edit buffer; per-channel mute keys carry over from the
      player
- [ ] Create new songs from scratch, not only edit tape-loaded ones
      (the "New song" splash entry above). Per the A.Y. Tracker analysis
      in `docs/aytracker-analysis.md`, the empty template can be a tiny
      `static const unsigned char empty_pt3[]` — header + one position +
      one pattern with three `$D0` FIN-only channel streams. memcpy into
      TAPE_SONG_BASE, drop into edit mode. Doesn't need the full
      "synthesize a valid PT3 from scratch" project we previously
      sketched.

## To consider — features from the origin programs

Catalog of ideas surfaced by reading **Sound Tracker 1.1** and
**A.Y. Tracker v1.0** in `origin/`. Not committed scope; revisit when
core editing + save-back land.

From A.Y. Tracker (Jonathan Cauldwell, 2005) — closest cousin to what
we're building, single-screen menu + edit mode:

- [ ] **Note preview** — cursor on a cell, press a key, hear the
      note through the AY before committing. (A.Y. Tracker uses SPACE
      for this; we already use SPACE for "clear note", so we'd need
      to rebind one of them.) Implementation per the A.Y. analysis:
      ~30 LOC, program AY R0/R1 (tone period) + R7 (tone enable) +
      R8 (channel A volume) directly via `ay_ts2068.c`, no PTxPlay
      involvement; stop on key release.
- [ ] **Play current pattern / song** from the editor without
      leaving to the player app (`P` key in their model).
- [ ] **Insert / delete row** at cursor — push later rows down
      (insert) or pull them up (delete). Currently we can only
      mutate the cell at cursor. This is core tracker UX.
- [ ] **Clear channel** — wipe one channel's events for the whole
      pattern in a single key.
- [ ] **Jump to row 0** of the current pattern (`R` in their model;
      complements our `F` jump-to-pattern).
- [ ] **Tempo / speed editing** — currently we read the song's
      speed but offer no way to change it. Up/down on a tempo
      indicator like A.Y. Tracker's `T` mode.
- [ ] **Volume per cell** — PT3 supports it (we already decode it),
      we just don't expose entry. UI: a third sub-field within each
      channel cell, or a modal `U` mode like A.Y. Tracker.
- [ ] **Rest event** — explicit "stop sounding here" distinct from
      empty (no event). Maps to PT3's RELEASE; we already display
      it as `-=-` but don't let the user enter one.
- [ ] **Labelled loops (1-3)** — A.Y. Tracker lets the user mark
      sections to loop. PT3's position list already supports this
      via the loop-position byte; could expose a position-list
      editor.
- [ ] **Compile to standalone playback routine** — produce a single
      `.tap` containing PTxPlay (already built at the current PTX_ORIGIN)
      + a song + a tiny BASIC stub `RANDOMIZE USR <init>: PAUSE 0`, and
      the song auto-plays on load. **No firmware change required.** Use
      `tzxtools` (already on user's system) to assemble the .tap rather
      than hand-rolling the block-construction logic. Pitch: "drop a
      `.pt3` in, get a self-contained chip-tune cassette."
- [ ] **Help page** — full key reference accessible from the menu
      and from edit mode, instead of the cramped two-line hint.
- [ ] **Confirmation prompts** for destructive actions (clear
      channel, abandon edits on switch). A.Y. Tracker's `Are you
      sure? (Y/N)` idiom.

From Sound Tracker 1.1 — minimal info available without running it,
but worth flagging:

- [ ] **`O`/`P`/`Q`/`CAPS` cursor support** as an alternate to
      CAPS+5/6/7/8. Old-school Spectrum convention; some users
      have muscle memory for it. Also matches Sound Tracker's
      cassette-era expectations.

Visual presentation notes (already informing our look):

- The TIMEX-banner / status-banner / INVERSE-hotkey idiom we
  cribbed from `nofile.tap` is shared by A.Y. Tracker and
  feels period-correct. Keep.
- Both origin programs are monochrome / two-tone and use full-
  screen text layouts. Our coloured volume bars (in the player)
  are a nice modern addition — worth keeping for live-playback
  preview when that lands.

## Done

- [x] PT3 pattern decoder + scrollable pattern view
- [x] Cell-level cursor (row hex inverse + active channel inverse)
- [x] Channel switch via left / right
- [x] Piano-style note entry (`Z..M`, lower octave)
- [x] Octave selection (`1`-`8`) with retune of existing note
- [x] Free-memory display (`Free: NNNNN bytes`)
- [x] Jump to specific pattern (`F` + 2 hex digits)
- [x] Smart redraw: incremental cursor moves + diff on pattern switch
- [x] Memory map reorg (`$B500` PTxPlay, `$C000` song slot,
      +2.8 KB song headroom)
