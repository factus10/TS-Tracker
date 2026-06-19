# TS Tracker — architecture & design notes

How the editor (`src/tracker.c`) is put together, why, and the constraints
that shape it. Read this before changing the song-data path or the memory map.

## Two apps, one engine

- **`pt3-player`** (`src/pt3_player.c`) — playback-only picker. Shipped, stable.
- **`tracker`** (`src/tracker.c`) — the pattern editor.
- Both link **`src/pt_engine.[ch]`**: thin asm wrappers around the PTxPlay
  (Bulba) driver — `PTx_init / PTx_play / PTx_mute / silence_channel` — plus the
  AY-mute helper and the 60→50 Hz tempo divider (`pt_play_60to50`). PTxPlay
  itself is assembled to `build/ptxplay.bin` and shipped as a separate CODE
  block on the tape, loaded at `PTX_ORIGIN_HEX`.

## Song data model (the important part)

The editor used to keep the song **only** as a PT3 byte stream at
`TAPE_SONG_BASE`, decoding one pattern at a time and requiring a manual `W`
commit (append-only, dead bytes) or edits were lost on pattern switch. That is
gone. Now:

- **The decoded model is the source of truth while editing.** Every pattern is
  decoded into `cell_t model[MAX_PATTERNS][64][3]` at a *fixed* address
  `MODEL_BASE` (`0x6000`) in the free RAM gap below the C image. `cell_t` is 3
  bytes: `{signed char note; unsigned char sample; unsigned char volume}`
  (note: −1 empty, −2 rest, 0..95 pitch). `pattern_view` is a **pointer alias**
  into `model[cur_pat]`, so the ~15 existing `pattern_view[row*3+ch]` edit sites
  are unchanged; switching patterns just repoints it — instant and lossless,
  **no commit step**.
- **`decode_all_patterns()`** runs once per song load (tape or New). It derives
  the pattern count by scanning the position list (`song[201+i]/3`, max+1,
  clamped to `MAX_PATTERNS`), decodes each into the model, captures
  `base_pat_off` (the song's pattern-table offset) for rebuild, then normalises
  the slot via `rebuild_song()`. **PT3 only** — there is no PT2 decoder, so the
  caller gates on `tape_song_fmt == 0` and `show_pattern` refuses PT2.
- **`rebuild_song()`** regenerates the PT3 byte stream at `TAPE_SONG_BASE` from
  the model, called before play (A/L) and before save (S). It **overwrites in
  place starting at `base_pat_off`**, preserving everything below it (header,
  sample/ornament pointer tables, position list, and the sample/ornament
  *definition* blocks) and re-emitting only the pattern table + concatenated
  pattern data. `song_size` is reset to the new tail each call, so repeated
  rebuilds never accumulate dead bytes. Reuses `encode_channel`, which now
  encodes straight into the slot (no staging buffer).

### PT3 layout assumption (the main correctness trap)
`rebuild_song`'s in-place overwrite is only safe if the pattern table + pattern
data are the **last** things in the file, after the instrument definitions —
i.e. `base_pat_off` ≥ every sample/ornament definition. Standard PT3 files
follow this. The baked-in `empty_pt3[]` template was deliberately **reordered**
so its pattern table (`@224`) and channel streams come after the sample/ornament
defs; `patptr` (header bytes 103/104) points to `0x00E0`. A non-standard song
that interleaves pattern data before instrument defs would be corrupted by
rebuild — not yet guarded. **This is the thing to retest with real songs.**

### Empty row 0
PT3 always decodes row 0, so a literally-empty row 0 on an active channel isn't
representable. `encode_channel` no longer refuses it — it emits a REST (`0xC0`)
at row 0 and a skip to the first real event. On reload row 0 reads as a rest
rather than empty; functionally identical (silent start) since this engine
re-inits each channel per pattern (no cross-pattern note hold).

### Ornaments
`cell_t` carries `ornament` as a 4-bit bitfield packed into the spare nibble of
the volume byte, so the cell stays 3 bytes (a compile-time `sizeof==3` assert
guards it) and MAX_PATTERNS stays 14. The decoder captures ornament into the
cell; `encode_channel` emits the `0x40+orn` command. So ornaments round-trip,
and `U`'s Orn mode assigns them per cell. (This avoided the feared 14→10
pattern cost.)

## Memory map (TS2068, the binding constraint)

The 64K is essentially full. Single source of truth for the constants is the
**Makefile** (`PTX_ORIGIN_HEX`, `TAPE_SONG_BASE_HEX`); `MODEL_BASE`/
`MAX_PATTERNS` live in `tracker.c`.

| Region | Range | Notes |
|---|---|---|
| Display file | `$4000–$5AFF` | 6912 B |
| ZX system vars | `$5C00–$5CB5` | do not stomp |
| **Decoded model** | **`$6000–$7F80`** | `MAX_PATTERNS=14` × 576 B; in the free gap |
| C binary (code+data) | `$8000–~$D7E0` | ~22.5 KB; headroom to PTxPlay shrinks as it grows |
| PTxPlay engine | `$DAC0–$E4FE` | 2622 B (gap to song slot = 2624 B) |
| PT3 song slot | `$E500–~$FAFF` | `SONG_BUDGET` = `$FB00−$E500` = 5632 B |
| Stack / ROM tape buffers | `$FB00+` | reserved |

`PTX_ORIGIN` was raised `$D700→$DAC0` (and `TAPE_SONG_BASE` `$E200→$E500`) to
give the instrument editor code room; the song slot shrank 6400→5632 B but
still holds the largest bundled song (5464 B), so the player is unaffected.
`ptxplay_addrs.h` regenerates from the origin, so only the two Makefile
constants move.

## Instrument editor (samples + ornaments)

`show_instr_editor(kind)` (src/tracker.c) edits both instrument kinds — `E`
opens it for **samples** (kind 0), `T` for **ornaments** (kind 1). They share
the on-tape shape (`[loop,length]` + lines); the editor parameterises on
`SE_TBL`/`SE_LSZ`/`SE_NSL` (sample = 4-byte lines, table @105, 32 slots;
ornament = 1-byte signed-offset lines, table @169, 16 slots). Edited **in place
in the song slot** (no RAM model — see memory map):
- **Edit:** every byte is editable in hex (full PT3 fidelity), with decoded
  Vol (`b1&0x0F`)/Tone (`b2|b3<<8`) for samples, signed note-offset for
  ornaments. SPACE walks a field cursor; `0–F` rolls a 2-hex value into the byte.
- **Create / resize:** editing the `len` field calls `instr_resize`, which
  **appends** the new block at `base_pat_off`, repoints just this instrument,
  bumps `base_pat_off`, and lets `rebuild_song` re-lay the pattern region after
  it. Only this instrument's pointer + `base_pat_off` change — no general
  pointer fix-up. Over-budget resizes roll back. `instr_ensure_private` forks a
  block shared by multiple slots on first in-place edit, so a new song's
  instruments become individually editable. Limits: ≤13 lines shown/editable;
  resized-away old blocks are left as dead bytes (bounded).
- Per-cell assignment: `U` cycles Oct/Vol/**Smp**/**Orn**; Smp sets the cell's
  sample (2-hex, 00..1F), Orn its ornament (0..F). The encoder serialises both
  (`0xD0+smp`/ESAM and `0x40+orn`).

Consequences:
- The decoded model lives in the `$6000` gap precisely because the binary has no
  room. Phase 1 of the rework deleted `commit_pattern`/`key_W`/`encode_buf[1024]`
  to claw back ~1.6 KB; the Makefile overlap check (binary end vs `PTX_ORIGIN`)
  guards regressions — keep that green.
- There is **no free 6912-byte region** for a screen save-buffer (the model
  fills the gap, the song slot is in use). This killed the planned pre-rendered
  LDIR help screen (its image is ~3.9 KB even RLE'd, > the 1.6 KB headroom, and
  nowhere to load it). The help is PRINT-drawn instead — see TODO.

## Screen layout (pattern view)

Rows 0–21 are the usable text area (`cls` clears 0–21; 22–23 are the ZX lower
screen, avoided). Banner(0), status(1), info "Pat/Row/Ch/Oct"(2), column
header(3), **grid rows 4–19 (`VIEW_TOP_ROW=4`, `VIEW_HEIGHT=16`)**, Free(20),
hint(21). Beat lines are PAPER bands written by `draw_pattern_row`: row%16==0
yellow (bar), row%4==0 cyan (beat), else white; the cursor's INVERSE rides on
top. Text output is via ROM `RST $10` control codes (`0x16` AT, `0x10` INK,
`0x11` PAPER, `0x14` INVERSE).
