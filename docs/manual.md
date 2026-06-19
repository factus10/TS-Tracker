---
title: "T S   T R A C K E R"
subtitle: "PT3 Song Editor"
short-title: "TS TRACKER"
header-right: "User Manual"
description: "Compose and edit AY chip-tunes on your own machine"
author: "David Anderson"
author-label: "Written by"
credit:
  - "Plays PT2 and PT3 tunes via the PTxPlay (Bulba) driver"
  - "Companion to the TS Tracker Player"
publisher: "64K SOFTWARE"
year: "2026"
system: "Timex Sinclair 2068"
toc: true
toc-note: "Keep this manual by the keyboard until the key layout is in your fingers."
footer-note: "TS Tracker -- a 64K Software production -- End of manual"
---

# Welcome

TS Tracker turns your Timex Sinclair 2068 into a three-voice music
workstation. You can load an existing **PT3** tune from tape and rework it,
or start a brand new song from nothing and build it up note by note --- no
tape required to begin. When you are happy with the result, TS Tracker writes
it back out to cassette as a standard song file that the TS Tracker Player
(or any PT3 player) can load and play.

The program drives the AY-3-8912 sound chip through the well-known PTxPlay
(Bulba) driver, the same engine used by the player, so what you hear while
editing is what you will hear on playback.

If you are the sort of person who reads the whole manual before touching the
keyboard, good for you --- but you needn't. TS Tracker leads you by the hand
with on-screen menus and a built-in help page (press **K** any time you are
editing). The rest of this booklet fills in the details.

# Loading the program

TS Tracker is supplied as a `.tap` cassette image. Load it the usual way:

```
LOAD ""
```

then start the tape. After a few seconds the **title screen** appears:

```
TS Tracker
PT3 song editor for the TS-2068
a 64K Software production
Press any key to start.
```

Press any key to continue to the first menu.

# The first screen

When the program starts it has no song in memory, so it shows the
**No tape loaded** menu with three choices:

| Key | Action |
|-----|--------|
| `S` | **Scan tape** for songs to edit |
| `N` | **New song** --- start composing with no tape needed |
| `Q` | **Quit** back to BASIC |

If you just want to make a tune from scratch, press **N** and skip ahead to
*The pattern editor*. To work on a song already on cassette, read on.

# Scanning a tape

Press **S** (or SPACE) and start your song tape playing. TS Tracker reads
through the tape and lists every song file it finds, up to nine at a time:

```
1 (PT3) MY TUNE
2 (PT3) DEMO SONG
3 (PT2) OLD FAVOURITE
```

Each entry shows its slot number, its format, and its name. When the last
song has gone by, press **CAPS SHIFT + SPACE** to stop scanning.

From the directory:

| Key | Action |
|-----|--------|
| `1`...`9` | Choose a song to load and edit |
| `R` | Re-scan the tape |
| `Q` | Quit |

Pick a number and TS Tracker loads that song into memory.

> **Note:** TS Tracker can *edit* PT3 songs. PT2 songs can be loaded and
> played, but not edited in this version --- the editor will tell you so if
> you try.

# The song information screen

Whether you loaded a song or started a new one, you arrive at the
**Song info** screen. It shows the tune's vital statistics:

| Field | Meaning |
|-------|---------|
| File | The song's name |
| Type | PT3 (or PT2) |
| Speed | Playback speed value |
| Positions | Length of the song, and its loop point |
| Patterns | How many patterns the song uses |

From here press **V** to open the pattern editor, or **Q** to go back.

# The pattern editor

This is where the work happens. A *pattern* is a short block of up to 64
**rows**, and each row holds one event for each of the three sound channels
(**A**, **B** and **C**). A song plays its patterns one after another in the
order set by its position list.

The editor shows sixteen rows at a time:

```
Pat 00/00 Row 00 Ch:A Oct:4
RR  ChA s   ChB s   ChC s
00  C-4 .  --- .  --- .
01  --- .  --- .  --- .
02  --- .  --- .  --- .
...
```

- The line at the top tells you the current **pattern number**, the
  **cursor row**, the active **channel**, and the current **octave**.
- Each channel cell shows a **note** and a **sample** number. `---` means
  "nothing here"; `-=-` is a **rest** (stop sounding); `C-4` is the note C
  in octave 4.
- Every fourth row is tinted **cyan** and every sixteenth **yellow**, so you
  can find the beat at a glance, like the bar lines on sheet music.
- The cursor highlights one cell. The right-hand `s` column shows that
  cell's sample.

At the bottom, **Free: NNNNN bytes** tells you how much room is left for the
song when it is saved.

## Moving around

| Key | Moves |
|-----|-------|
| CAPS SHIFT + `7` / `6` | Up / down a row |
| CAPS SHIFT + `5` / `8` | Left / right between channels A, B, C |
| `R` | Jump to row 0 (top of the pattern) |
| `O` / `P` | Previous / next pattern |
| `F` | Jump to a pattern by number (type two hex digits) |

A joystick works for up/down/left/right as well.

> **Your edits are never lost.** Unlike many trackers, TS Tracker keeps the
> whole song decoded in memory while you work. Moving between patterns,
> playing the song, and saving all happen automatically --- there is no
> separate "commit" step to remember. Just edit and go.

## Entering notes

TS Tracker lays a piano keyboard across two rows of keys. The bottom row
gives the natural notes; the row above gives the sharps:

```
  sharps:  S  D     G  H  J
  notes:  Z  X  C  V  B  N  M
          C  D  E  F  G  A  B
```

| Key | Note | Key | Note |
|-----|------|-----|------|
| `Z` | C  | `S` | C# |
| `X` | D  | `D` | D# |
| `C` | E  | `G` | F# |
| `V` | F  | `H` | G# |
| `B` | G  | `J` | A# |
| `N` | A  |     |    |
| `M` | B  |     |    |

Press a note key to place that note in the cell under the cursor. The note
sounds briefly through the AY so you can hear what you picked.

The note's **octave** is set by the number keys **1** to **8**. Choose an
octave first, then play notes; pressing a number while the cursor sits on an
existing note re-tunes that note to the new octave.

Other note-entry keys:

| Key | Action |
|-----|--------|
| ENTER | Place a **rest** (`-=-`) --- silences the channel from here |
| SPACE | **Clear** the cell back to empty (`---`) |
| `I` | **Insert** a blank row, pushing later rows down |
| CAPS SHIFT + `0` | **Delete** the row, pulling later rows up |
| `9` | **Clear the whole channel** (asks Y/N first) |

## Setting volumes

Each cell can carry its own volume. Press **U** to switch the editor into
**volume mode** --- the indicator at the top changes from `Oct:` to `Vol:`.
Now the keys **0** to **F** set the volume (0 = silent, F = loudest) of the
cell under the cursor. Press **U** again to return to note mode.

# Hearing your work

You don't need to leave the editor to listen:

| Key | Action |
|-----|--------|
| `A` | **Play the whole song** from the current pattern |
| `L` | **Loop the current pattern** over and over |

Either way, press any key to stop and return to editing. TS Tracker rebuilds
the tune from your edits before it plays, so you always hear the latest
version.

# Saving to tape

Press **W** to save. TS Tracker first rebuilds your song into a proper PT3
file, then asks for a name:

```
Filename (max 8 chars).
Letters / digits / space.
    MY TUNE  01
Bytes:   234
```

Type up to eight characters. TS Tracker adds a two-digit version number
automatically and bumps it on every save, so `MY TUNE 01`, `MY TUNE 02`, and
so on never overwrite each other on the tape.

| Key | Action |
|-----|--------|
| DEL (CAPS SHIFT + `0`) | Erase the last character |
| ENTER | Start recording --- have the tape ready first! |
| `Q` | Cancel |

Start your recorder, press ENTER, and the song is written as a standard CODE
block. Load it back with the TS Tracker Player, or scan it straight back into
the editor.

> If the song has grown too large to fit the cassette buffer, TS Tracker
> refuses to save and tells you so. Remove some notes or patterns and try
> again.

# The help screen

Press **K** at any time in the editor for a full one-screen key reference.
Press any key to return exactly where you left off.

# Quick key reference

**First screen:** `S` scan, `N` new song, `Q` quit.

**Directory:** `1`-`9` choose, `R` re-scan, `Q` quit.

**Song info:** `V` edit patterns, `Q` back.

**Pattern editor:**

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| CAPS+5/6/7/8 | Move cursor | `Z`..`M` | Play notes |
| `O` / `P` | Prev / next pattern | `1`..`8` | Octave |
| `F` | Jump to pattern | ENTER | Rest |
| `R` | Jump to row 0 | SPACE | Clear cell |
| `A` | Play song | `I` | Insert row |
| `L` | Loop pattern | CAPS+0 | Delete row |
| `U` | Volume mode | `9` | Clear channel |
| `W` | Save to tape | `K` | Help |
| `Q` | Back to song info | | |

# Limits and notes

- A song may use up to **14 patterns**.
- When you save, the whole tune must fit the cassette song area (about
  **6.4 K**). The **Free** counter warns you as you approach the limit.
- TS Tracker edits **PT3** songs. **PT2** songs play but cannot be edited.
- An empty first row on a sounding channel is saved as a rest --- silence at
  the start of the pattern --- because the PT3 format always reads row zero.
- Instrument definitions (samples and ornaments) from a loaded song are
  preserved unchanged; this version edits notes, volumes and arrangement,
  not the instruments themselves.

# Credits

TS Tracker is a 64K Software production for the Timex Sinclair 2068. It uses
the PTxPlay (Bulba) AY replay driver, shared with the TS Tracker Player.
The display style follows the period TS2068 convention of the TIMEX banner,
status bar and inverse-video hot-keys.

Happy composing.
