# TS Tracker — status & TODO

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

Verified via direct function execution (byte-level: model→rebuild→PT3,
empty-row-0 REST) and the real UI (new song → note → `S` saves with the edit).
All committed to `main`.

## Known issues / risks

- **Not yet tested in the UI: real multi-pattern PT3 load + pattern switching.**
  New-song templates only have one pattern. The logic is identical to the
  verified single-pattern path, but exercise it on a real song (Fuse/hardware).
- **`rebuild_song` assumes standard PT3 layout** (pattern table + data last,
  after instrument defs). Non-standard songs that interleave them would be
  corrupted on rebuild — not guarded. See `docs/architecture.md`.
- **`MAX_PATTERNS = 14`** — sized to the `$6000` gap and roughly matched to the
  ~5.5 KB save budget (`SONG_BUDGET = $FB00−$E500`, after PTX_ORIGIN was raised
  to `$DAC0` to fund the editor). Bigger songs need memory-map surgery.
- **Binary is essentially full** — ~170 B headroom below PTxPlay after the
  ornament editor. Future code needs a reclamation pass or another PTX bump.
- **Instrument editor limits** — ≤13 lines shown/editable; a resized-away old
  block is left as dead bytes (bounded).
- **PT2 songs are view/play-only** — no PT2 decoder; the editor refuses them.

## Remaining backlog (committed scope, unbuilt)

- [ ] **Octave-shift current cell** up/down as a separate op from setting the
      base octave (today one key does both).
- [ ] **Live playback while editing** — PTxPlay running against the edit buffer;
      per-channel mute keys carried over from the player.
- [ ] **Tempo / speed editing** — we read `song[100]` but offer no way to change
      it (A.Y. Tracker `T`-mode style up/down).
- [ ] **Multi-pattern UI verification pass** on a real song (see Known issues).
## Sound editor overhaul (in progress, funded by the Phase-1 RAM reclaim)

- [x] **Phase 1 — per-line noise pitch + envelope display** — the sample editor
      now decodes `b0`: an `Ns` column shows the per-line noise pitch (`b0` bits
      1-5, the offset added to the master noise base, which defaults to 0 so it
      sets AY noise period 0-31 directly), CAPS+↑/↓ nudge it on the cursor line,
      and a `TNE` indicator shows the hardware-envelope enable (`b0` bit0). Noise
      pitch reads `--` on a line whose noise is muted.
- [ ] **Phase 2 — tempo/speed editing** — edit `song[100]` (global default speed)
      up/down; later the per-pattern `C_DELAY` (SPCCOMS 0x09) command.
- [ ] **Phase 3 — pattern-FX commands** — author the master noise period
      (`Ns_Base`, opcode 0x20-0x3F) and the hardware envelope (shape+period,
      opcode 0xB2-0xBF, 3 bytes). Needs a per-row FX store: the decoded model is
      note/sample/volume/ornament only, so `decode_channel_row`/`encode_channel`
      currently PARSE-but-DROP these. Least-disruptive option is a sparse
      per-pattern FX list (don't widen `cell_t` — that costs patterns). With FX
      authored, the `E` flag and per-line noise become fully musical.
      (Heads-up found during research: `decode_channel_row` assumes the 2-byte
      ESAM form (0x10-0x1F); the 0x11-0x1F + envelope form is 4 bytes — scan real
      songs for it before shipping FX, it could desync the current decoder.)

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
