# TS Tracker 2.1

Undo, channel copy/paste, PT2 import and TS-PICO SD-card support for the machine-code editor introduced in 2.0. The player is unchanged.

**Download `ts-tracker.zip`** below. It contains:

| File | What it is |
| --- | --- |
| `tracker2.tap` | TS Tracker 2, the PT3 song editor |
| `pt3-player.tap` | The playback-only picker (plays PT2 and PT3) |
| `songs.tap` | Six PT2/PT3 chiptunes, one CODE block each |
| `TS-Tracker-2-Manual.pdf` / `.md` | The user manual |
| `README.txt` | Quick start |

Load with `LOAD ""` on a Timex/Sinclair 2068, in an emulator (ZEsarUX, FUSE) or on real hardware via a TS-PICO. At the start screen press **N** for a new song, **S** to scan a song tape, or **P** to browse a TS-PICO's SD card.

## What's new

**Undo.** SYM+U takes back the last edit to the pattern: a note or field, a row insert or delete, a cleared channel, a paste, a transpose. Press it again and the edit is redone. It is one level deep and keeps its snapshot in the unused top of the song slot, so it is unavailable only when the song fills the slot to within 1.5 KB; the hint row says so.

**Channel copy/paste.** CAPS+SYM+C copies the cursor's channel; CAPS+SYM+V pastes it onto the cursor's channel of any pattern, carrying the envelope period over to rows where the pasted notes use the envelope and leaving the other two channels alone. SYM+C/V still copy whole patterns; the clipboard holds one or the other and the wrong paste key is refused with a message.

**PT2 import.** A PT2 song is converted to PT3 as it loads: every note, sample, ornament, envelope and effect, by the same rules the player uses to play PT2, so it sounds the same (the AY register stream of the conversion was compared with the player's own PT2 playback, frame by frame, for every bundled PT2). PT2 sets noise per channel and PT3 per row, so where two channels disagree on one row the last one wins; a PT2 volume 0 becomes 1; PT2's "stop slide" has no PT3 form and is dropped. Saving writes a PT3.

**TS-PICO.** On a 2068 fitted with a TS-PICO and its TPI ROM, `SAVE "TPI:SDCARD"` before loading the editor and every tape operation goes through the Pico: a mounted `.tap` scans and loads with no rewind prompts and saves with no recording prompt. **P** on the start screen browses the SD card's raw `.pt3` files instead; ENTER loads one, and SYM+S writes the song back as a `.pt3` file in the same folder. The start screen shows the ROM's BIOS version when it is present. This part was verified in the emulator against the frames the TPI ROM itself sends, but had not yet met a real TS-PICO when this release was made; a `Pico error nn` message reports the TPI status code if the Pico objects.

**Directory.** The tape (or SD-card) directory holds 64 entries, fifteen to a screen, with a scrolling selection: CAPS+6/7 move, ENTER or a row's digit loads.

## Changes since v2.0

- The song slot is 11.5 KB (2.0: 13.5 KB); the code grew by two kilobytes for the PT2 converter, undo and TS-PICO support.
- The manual gains sections on undo, channel paste, PT2 import and the SD card; the directory keys changed as above.
- Skipping a block while scanning on a TS-PICO no longer uses VERIFY, and the program pages the Pico's 16 K EXROM correctly: both would have failed on hardware in 2.0.
- `pt3-player.tap` and `songs.tap` are unchanged.

## Verification

Eight automated suites drive the exact binary in this bundle in ZEsarUX over its remote protocol and pass: the Z80 pattern codec against a Python reference on every pattern of the bundled songs (105 checks), the arrangement editor, the instrument editors, the editing/playback/de-duplication operations, undo and channel paste, PT2 conversion against a Python reference converter (byte for byte) plus the AY-stream equivalence test, the TS-PICO command frames and SD flow against a fake Pico, and tape load/save through the real EXROM routines with the tape playing in real time. The program has still not been run on a physical TS2068; the TS-PICO support in particular needs that pass.

## Known limitations

- The SD-card browser shows the card's current folder only; change folders from BASIC (`SAVE "TPI:CD name"`) first. Raw-file support is unverified on hardware (see above).
- Undo covers pattern edits, one level; arrangement and instrument edits are not undoable.
- A PT2 bigger than about 5 K may not leave room for its conversion.

## Credits

The replay driver is Sergey Bulba's PTxPlay. The screen layout follows SQ-Tracker. TS-PICO support is built on Gus Pane's TPI protocol and ROM. TS Tracker is a 64K Software production for the Timex Sinclair 2068.
