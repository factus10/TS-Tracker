# TS Tracker 2.0

A new editor, written from scratch in Z80 machine code, with an SQ-Tracker-style screen. It replaces the C editor of v1.x. The player is unchanged.

**Download `ts-tracker.zip`** below. It contains:

| File | What it is |
| --- | --- |
| `tracker2.tap` | TS Tracker 2, the PT3 song editor |
| `pt3-player.tap` | The playback-only picker (plays PT2 and PT3) |
| `songs.tap` | Six PT2/PT3 chiptunes, one CODE block each |
| `TS-Tracker-2-Manual.pdf` / `.md` | The user manual |
| `README.txt` | Quick start |

Load with `LOAD ""` on a Timex/Sinclair 2068, in an emulator (ZEsarUX, FUSE) or on real hardware via a TS-PICO in tape mode. At the start screen press **N** for a new song, or **S** to scan a song tape and pick one to edit.

## What's new

**The pattern editor.** Three channels, fifteen rows on screen with the cursor row fixed in the middle and the pattern scrolling under it. Every cell shows its note and its sample, envelope, ornament, volume and command fields. The three menu strips at the top name every command and the key that runs it (SYMBOL SHIFT + the yellow letter); SYM+H shows the whole key map. Piano keys, octave keys, rests, insert/delete row, clear channel, copy/paste pattern, transpose by a semitone or an octave, an edit step, PT3 commands with hex parameter entry (tone slide, portamento, sample/ornament position, vibrato, envelope slide, speed), and the row's envelope period and noise. Every note you type is previewed with its own sample, ornament and envelope while the key is held.

**Instrument editors.** Samples show every field the player reads: tone/noise/envelope enables, signed tone offset with accumulate, signed noise/envelope offset with accumulate, volume, amplitude slide. Ornaments are one semitone offset per line. Both have length and repeat prompts, insert/delete line, create-on-first-edit, and ENTER plays the instrument for as long as you hold it. Up to 64 lines each.

**Arrangement editor and song info.** The position list as a grid: type a pattern number, insert, delete, set the loop point, create a new pattern, change a pattern's length. Title, author and speed are edited in place.

**Playback.** Play from the current position or loop the current pattern. The grid follows the music, the row that is playing is the highlighted one, and when you stop, the cursor is where the music was. Keys 1, 2 and 3 mute channels; a VU meter runs on the detail row.

**Tape.** Scan a tape into a nine-entry directory, load a PT3 by name, save with an eight-character name and an auto-incrementing version. A `*` in front of `SONG` shows the song has changes not yet on tape.

**PT3, exactly.** The song in memory *is* the PT3 file. One pattern at a time is decoded for editing and re-encoded canonically when you leave it, so nothing is lost across pattern switches, plays or saves. Identical channel streams are shared again on save. Saved files load straight into Vortex Tracker II. Songs may use up to 85 patterns and 200 positions in a 13.5 KB slot (v1.2 was capped at 14 patterns in about 7 KB), and Quit returns cleanly to BASIC.

## Changes since v1.2

- The editor is TS Tracker 2 (`tracker2.tap`). The C editor is retired: it still builds from source with `make tracker-classic` and its manual remains in the repository as `docs/manual.md`, but it is no longer part of the default build or this bundle.
- `pt3-player.tap` and `songs.tap` are unchanged.
- New user manual, `TS-Tracker-2-Manual.pdf` (dot-matrix print style) and `.md`.

## Verification

Five automated suites drive the program in ZEsarUX over its remote protocol and pass on the exact binary in this bundle: the Z80 pattern codec against a Python reference model on every pattern of the bundled songs (100 patterns, 105 checks), the arrangement editor, the instrument editors, the editing/playback/de-duplication operations, and tape load/save through the real EXROM routines with the tape playing in real time. The program has not yet been run on a physical TS2068 with this release; reports welcome.

## Known limitations

- Edits PT3 only. PT2 songs are listed by the scan but refused; the player plays them. A PT2-to-PT3 import is on the list.
- No undo.
- Copy/paste works on whole patterns, not single channels.
- Loading is from tape (or a TS-PICO in tape mode), not from TS-PICO files by name.

## Credits

The replay driver is Sergey Bulba's PTxPlay. The screen layout follows SQ-Tracker. TS Tracker is a 64K Software production for the Timex Sinclair 2068.
