# A.Y. Tracker v1.0 — disassembly notes and integration plan

Source: `origin/A.Y. Tracker v1.0.tzx` (Jonathan Cauldwell, 2005). The TZX
contains 6 blocks: a 19-byte BASIC header for "AYtracker", the 4294-byte
tokenised BASIC, and headers + bodies for two CODE blocks: `tracker 0`
($8000, 12 288 bytes) and `tracker 1` ($C000, 2560 bytes).

## BASIC loader — what it tells us up front

The BASIC is the whole shell. It's the menu, the file I/O, the help
screen, *and* the compile step. The interesting bits:

**Memory map (from BASIC POKEs and SAVE/LOAD lengths):**

| Range | Bytes | Contents |
| --- | ---: | --- |
| `$7FFC..$7FFF` | 4 | Saved song header — peeked from `$C834,$C83F,$C840,$C841` |
| `$8000..$87FF` | 2048 | Channel 1 byte stream |
| `$8800..$8FFF` | 2048 | Channel 2 byte stream |
| `$9000..$97FF` | 2048 | Channel 3 byte stream |
| `$9800..$9FFF` | 2048 | Editor data tables (font, prompt buffers, helpers) |
| `$A000..$AFFF` | 4096 | Editor + UI Z80 code |
| `$C000..$C1FF` | 512 | Period / volume / envelope tables (player) |
| `$C800..$C9FF` | 512 | Player code + state |

The tracker0 image contains the **empty-song template baked in**: the
first 6 KB of the binary is `FF BF BF BF…` — i.e. each fresh channel
slot starts with `FF` (no event this frame) followed by `BF` (loop-back-
to-start). So a brand-new editor session shows three idle channels and
play is silent.

**File format on tape** (`SAVE a$ CODE 32764, 6148`):

```
Offset  Bytes   Meaning
+0      1       tempo                       (peeked from $C834)
+1      1       channel-1 player state byte (peeked from $C83F)
+2      1       channel-2 player state byte (peeked from $C840)
+3      1       channel-3 player state byte (peeked from $C841)
+4      2048    channel 1 data
+2052   2048    channel 2 data
+4100   2048    channel 3 data           total = 6148
```

A song is **always 6 KB on tape** regardless of length — fixed-size
slots, padded with `BF`.

**Compile mode** (line 5000 of BASIC). Writes a *standalone* `.tap`
containing:

1. The 2.5 KB player binary, with channel-base pointers patched at
   runtime offsets `$C815/$C817/$C819` to point at where each channel's
   data ends up after concatenation.
2. The three channel byte streams, packed back-to-back (each truncated
   at its `$BF`).

The user is told: "call 51200 to init / 51203 to play". That's it —
the entire embeddable runtime is one CODE block plus two `RANDOMIZE
USR` calls.

## tracker0 ($8000-$AFFF) — the editor

Two callable entry points the BASIC uses:

- `USR 43538` ($AA12) — enter EDIT MODE
- `USR 44605` ($AE3D) — print routine driven by `p$` (consumes embedded
  `$16 row col` AT-codes, same protocol as Spectrum BASIC PRINT). The
  whole UI is built by composing `p$` strings and calling this once.

Strings in tracker0 give the full edit-mode language:

```
$A88D  "C-C#D-D#E-F-F#G-G#A-A#B-C-??????----LOOP (1-3)"
$A8BE  "OCTAVE?"
$A8C8  "INSTRUMENT? (A-D)"           # 4 instruments, single letter
$A8DC  "CHANNEL?"
$A8E7  "ARE YOU SURE? (Y/N)"         # confirm idiom
$A8FD  "ALTER VOLUME WITH CURSOR UP/DOWN."
$A921  "ALTER TEMPO WITH CURSOR UP/DOWN."
$A967  " .mjnhbgvcdxsz"              # piano keymap (one octave)
```

The piano map is a flat 14-byte table. Index = semitone (0..13), value
= key char, so the lookup is a `cpir` over the bottom + middle QWERTY
rows. Key/note pairs:

`z=C s=C# x=D d=D# c=E v=F g=F# b=G h=G# n=A j=A# m=B ,=C(next) .=spare`

A small bitmap font lives at `$A62C..$A6E0` (pattern `06 xx xx xx xx 00 00`
per glyph — 6-byte stride).

**Editor key reference (recovered verbatim from BASIC line 6020-6080):**

| Key | Action |
| --- | --- |
| `P` | Play tune |
| SPACE | Play note (preview the cell under cursor) |
| `W` | Insert loop |
| ENTER | Rest |
| `R` | Go to start |
| `O` | Set octave |
| `I` | Set instrument |
| `U` | Set volume |
| `T` | Set tempo |
| DELETE (CAPS+0) | Delete row |
| EDIT (CAPS+1) | Insert row |
| `9` | Clear channel |
| `0` | Return to menu |

## tracker1 ($C000-$C9FF) — the player

About 75% data, 25% code. Anatomy:

- `$C000..$C1BF`: period table (96 entries × ~2 bytes — note frequencies
  for the AY tone register)
- `$C1C0..$C7F5`: volume / envelope shape tables (`inc(hl)` / `cp 64`
  clamp at `$C94F` reads from `$C1C0`)
- `$C7F6..$C807`: the AY register-write loop. Writes registers 0..10
  to the `$BFFD/$FFFD` ports. Loops 11 times (`cp 11`).
- `$C808..$C82E`: per-channel state cells (current note, volume,
  current pointer, envelope index)
- `$C82F..$C834`: tempo and the three channel-base pointer SLOTS — the
  patchable bytes the compiler rewrites
- `$C835..$C865`: **init** entry. Copies the three start-pointers into
  the working pointers, zeros tick counters, kicks tempo.
- `$C86B..$C916`: **play one frame** entry (`USR 51203`). Per channel:
  1. Decrement tick. If non-zero, fall through.
  2. Otherwise read the next byte from the channel pointer.
     - `$BF` → reset pointer to channel start (loop), re-read.
     - `$FF` → no new event (sustain).
     - else → store as the current note/event byte for this channel.
  3. Reset tick to tempo.
- `$C919..$C96C`: helpers — frequency lookup for one channel (shifts
  the event byte: high nibble = octave, low nibble = note within octave)
  and volume/envelope ramp.

So the **byte-stream encoding** is dead simple, one byte per row per
channel:

| Byte | Meaning |
| --- | --- |
| `$BF` | Loop back to start of channel |
| `$FF` | No new event this frame (hold previous) |
| `nnnnxxxx` | Note event: high nibble selects octave, low nibble selects semitone (0..11) |

Instrument and volume must therefore be encoded in additional event
bytes (the `INSTRUMENT? (A-D)`, `SET VOLUME` modes write something —
most likely they widen the cell to a multi-byte event using one of the
unused nibble values, or they write into a parallel state stream). The
4-byte song-header (tempo + 3 player state bytes) corresponds to
*current* tempo + per-channel volume snapshots, restored on LOAD.

The "**LOOP (1-3)**" feature is a higher-level construct: the editor
inserts marker bytes that the player honours alongside the per-channel
`$BF`. Three nestable repeat brackets, hand-edited in the column. PT3
has nothing equivalent — its loop is a single position-list pointer.

## What's actually borrow-worthy

Everything we're missing in `src/tracker.c` is well-paved here.
Crucially, A.Y. Tracker's *whole architecture* is much smaller than
ours:

- Their format is "one byte per row per channel, three flat streams,
  $BF terminates" — flat enough to insert/delete a row by `memmove` of
  one byte.
- Our format (PT3) is a packed variable-length stream with skip-counts,
  instruments, ornaments, envelopes, and a position list. Insert/delete
  row is *much* harder because every command can change the parse
  offset of every following row.

We can't lift their format, but we can lift their **UX patterns**
wholesale, and we can lift the **compile-to-standalone-tape** trick
almost verbatim — we already have PTxPlay at `$B500` and a song slot at
`$C000`; bundling the two into a CODE block with a thin `init/play`
wrapper is the same shape as their tracker1.

# Integration plan for TS Tracker

Items already in `TODO.md` that this analysis confirms (just
re-grounded):

1. **Note preview on SPACE** — A.Y. uses SPACE in edit mode for "play
   this cell on the AY now, don't commit". `read_piano()` at
   `tracker.c:1115` already maps key→semitone; add a sibling
   `preview_piano()` that programs AY R0/R1/R7/R8 directly through
   `ay_ts2068.c` and stops on key release. ~30 LOC, no PTxPlay
   involvement.

2. **`P` = play current pattern; `R` = back to row 0** — A.Y. plays
   from cursor. Right now we leave to the player app. We already have
   PTxPlay loaded; calling `PTx_init(TAPE_SONG_BASE)` then halting in a
   frame loop with `PTx_play()` would do it. `R` is a one-liner — set
   `cursor=0`, recompute `top`, redraw row indicator. Both gated on
   `key_R()` which is already wired for "rescan" only on the directory
   screen, so the binding is free in pattern view.

3. **`9` = clear channel + Y/N confirm** — clears one column for the
   current pattern. Fits cleanly above `show_pattern()` (`tracker.c:1572`)'s
   key-loop. The Y/N modal lives in its own draw helper (the prompts
   at `$A8E7` "ARE YOU SURE? (Y/N)" are stored as full screen
   fragments — same idea, a small `confirm()` helper that draws to
   row 21 and waits).

4. **EDIT/DEL = insert/delete row** — this is where A.Y.'s flat format
   helps and PT3 hurts. **Don't try to operate on the on-disk PT3
   stream**. We already decode into `pattern_view[PV_ROWS_MAX * 3]`
   (cell array) and re-encode on `commit_pattern()`. Insert/delete is
   just a `memmove` over `pattern_view[]`. The hard part is when the
   pattern grows beyond `PV_ROWS_MAX` (PT3 patterns can be up to 64
   rows but vary; the encoder uses the song's row count). For v1 keep
   total rows fixed and just shift cells within the existing row count,
   dropping/duplicating an end row.

5. **`U` = volume entry / `T` = tempo entry** — A.Y. uses a modal
   "ALTER WITH CURSOR UP/DOWN" overlay; we already have a
   `draw_oct_indicator()` (`tracker.c:1190`) pattern. `U` toggles the
   indicator into "volume mode" so up/down adjusts
   `pattern_view[cursor*3+ch].volume` by ±1 (already in `cell_t`),
   redraws cell, exits on any other key. `T` edits `song[99]` (the
   speed byte) and redraws a tempo indicator. The TODO already calls
   these out — confirmed worth doing because A.Y.'s modal-overlay UX
   maps cleanly onto our existing indicator helpers.

6. **ENTER = rest event** — we already display `-=-` for RELEASE
   (decode emits `note=-2`). Make ENTER write `-2` to the cell at
   cursor; the encoder at `tracker.c:864` needs a `cmd == 0xC0` branch.
   Tiny.

7. **`H` = full help page** — A.Y.'s key list is so small they can
   render it in BASIC. Ours can be a single `cls()` + ~15 line
   constants in `pt3_player.c` and `tracker.c`. Match the existing
   TIMEX banner / status idiom rather than inventing a new layout.

Less obvious things the disassembly surfaced that the TODO doesn't yet
capture:

8. **"Compile" feature — bundle song + PTxPlay into a standalone
   .tap.** A.Y.'s line 5000 is conceptually trivial: SAVE the player +
   SAVE the song with the player's pointer slots patched. We can do
   the same with no z80 work:
   - Add `make compiled-tape SONG=foo.pt3 OUT=foo-standalone.tap` that
     produces a single `.tap` containing a CODE block at `$B500`
     (PTxPlay, already built) + the song bytes appended at PTxPlay's
     expected song-base offset, plus a 6-byte BASIC stub `RANDOMIZE
     USR <init>: PAUSE 0` so it auto-runs.
   - Realistically this is a ~100-line Python tool in `tools/` (mirror
     `tools/songs_to_tape.py`). The output `.tap` boots straight to a
     music demo on any TS2068.
   - Two-line README pitch: "drop a `.pt3` in, get a self-contained
     chip-tune cassette". Strong demo value.

9. **Empty-channel template = `FF BF`.** A.Y.'s "new song" doesn't
   need a special empty PT3 template (which the current TODO under
   "create new songs from scratch" frets about). For TS Tracker the
   equivalent is a tiny constant in `tracker.c` — a minimal valid PT3
   song with the header, one position, one all-empty pattern. Ship as
   `static const unsigned char empty_pt3[]` next to the encoder; "New
   song" memcpy's it into `TAPE_SONG_BASE` and falls into edit mode.
   Smaller than it sounds — the empty pattern is three `D0` (FIN)
   bytes.

10. **The `INSTRUMENT? (A-D)` modal — only 4 instruments.** A.Y. ships
    with a fixed bank of 4 hard-coded AY waveforms; the user picks
    A/B/C/D. PT3 has ornaments + 32 samples and we already decode all
    of them. The takeaway is *not* that we should reduce to 4 — it's
    that A.Y.'s modal-prompt UX (single-letter pick, no list browsing)
    maps to our existing `cell_t.sample` directly, and is simpler than
    the "hex sample entry" path called out in the TODO. Worth
    considering: when entering hex digits for sample number, render
    the modal at row 21 with the prompt + current value, accept 2 hex
    keys, dismiss on ENTER. Same code shape as the existing
    `prompt_jump_pattern()` (`tracker.c:1526`).

11. **What *not* to copy:** A.Y.'s 1-byte-per-row format and its
    position-list-less "loop bracket inside a column" idiom. PT3's
    position list is strictly more powerful and our player already
    handles it. Adding a column-level loop marker would mean inventing
    a non-standard PT3 dialect that PTxPlay won't play.

## Suggested ordering

If you want a phasing for the next branch, this is roughly
increasing-effort:

1. SPACE preview, ENTER rest, R-to-top, P-play-pattern, H help page
   (each one ≤ 50 LOC, no encoder change)
2. 9 = clear channel + Y/N confirm helper (reusable for any future
   destructive op)
3. U volume mode + T tempo mode (reuse the indicator helpers)
4. EDIT/DEL row insert/delete (operates on `pattern_view[]`, then
   commit re-encodes)
5. New-song empty template + splash entry (the TODO's "N" key)
6. `make compiled-tape` standalone-bundle tool — Python only, no
   firmware change

Items 1-3 are all small enough they could land as one PR. 4 needs care
around the row-count invariant. 5-6 are independent and can be
sequenced however.
