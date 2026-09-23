#!/usr/bin/env python3
"""Phase 2 tape test: scan, load and save through the real EXROM tape routines.

Launches a private ZEsarUX with build/songs.tap as a REAL tape (--realtape:
ZEsarUX's instant-load traps only serve the ROM's own LOAD, so our direct
EXROM R_TAPE calls need real-time playback) and an output tape (--outtape),
injects build/v2/tracker2.bin, runs it, then drives:
  S (scan)  -> screenshot of the directory
  1 (load first song) -> any key at the rewind prompt -> editor screenshot
  SYM+S (save) -> ENTER (name) -> any key (record prompt) -> saved
Finally parses the output .tap: the data block must equal the loaded song and
decode with tools/pt3codec.py.

Usage: v2_tape_test.py <out_dir> [songs.tap]
"""
import os, re, shutil, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import v2_ui_smoke as U          # Z (ZRCP client), K (key masks), mask(), scr_to_png
ZESARUX = U.ZESARUX
PORT = 10004
U.PORT = PORT
K = U.K
K.update({"s": U.mask(r1=0x02), "sym_s": U.mask(r7=2, r1=0x02), "sym_d": U.mask(r7=2, r1=0x04),
          "y": U.mask(r5=0x10), "enter": U.mask(r6=0x01)})
for d, (row, bit) in {"1": (3, 0x01), "2": (3, 0x02), "3": (3, 0x04), "4": (3, 0x08), "5": (3, 0x10),
                      "6": (4, 0x10), "7": (4, 0x08), "8": (4, 0x04), "9": (4, 0x02)}.items():
    K[d] = U.mask(**{f"r{row}": bit})


def load_syms():
    return {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M)}


def tap_blocks(b):
    pos, out = 0, []
    while pos < len(b):
        n = struct.unpack("<H", b[pos:pos + 2])[0]; pos += 2
        out.append(b[pos:pos + n]); pos += n
    return out


def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    src_tap = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "build/songs.tap"
    tape_in = out / "songs.tap"; shutil.copy(src_tap, tape_in)
    tape_out = out / "saved.tap"
    if tape_out.exists(): tape_out.unlink()
    S = load_syms(); SLOT = S["SLOT_BASE"]
    code = (ROOT / "build/v2/tracker2.bin").read_bytes()
    # expected: the first PT3 block of the input tape (the tape also carries PT2s)
    blocks = tap_blocks(tape_in.read_bytes())
    entries = [(blocks[i][2:12], struct.unpack("<H", blocks[i][12:14])[0], blocks[i + 1][1:-1]) for i in range(0, len(blocks) - 1, 2)]
    pick = next(i for i, (n, l, d) in enumerate(entries) if d[:13] == b"ProTracker 3." or d[:14] == b"Vortex Tracker")
    first_name, first_len, first_data = entries[pick]
    print(f"input tape: {len(entries)} blocks; loading #{pick + 1} = {first_name!r} {first_len} B")

    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1)
    proc = subprocess.Popen([ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT),
                             "--noconfigfile", "--realtape", str(tape_in.resolve()), "--outtape", str(tape_out.resolve())],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    ok = True
    try:
        for _ in range(40):
            try:
                s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
            except Exception: time.sleep(1)
        time.sleep(6)
        z = U.Z(); z.cmd("send-keys-ascii 200 13"); time.sleep(0.5)
        z.cmd("exit-cpu-step"); z.cmd("reset-cpu"); time.sleep(3)
        # inject the program and start it (slot is clean RAM -> start screen)
        z.cmd("enter-cpu-step")
        for i in range(0, len(code), 256):
            z.cmd(f"write-memory-raw {0x8000 + i} {code[i:i+256].hex()}")
        z.cmd(f"write-memory-raw {SLOT} {'00'*32}")
        z.cmd("set-register PC=8000h"); z.cmd("exit-cpu-step"); time.sleep(1.5)
        z.shot(out / "01_start.png")
        # ---- load: inject a one-entry directory for the target song and jump to the
        # directory screen; the real tape has been playing since launch, so the loader
        # skips the blocks ahead of the target and picks it up by name (no rewind needed)
        entry = first_name + struct.pack("<H", first_len) + bytes([3, 0])
        # stop the CPU inside OUR code but not inside an interrupt handler (the ROM's
        # below $100, or our own isr_frames), where IFF is off until its EI --
        # hijacking PC there leaves the next HALT sleeping forever
        isr0, isr1 = S["isr_frames"], S["isr_frames_end"]
        for _ in range(50):
            z.cmd("enter-cpu-step")
            pc = z.pc()
            if 0x8000 <= pc < SLOT and not (isr0 <= pc < isr1): break
            z.cmd("exit-cpu-step"); time.sleep(0.02)
        z.cmd(f"write-memory-raw {S['DIR_BUF']} {entry.hex()}")
        z.cmd(f"write-memory-raw {S['dir_count']} 01")
        z.cmd(f"write-memory-raw {S['song_len']} 0000")
        z.cmd(f"set-register PC={S['t_directory']:04X}h"); z.cmd("exit-cpu-step"); time.sleep(1.0)
        z.shot(out / "02_directory.png")
        z.press("1", settle=0.8); z.shot(out / "03_rewind_prompt.png")
        z.press("any", settle=1.0)                         # any key at the rewind prompt
        t0 = time.time()
        while time.time() - t0 < 360:
            time.sleep(3)
            sl = int(z.cmd(f"read-memory {S['song_len']} 2").strip().replace(" ", "")[:4], 16)
            sl = ((sl & 0xFF) << 8) | (sl >> 8)                       # little-endian word
            if int(time.time() - t0) % 30 < 3:
                r = z.cmd("get-registers"); pc = re.search(r"PC=([0-9a-fA-F]{4})", r).group(1)
                print(f"  load: song_len {sl} PC={pc} after {time.time()-t0:.0f}s")
            if sl == first_len: break
        time.sleep(3)
        print(f"  load finished after {time.time()-t0:.0f}s (song_len {sl})")
        time.sleep(2)
        z.shot(out / "04_loaded.png")
        slot = bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", z.cmd(f"read-memory {SLOT} {first_len}", limit=8)))
        loaded_ok = slot == first_data
        print("loaded song matches the tape block:", loaded_ok)
        ok &= loaded_ok
        # ---- save
        z.press("sym_s", settle=1.0); z.shot(out / "05_save_prompt.png")
        z.press("enter", settle=0.8)                      # accept the name
        z.press("any", settle=0.5)                        # "start recording, then any key"
        t0 = time.time()
        while time.time() - t0 < 120:                      # real-time save ~1500 baud + leaders
            time.sleep(3)
            sv = z.cmd(f"read-memory {S['save_version']} 1").strip()
            if sv == "02": break
        time.sleep(1.5)
        print(f"  save_version now {sv} after {time.time()-t0:.0f}s")
        z.shot(out / "06_saved.png")
    finally:
        if proc.poll() is None: proc.kill()
    # ---- check the output tape
    if tape_out.exists():
        ob = tap_blocks(tape_out.read_bytes())
        print(f"output tape: {len(ob)} blocks")
        if len(ob) >= 2:
            hdr, data = ob[0], ob[1][1:-1]
            name = hdr[2:12]; ln = struct.unpack("<H", hdr[12:14])[0]; p1 = struct.unpack("<H", hdr[14:16])[0]
            same = data == first_data
            print(f"  header: type {hdr[1]} name {name!r} len {ln} load ${p1:04X}; data == loaded song: {same}")
            ok &= same and ln == len(data)
            song = C.Song(data)
            print(f"  decodes: {song.num_patterns()} patterns, round-trip", end=" ")
            bad = sum(C.decode_pattern(song, p).key() != C.decode_streams(C.encode_pattern(C.decode_pattern(song, p))).key() for p in range(song.num_patterns()))
            print("PASS" if not bad else f"FAIL ({bad})"); ok &= not bad
        else:
            ok = False
    else:
        print("output tape not written"); ok = False
    print("TAPE TEST", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
