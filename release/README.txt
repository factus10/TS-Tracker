TS Tracker -- prebuilt tapes (v1.0)
===================================

Two apps for the Timex/Sinclair 2068. Both are standard Spectrum-format
.tap files: load with `LOAD ""` from BASIC, or pass on an emulator's
command line. Each shows a TIMEX title splash -- press any key to start.

  tracker.tap
      The pattern editor. Press N at the first menu to start a NEW song
      with no tape, or S to scan an inserted song tape and edit one.
      Edit notes/volumes, design instruments (E = sample editor,
      T = ornament editor), play with A, and save back to tape with W.
      Full key reference: press K in the editor, or see the manual PDF.

  pt3-player.tap
      The playback-only picker. Boot it, then insert a song tape and
      press S to scan; 1-9 plays a song, A plays all.

  songs.tap
      Six PT2/PT3 chiptunes (the ones in songs/ in the source repo),
      one CODE block per song. Insert AFTER the player (or tracker) has
      booted, then press S to scan it.

  TS-Tracker-Manual.pdf
      The full user manual for the tracker.

Quick start (ZEsarUX)
---------------------

  zesarux --machine ts2068 --tape tracker.tap     (or pt3-player.tap)

After the title splash and the first menu:

  Tracker:  press N for a new song -> V to open the pattern view -> edit.
            (Or insert songs.tap, press S to scan, pick one to edit.)
  Player:   insert songs.tap (F5 menu), press S to scan, then 1-6 to play.
            Rewind (F5 -> Rewind) before each play; CAPS+SPACE stops a scan.

On a real TS2068
-----------------

Same flow with real cassettes (or a TS-PICO in tape mode). When a song
tape physically stops at the end, press CAPS+SPACE to stop scanning.

Source / latest
---------------

  https://github.com/factus10/TS-Tracker
