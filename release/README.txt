TS Tracker -- prebuilt tapes
============================

  pt3-player.tap
      The player itself. Boot this first; it shows the empty-tape menu
      and waits for you to load a song tape. Loads at $8000 with PTxPlay
      at $C000; use the tape's standard `LOAD ""` from BASIC.

  songs.tap
      Six PT2/PT3 chiptunes (the same ones bundled in songs/ in the
      source repo) packed as one CODE block per song. Insert this AFTER
      the player has booted, then press `S` to scan it.

Quick start (zesarux)
---------------------

  zesarux --machine ts2068 --tape pt3-player.tap

After the player's boot screen comes up:

  1. Eject pt3-player.tap, insert songs.tap (zesarux: F5 menu).
  2. Press S to scan -- the directory fills as each song is found.
     The emulator will auto-loop the tape; the player stops scanning
     when it sees a duplicate.
  3. Rewind the tape (zesarux: F5 -> Rewind).
  4. Press 1-6 to play a song, A to play all, R to rescan, Q to quit.

On a real TS2068
-----------------

Same flow with two real cassettes (or one cassette per side, with a
TS-PICO etc.). When the song tape physically stops at the end, press
CAPS+SPACE to tell the player you're done scanning.

Source / latest
---------------

  https://github.com/factus10/TS-Tracker
