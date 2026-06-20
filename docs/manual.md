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
editing). If you would rather learn by doing, jump to *Walkthrough: your first
tune* near the back and follow along; the reference chapters fill in the rest.

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
*The pattern editor* (or to the *Walkthrough*). To work on a song already on
cassette, read on.

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
**Song info** screen. It is the hub you return to from the pattern editor, and
it shows the tune's vital statistics:

| Field | Meaning |
|-------|---------|
| File | The song's name |
| Type | PT3 (or PT2) |
| Speed | Playback speed (tempo) value |
| Positions | Length of the song, and its loop point |
| Patterns | How many patterns the song uses |

From here:

| Key | Action |
|-----|--------|
| `V` | Open the pattern editor |
| CAPS SHIFT + `7` / `6` | Raise / lower the song's **Speed** (tempo) |
| `Q` | Go back |

**About Speed.** It is the number of 50ths-of-a-second the chip holds each
row, so a *larger* number plays *slower*. Most tunes sit around **3 to 6**.
Watch the **Speed** field change as you press CAPS+7 / CAPS+6. The new tempo is
stored with the song and takes effect the next time you play.

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
  **cursor row**, the active **channel**, and the current **octave**. (The
  right-hand part of this line doubles as the edit-mode readout --- see
  *Setting volumes, samples and more* below.)
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

## Setting volumes, samples and more

The **U** key cycles a small edit mode shown at the top right of the info
line, through five settings:

- **Oct** (default) --- the number keys set the octave, as above.
- **Vol** --- the keys **0**-**F** set the volume of the cell under the cursor
  (`0` = silent, `F` = loudest).
- **Smp** --- the keys **0**-**F** set which **sample** (instrument, `00`-`1F`)
  the cell's note plays with; type two digits for samples above `0F`. The
  chosen number shows in the cell's right-hand `s` column.
- **Orn** --- the keys **0**-**F** set the note's **ornament** (the pitch
  arpeggio it plays through, `0`-`F`).
- **Noi** --- the keys **0**-**F** set the **master noise pitch** (`00`-`1F`)
  from this row onward. This only takes on a cell that already has a note or
  rest, because the change rides on an event. The value shows as `Noi:NN`. A
  *low* number is a bright, hissy noise; a *high* number is a low, coarse
  rumble. (Each sample can also nudge the pitch per line --- see the noise
  notes under *The instrument editors*.)

Press **U** again to step on; it wraps back round to Oct. (While in any mode
other than Oct the letter keys feed the value, so press **U** back round to Oct
before using the command keys.)

# The instrument editors

A *sample* is an instrument: a little per-frame envelope that gives a note its
character. An *ornament* is a short pitch arpeggio a note steps through. Press
**E** in the pattern view to open the **sample editor**, or **T** for the
**ornament editor** (they work the same way).

```
Sample 01  loop 00 len 03
LN b0 b1 b2 b3  Vl Tone TNE Ns
00 FF 8A 00 00  A +    0 TN- 05
01 00 8A 00 00  A +    0 TN- 00
02 00 8A 00 00  A +    0 TN- 00
```

Each sample is a short list of **lines** the AY steps through, one per frame,
looping at the **loop** point. Each line is four bytes (`b0`-`b3`); the editor
shows them in hex so every detail of the PT3 format is reachable, with the
decoded **Vl** (volume), **Tone** offset, the **TNE** flags and the **Ns**
noise pitch alongside:

- **TNE** --- whether **t**one, **n**oise and the hardware **e**nvelope are
  flagged on for that line (a letter when on, `-` when off).
- **Ns** --- that line's **noise pitch** (`00`-`1F`), or `--` when noise is off
  on the line. It is added to the song's master noise setting, so a line can
  ride above or below the master pitch.

## Sample editor keys

- **O** / **P** --- choose which sample (`00`-`1F`) or ornament (`0`-`F`) to
  edit.
- **SPACE** --- step the field cursor **forward** through the fields.
- **CAPS SHIFT + 5 / 8** --- step the field cursor **left / right**.
- **0**-**F** --- set the highlighted byte (two hex digits).
- **T** / **N** --- toggle **tone** / **noise** on the cursor's line.
- **CAPS SHIFT + 7 / 6** --- raise / lower the **noise pitch** (`Ns`) on the
  cursor's line.
- **len** field --- edit it to grow or shrink the instrument (it forks a
  private copy, so a second instrument won't disturb the first).
- **Q** --- return to the pattern view.

The fields the cursor steps through are: **loop**, **length**, then each
line's bytes (four per line for a sample, one for an ornament). Setting the
**len** field gives the instrument its own private copy, so you can build a
second distinct instrument without disturbing the first. Up to 13 lines are
shown at once.

For an ornament, each line is a single signed note offset, shown in decimal
(e.g. `+0`, `+4`, `+7`).

To use an instrument, set a note's sample (`U`-`Smp`) or ornament (`U`-`Orn`)
number in the pattern editor, then `A` to hear it.

> **A word on the `E` (envelope) flag.** `E` shows whether a line is set to use
> the AY's hardware envelope generator. The flag is shown so that envelopes in
> songs you *load* survive editing and saving. Authoring a hardware envelope
> from scratch (choosing its shape and speed) is not in this version --- for
> now, design timbres with the **Vl** column and noise, which covers the vast
> majority of chip sounds.

# How instruments make sound

This is the part that takes a moment to click, so it's worth a page.

The AY sound chip is told what to do **50 times a second**. A PT3 song does
*not* store those chip settings directly. Instead, every frame the player
works them out fresh, per channel, from three things: the **note** you placed,
the current line of its **sample**, and the current line of its **ornament**.
So you never program the chip directly --- you design the sample and ornament
tables, and the player "performs" them.

Picture a **sample as a strip of frames** --- one line per 1/50th second ---
that the chip steps through and then loops. Each line says, for that instant:
how loud, how far to bend the pitch, whether tone / noise are sounding, and the
noise pitch. A short looping strip of those is what gives a note its
*character* --- a sharp pluck, a steady organ, a noisy hit.

An **ornament** is the same idea for **pitch**: a strip of semitone offsets,
one per frame, added to the note. It only moves pitch, not timbre.

## Reading the columns

- **len** --- how many lines (frames) the instrument has. **loop** --- the
  line it jumps back to after the last, so it repeats forever from there.
  (Sustain by looping on a steady line; "play once then go quiet" by looping
  on a silent line.)
- **LN** --- the line (frame) number.
- **Vl** --- the **volume** for that frame, `0` (silent) to `F` (loudest).
  This is the column you'll use most: the shape of `Vl` down the lines *is* the
  volume envelope.
- **Tone** --- a **pitch offset** for that frame (`0` = none). Small
  alternating values make vibrato; a steady ramp makes a pitch bend.
- **TNE** --- whether **t**one / **n**oise / hardware **e**nvelope are flagged
  on this line. Press **T** / **N** to toggle tone / noise on the cursor's line.
- **Ns** --- the **noise pitch** for the line (`00`-`1F`); `--` when noise is
  off. Press CAPS+7 / CAPS+6 to tune it.
- **b0 b1 b2 b3** --- the raw four bytes, for full control. `Vl` lives in `b1`;
  `Tone` in `b2`/`b3`; the tone/noise switches and noise pitch in `b0`/`b1`.
  The friendly columns and the `T`/`N`/CAPS keys edit these for you, but the
  hex is always there if you want it.

## Editing a line's volume

The quickest way to shape a sound is its volume over time. The decoded **Vl**
column is read from byte **b1**: to set a line's volume, step the field cursor
to that line's **b1** and type the volume as the *second* hex digit. For a
note that rings cleanly, you want **tone on, noise off** --- so first press
**T** until the line shows `T`, and **N** until noise shows `-`, then set the
volume. (The `T`/`N` toggles and the volume share the `b1` byte, so set the
mixer with `T`/`N` first, then the level.)

## Making different sounds

Most instruments are just a **volume envelope** (the shape of `Vl` over the
lines) plus maybe a little `Tone` movement:

- **Organ / sustained** --- several lines all at a steady `Vl` (say `F`), with
  **loop** on a line that holds. The note rings until the next note.
- **Plucked / decay** --- `Vl` starts high and falls, e.g. `F C 9 6 3 0`; loop
  the last (silent) line so it stays quiet. Short + sharp = a blip; longer =
  a mellow pluck.
- **Bass** --- a low note with a steady mid `Vl`, kept short and looping.
- **Vibrato** --- hold `Vl` steady and put small alternating `Tone` values on
  successive lines (e.g. `+8`, `0`, `-8`, `0` …).
- **Chords / arpeggios** --- this is an **ornament**, not a sample. An ornament
  of `0, 4, 7` looping every three frames turns one held note into a major
  chord shimmer (the classic chiptune sound); `0, 3, 7` = minor, `0, 12` =
  octave. Assign it to a note with `U`-`Orn`.
- **Percussion / snare / hi-hat** --- these need **noise** instead of (or as
  well as) tone, plus a fast `Vl` decay. Press **N** to turn noise on (the
  `TNE` column shows `N`), set `Vl` to fall quickly (e.g. `F 9 4 0`), and you
  have a hit. Press **T** to drop the tone for pure noise. **Tune the noise**
  two ways: per line with CAPS+7 / CAPS+6 in the sample editor (the `Ns`
  column) so a hit can sweep bright-to-dark, and per song with `U`-`Noi` in the
  pattern editor to set the master pitch from a row onward. A bright `Ns`
  (low number) gives a hi-hat or snare crack; a dark `Ns` (high number) gives a
  tom or rumble.

## Where it goes

Each frame the player turns this data into the AY's registers: note + ornament
set the channel's **pitch**; the sample's `Tone` is added to that pitch; `Vl`
becomes the channel **volume**; the tone/noise switches set the chip's
**mixer**; and the noise pitch sets the shared noise generator. All of it is
stored inside the song file (the sample and ornament tables, and the noise
settings), so it travels with the tune when you save.

# Hearing your work

You don't need to leave the editor to listen:

| Key | Action |
|-----|--------|
| `A` | **Play the whole song** from the current pattern |
| `L` | **Loop the current pattern** over and over |

Either way, press any key to stop and return to editing. TS Tracker rebuilds
the tune from your edits before it plays, so you always hear the latest
version --- including the tempo you set on the Song info screen.

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

> If the song has grown too large to fit the cassette song area, TS Tracker
> refuses to save and tells you so. Remove some notes or patterns and try
> again.

# Walkthrough: your first tune

Theory is fine, but the keys live in your fingers only after you use them.
Here is a complete pass --- a short loop with a melody, a bass and a drum ---
from a blank machine to a saved tape. Follow along.

**1. Start a new song.** From the first screen press **N**. You land on the
Song info screen; press **V** to open the pattern editor on an empty pattern 0.
The cursor sits on row `00`, channel A.

**2. Lay a melody on channel A.** Octave 4 is fine (the top line shows
`Oct:4`). Place a note every four rows so they fall on the cyan beat lines:

- Row `00`: tap **Z** (C).
- Press CAPS+6 to row `04`: tap **B** (G).
- Down to row `08`: tap **N** (A).
- Down to row `0C` (the next bar line): tap **M** (B).

You have placed four notes, one per beat. Press **A** to hear the loop; press
any key to stop.

**3. Add a bass on channel B.** Press CAPS+8 to move to channel B, then **R**
to jump back to row `00`. Press **2** to drop to octave 2, then:

- Row `00`: **Z** (a low C).
- Down to row `08`: **V** (a low F).

Press **A** again --- melody and bass together.

**4. Add a drum on channel C.** CAPS+8 to channel C, **R** to row `00`. Place
a hit on the off-beats:

- Row `04`: tap any note (say **Z**) --- we will give it a noise instrument.
- Down to row `0C`: **Z** again.

**5. Build a snare instrument.** Press **E** for the sample editor. Press **P**
until you are on a free sample, say `02`. Step to the **len** field (SPACE
twice, or CAPS+5/8) and type **4** for four lines. Now make a noisy decay:

- On each line, press **N** until the `TNE` column shows `N`, and **T** until
  tone shows `-` (pure noise).
- Set the volumes to fall fast: step to line `00`'s **b1** and type the level
  in the second digit so **Vl** reads `F`; line `01` `9`; line `02` `4`;
  line `03` `0`. The `Vl` column now reads `F 9 4 0`.
- Tune the crack: with the cursor on a line, tap CAPS+7 / CAPS+6 to set the
  `Ns` noise pitch to taste (a low number for a sharp snare).
- Set **loop** to `03` (the silent last line) so the hit fires once and stops.

Press **Q** to return to the pattern editor.

**6. Point the drum notes at the snare.** You are on channel C. Press **U**
until the mode reads `Smp:`, then type **02** to set this cell's sample to your
snare. Move to the other drum row (CAPS+6 to row `0C`) and do the same. Press
**U** back round to `Oct:` so the letter keys are commands again.

**7. Set the tempo.** Press **Q** to the Song info screen. Press CAPS+7 / CAPS+6
to set **Speed** --- try `5`. Press **V** to return to the pattern.

**8. Play the whole thing.** Press **A**. Press any key to stop.

**9. Save it.** Press **W**, type a name like `FIRST`, make sure your recorder
is in record, and press ENTER. TS Tracker writes `FIRST   01` to the tape.

That's a finished, saved chip-tune --- three voices, a custom drum, and a tempo
of your own. Everything else in this manual is variations on those steps.

# The help screen

Press **K** at any time in the pattern editor for a full one-screen key
reference. Press any key to return exactly where you left off.

# Quick key reference

**First screen:** `S` scan, `N` new song, `Q` quit.

**Directory:** `1`-`9` choose, `R` re-scan, `Q` quit.

**Song info:** `V` edit patterns, CAPS+7/6 Speed, `Q` back.

**Pattern editor:**

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| CAPS+5/6/7/8 | Move cursor | `Z`..`M` | Play notes |
| `O` / `P` | Prev / next pattern | `1`..`8` | Octave |
| `F` | Jump to pattern | ENTER | Rest |
| `R` | Jump to row 0 | SPACE | Clear cell |
| `A` | Play song | `I` | Insert row |
| `L` | Loop pattern | CAPS+0 | Delete row |
| `U` | Oct/Vol/Smp/Orn/Noi | `9` | Clear channel |
| `E` | Sample editor | `T` | Ornament editor |
| `W` | Save to tape | `K` | Help |
| `Q` | Back to song info | | |

**Sample / ornament editor:**

| Key | Action |
|-----|--------|
| `O` / `P` | Choose instrument |
| SPACE, CAPS+5/8 | Move between fields |
| `0`-`F` | Set the byte (hex) |
| `T` / `N` | Toggle tone / noise (samples) |
| CAPS+7/6 | Noise pitch up / down (samples) |
| `Q` | Back to pattern editor |

# Limits and notes

- A song may use up to **14 patterns**.
- When you save, the whole tune must fit the cassette song area (about
  **7 K**, instruments + patterns combined). The **Free** counter warns you
  as you approach the limit.
- TS Tracker edits **PT3** songs. **PT2** songs play but cannot be edited.
- The master noise pitch (`U`-`Noi`) and the per-line noise pitch (`Ns`) attach
  to a row that carries a note or rest --- they ride on an event, the way the
  PT3 format expects.
- An empty first row on a sounding channel is saved as a rest --- silence at
  the start of the pattern --- because the PT3 format always reads row zero.
- The sample and ornament editors show up to 13 lines of an instrument at once.
- Authoring a hardware envelope (its shape and speed) is not in this version;
  the `E` flag is shown so loaded songs keep theirs.

# Credits

TS Tracker is a 64K Software production for the Timex Sinclair 2068. It uses
the PTxPlay (Bulba) AY replay driver, shared with the TS Tracker Player.
The display style follows the period TS2068 convention of the TIMEX banner,
status bar and inverse-video hot-keys.

Happy composing.
