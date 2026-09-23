#!/usr/bin/env python3
"""Phase 2 UI test: arrangement editor (SYM+F) and song info (SYM+G).

Boots build/v2/tracker2-demo.tap (Kenotron), drives:
  SYM+F: type pattern 5 at position 0; I (insert); L (loop here); X (delete);
         N (new pattern here); E 3 2 ENTER (length 32); ENTER (back)
  SYM+G: CAPS+7 (speed +1); T, "HI", ENTER (title); ENTER (back)
then reads the slot back and checks: position list / loop / speed / title as
expected, num_pats grew by one, the new pattern is 32 rows and empty, every
ORIGINAL pattern still decodes identically, and all instrument bytes are
unchanged (the splices fixed every pointer).

Usage: v2_arrange_test.py <out_dir>
"""
import re, shutil, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import v2_ui_smoke as U
PORT = 10005; U.PORT = PORT
K = U.K
K.update({"sym_f": U.mask(r7=2, r1=0x08), "sym_g": U.mask(r7=2, r1=0x10), "i": U.mask(r5=0x04), "x": U.mask(r0=0x04),
          "l": U.mask(r6=0x02), "n": U.mask(r7=0x08), "e": U.mask(r2=0x04), "t": U.mask(r2=0x10), "h": U.mask(r6=0x10),
          "caps7": U.mask(r0=1, r4=0x08), "caps0": U.mask(r0=1, r4=0x01),
          "5": U.mask(r3=0x10), "2": U.mask(r3=0x02), "3": U.mask(r3=0x04)})


def syms():
    return {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M)}


def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    S = syms(); SLOT = S["SLOT_BASE"]
    orig = C.load_song(str(ROOT / "songs/3BIT - Kenotron - KENO50 (Paradox version).pt3"))
    orig_pats = [C.decode_pattern(orig, p) for p in range(orig.num_patterns())]
    tap = out / "demo.tap"; shutil.copy(ROOT / "build/v2/tracker2-demo.tap", tap)
    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1)
    proc = subprocess.Popen([U.ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT), "--noconfigfile"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    ok = True
    def rd(a, n):
        return bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", z.cmd(f"read-memory {a} {n}", limit=8)))
    def check(cond, what):
        nonlocal ok
        print(("  OK   " if cond else "  FAIL ") + what); ok &= bool(cond)
    def attr(row, col):
        return rd(0x5800 + row * 32 + col, 1)[0]
    def glyph(row, col):
        base = 0x4000 | ((row & 0x18) << 8) | ((row & 7) << 5) | col
        return bytes(rd(base + (y << 8), 1)[0] for y in range(8))
    def rom_glyph(ch):
        return rd(0x3C00 + ord(ch) * 8, 8)
    def shows(row, col, text):
        return all(glyph(row, col + i) == rom_glyph(ch) for i, ch in enumerate(text))
    try:
        for _ in range(40):
            try:
                s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
            except Exception: time.sleep(1)
        time.sleep(6)
        z = U.Z(); z.cmd("send-keys-ascii 200 13"); time.sleep(0.5); z.cmd("exit-cpu-step"); z.cmd("reset-cpu"); time.sleep(3)
        z.cmd(f"smartload {tap.resolve()}")
        t0 = time.time()
        while time.time() - t0 < 240:
            time.sleep(2); r = z.cmd("get-registers").lower()
            m = re.search(r"pc=([0-9a-f]{4})", r); pc = int(m.group(1), 16) if m else -1
            if 0x8000 <= pc < SLOT or (pc < 0x100 and "sp=fe" in r): break
        time.sleep(1.5)
        npos0 = rd(SLOT + 101, 1)[0]; npats0 = rd(S["num_pats"], 1)[0]
        print(f"booted: {npos0} positions, {npats0} patterns")
        # ---- arrangement editor
        z.press("sym_f", settle=1.0); z.shot(out / "01_arrange.png")
        # cursor moves repaint only the two cells and the info line (no cls): the
        # title stays, the old cell goes plain, the new one inverts, Pos follows
        check(attr(4, 1) == 0x78 and attr(4, 7) == 0x07 and shows(2, 4, "00"), "cursor on position 0")
        z.press("right", settle=0.4)
        check(attr(4, 1) == 0x07 and attr(4, 7) == 0x78 and shows(2, 4, "01") and shows(1, 0, "ARRANGEMENT"),
              "CAPS+8: cell 0 plain, cell 1 inverted, Pos 01, title untouched")
        z.press("down", settle=0.4)
        check(attr(4, 7) == 0x07 and attr(5, 7) == 0x78 and shows(2, 4, "06"), "CAPS+6: down a row to position 6")
        z.press("up", settle=0.4); z.press("left", settle=0.4)
        check(attr(4, 1) == 0x78 and attr(5, 7) == 0x07 and attr(4, 7) == 0x07 and shows(2, 4, "00"), "CAPS+7, CAPS+5: back on position 0")
        z.press("5", settle=0.6)                          # pattern 5 at position 0
        check(rd(SLOT + 201, 1)[0] == 15, "typed pattern 5 at position 0")
        z.press("i", settle=0.8)                          # insert (duplicate) before cursor
        check(rd(SLOT + 101, 1)[0] == npos0 + 1 and rd(SLOT + 201, 2) == bytes([15, 15]), "insert duplicated position 0")
        z.press("l", settle=0.6)                          # loop here (position 0)
        check(rd(SLOT + 102, 1)[0] == 0, "loop set to position 0")
        check(attr(4, 3) == 0x46 and shows(2, 29, "00"), "loop marker on cell 0's colon, Loop 00 on the info line")
        z.shot(out / "02_after_insert.png")
        z.press("x", settle=0.8)                          # delete position 0 again
        check(rd(SLOT + 101, 1)[0] == npos0 and rd(SLOT + 201, 1)[0] == 15, "delete restored the count")
        z.press("n", settle=1.0)                          # new pattern here
        npats1 = rd(S["num_pats"], 1)[0]
        check(npats1 == npats0 + 1 and rd(SLOT + 201, 1)[0] == (npats1 - 1) * 3, "new pattern created and placed at position 0")
        z.press("e", settle=0.8); z.shot(out / "03_length_prompt.png")
        # the prompt shows "64" with the cursor on the last cell: DEL, DEL, then type 32
        z.press("caps0", settle=0.3); z.press("caps0", settle=0.3)
        z.press("3", settle=0.3); z.press("2", settle=0.3); z.press("enter", settle=1.2)
        z.shot(out / "04_after_length.png")
        # page crossing: pretend the list has 120 positions, walk the cursor onto page 2
        # and back (the whole page is repainted only then), then restore the count
        npos_now = rd(SLOT + 101, 1)[0]
        z.cmd(f"write-memory-raw {SLOT + 101} 78")
        for _ in range(12): z.press("down", settle=0.25)
        check(rd(S["ar_top"], 1)[0] == 60 and rd(S["ar_cur"], 1)[0] == 60 and shows(4, 1, "60:") and attr(4, 1) == 0x78 and shows(2, 4, "60"),
              "12 x down: page 2 drawn, cursor on 60")
        z.shot(out / "04b_page2.png")
        for _ in range(12): z.press("up", settle=0.25)
        check(rd(S["ar_top"], 1)[0] == 0 and shows(4, 1, "00:") and attr(4, 1) == 0x78 and attr(5, 1) == 0x07, "12 x up: page 1 again, cursor on 0")
        z.cmd(f"write-memory-raw {SLOT + 101} {npos_now:02x}")
        z.press("enter", settle=1.5)                      # back to the editor at position 0 (the new pattern)
        z.shot(out / "05_editor_newpat.png")
        wl = rd(S["wp_len"], 1)[0]; wp_pat = rd(S["wp_pat"], 1)[0]
        check(wp_pat == npats1 - 1, f"editor on the new pattern ({wp_pat})")
        check(wl == 32, f"new pattern length is 32 (got {wl})")
        # ---- song info
        z.press("sym_g", settle=1.0); z.shot(out / "06_info.png")
        sp0 = rd(SLOT + 100, 1)[0]
        z.press("caps7", settle=0.5)
        check(rd(SLOT + 100, 1)[0] == sp0 + 1, "speed +1")
        z.press("t", settle=0.6); z.press("h", settle=0.3); z.press("i", settle=0.3); z.press("enter", settle=0.8)
        z.shot(out / "07_info_title.png")
        title = rd(SLOT + 30, 32)
        check(b"HI" in title, f"title edited (appended at the cursor): {title!r}")
        z.press("enter", settle=1.2); z.shot(out / "08_back.png")
        # ---- structural check of the whole slot
        slen = struct.unpack("<H", rd(S["song_len"], 2))[0]
        new = C.Song(rd(SLOT, slen))
        print(f"slot now {slen} B, {new.num_patterns()} patterns, {new.num_pos} positions")
        for p in range(orig.num_patterns()):
            if C.decode_pattern(new, p).key() != orig_pats[p].key():
                check(False, f"original pattern {p} changed"); break
        else:
            check(True, "all original patterns decode identically")
        newpat = C.decode_pattern(new, new.num_patterns() - 1)
        empty = all((c.note == C.NOTE_NONE or (c.note == C.NOTE_EMPTY and not c.has_fields())) for r in newpat.rows for c in r.cells)
        check(newpat.length == 32 and empty, "new pattern is empty and 32 rows")
        inst_ok = True
        for kind, po, pn, stride in (("smp", orig.sample_ptrs(), new.sample_ptrs(), 4), ("orn", orig.ornament_ptrs(), new.ornament_ptrs(), 1)):
            for a, b in zip(po, pn):
                if a and bytes(orig.data[a:a + 2 + orig.data[a + 1] * stride]) != bytes(new.data[b:b + 2 + new.data[b + 1] * stride]):
                    inst_ok = False
        check(inst_ok, "all sample and ornament blocks intact after splices")
        check(list(new.positions())[1:] == list(orig.positions())[1:], "positions 1.. unchanged")
    finally:
        if proc.poll() is None: proc.kill()
    print("ARRANGE TEST", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
