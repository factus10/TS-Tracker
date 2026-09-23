TS Tracker -- prebuilt tapes (v2.2)
===================================

Two apps for the Timex/Sinclair 2068. Both are standard Spectrum-format
.tap files: load with `LOAD ""` from BASIC, or pass on an emulator's
command line.

  tracker2.tap
      TS Tracker 2, the PT3 song editor (all machine code, SQ-Tracker
      style screen). At the start screen press N for a NEW song, or
      S to scan an inserted song tape and pick one to edit. The three
      menu strips at the top name every command; each runs with
      SYMBOL SHIFT + the yellow letter. SYM+H shows every key.
      Full guide: TS-Tracker-2-Manual.pdf (or the .md).

  pt3-player.tap
      The playback-only picker. Boot it, then insert a song tape and
      press S to scan; 1-9 plays a song, A plays all. Plays PT2 and PT3.

  songs.tap
      Six PT2/PT3 chiptunes (the ones in songs/ in the source repo),
      one CODE block per song. Insert AFTER the editor or player has
      booted, then press S to scan it. The editor converts PT2 songs to
      PT3 as they load; the player plays both formats.

  TS-Tracker-2-Manual.pdf / .md
      The user manual for the editor.

Quick start (ZEsarUX)
---------------------

  zesarux --machine ts2068 --tape tracker2.tap     (or pt3-player.tap)

After loading:

  Editor:  press N for a new song -> type notes with Z S X D C V G B H N J M
           -> SYM+A plays -> SYM+S saves to tape.
           (Or insert songs.tap, press S to scan, press the song's number.)
  Player:  insert songs.tap (F5 menu), press S to scan, then 1-6 to play.
           Rewind (F5 -> Rewind) before each play; CAPS+SPACE stops a scan.

On a real TS2068
-----------------

Same flow with real cassettes. When a song tape physically stops at the
end of a scan, press SPACE (editor) or CAPS+SPACE (player) to end the scan.

With a TS-PICO and its TPI ROM: SAVE "TPI:SDCARD", mount a .tap and
LOAD "" as usual; S then scans the mounted .tap with no rewind prompts.
The editor's start screen also offers P to browse the SD card's .pt3
files directly (the current folder; saving writes a .pt3 file back).
This part is new and was verified in the emulator against the ROM's
protocol, not yet on hardware -- a "Pico error nn" message shows the
TPI status code if the Pico objects.

Source / latest
---------------

  https://github.com/factus10/TS-Tracker
