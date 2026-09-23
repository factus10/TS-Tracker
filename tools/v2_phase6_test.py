#!/usr/bin/env python3
"""Phase 6 UI test: one-level undo (SYM+U) and channel copy/paste (CAPS+SYM+C/V).

Boots build/v2/tracker2-demo.tap (Kenotron) and drives the pattern editor:
  undo:  type C on row 0 -> SYM+U restores the row -> SYM+U again redoes;
         SYM+T transposes channel A -> SYM+U restores every note;
         SYM+I inserts a row -> SYM+U restores the pattern;
         a fresh boot has nothing to undo (message, WP untouched)
  copy:  CAPS+SYM+C copies channel A of pattern P0; SYM+P moves to P1;
         CAPS+SYM+V pastes it onto channel B: B's cells equal P0's channel A,
         channels A and C of P1 are unchanged, rows with an envelope shape carry
         the period; SYM+U undoes the paste; plain SYM+V refuses (channel on
         the clipboard); SYM+C then SYM+V still pastes a whole pattern
Finally every untouched pattern decodes identically and all instrument blocks
are byte-identical.

Usage: v2_phase6_test.py <out_dir>
"""
import copy, re, shutil, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import v2_ui_smoke as U
PORT = 10011; U.PORT = PORT
K = U.K
K.update({"sym_u": U.mask(r7=2, r5=0x08), "sym_t": U.mask(r7=2, r2=0x10), "sym_c": U.mask(r7=2, r0=0x08),
          "sym_v": U.mask(r7=2, r0=0x10),
          # CAPS (row 0 bit 0) shares its half-row with C (bit 3) and V (bit 4)
          "caps_sym_c": U.mask(r0=0x09, r7=2), "caps_sym_v": U.mask(r0=0x11, r7=2)})


def syms():
    return {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M)}


def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    S = syms(); SLOT = S["SLOT_BASE"]; WP = S["WP_BASE"]
    orig = C.load_song(str(ROOT / "songs/3BIT - Kenotron - KENO50 (Paradox version).pt3"))
    orig_pats = [C.decode_pattern(orig, p) for p in range(orig.num_patterns())]
    positions = list(orig.positions()); P0, P1 = positions[0], positions[1]
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

    def b(name): return rd(S[name], 1)[0]
    def word(a): return struct.unpack("<H", rd(a, 2))[0]
    def wp(): return rd(WP, 64 * 24)
    def cells(buf, ch): return [bytes(buf[r * 24 + 3 + ch * 7: r * 24 + 10 + ch * 7]) for r in range(64)]
    def rowg(buf): return [bytes(buf[r * 24: r * 24 + 3]) for r in range(64)]

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
        print(f"booted: song {word(S['song_len'])} B, pattern {b('wp_pat')} (P0={P0}, P1={P1})")

        # ---- undo
        base = wp()
        z.press("sym_u", settle=0.8); z.press("enter", settle=0.6)
        check(b("undo_valid") == 0 and wp() == base, "fresh pattern: nothing to undo, WP untouched")
        z.press("z", hold=0.15, settle=1.0)
        after = wp()
        check(after != base and after[3] == 36, "C-4 entered on row 0")
        z.press("sym_u", settle=1.2)
        check(wp() == base, "SYM+U restored the pattern")
        z.press("sym_u", settle=1.2)
        check(wp() == after, "SYM+U again redid the edit")
        z.press("sym_u", settle=1.2)                       # back to the original for the rest
        check(wp() == base, "and back once more")
        z.press("sym_t", settle=1.0)
        tr = wp()
        check(tr != base, "SYM+T transposed channel A")
        z.press("sym_u", settle=1.2)
        check(wp() == base, "SYM+U restored all transposed notes")
        z.press("sym_i", settle=1.0)
        check(wp() != base, "SYM+I inserted a row")
        z.press("sym_u", settle=1.2)
        check(wp() == base, "SYM+U restored the pattern after the insert")
        z.shot(out / "01_after_undo.png")

        # ---- channel copy/paste: P0 channel A -> P1 channel B
        z.press("caps_sym_c", settle=0.8); z.press("enter", settle=0.6)
        check(b("copy_kind") == 1 and b("copy_chan") == 0 and b("copy_src") == P0, "CAPS+SYM+C copied channel A of the pattern")
        z.press("sym_p", settle=1.5)
        check(b("wp_pat") == P1, "moved to position 1")
        p1_before = wp()
        z.press("right", settle=0.3)                       # cursor into channel A field 1 ... move to channel B note field
        for _ in range(5): z.press("right", settle=0.25)   # field 5 of A -> then one more goes to B field 0
        check(b("cur_chan") == 1 and b("cur_field") == 0, "cursor on channel B")
        z.press("sym_v", settle=0.8); z.press("enter", settle=0.6)
        check(wp() == p1_before, "plain SYM+V refused: a channel is on the clipboard")
        z.press("caps_sym_v", settle=1.5)
        p1_after = wp()
        srcA = cells(base, 0); dstB = cells(p1_after, 1)
        check(dstB == srcA, "P1 channel B now equals P0 channel A")
        check(cells(p1_after, 0) == cells(p1_before, 0) and cells(p1_after, 2) == cells(p1_before, 2), "P1 channels A and C untouched")
        # envelope periods: where the pasted cell has a shape and P1's row had none, the period came along
        env_ok = True
        for r in range(64):
            shape = srcA[r][2] >> 4
            g_before, g_after, g_src = rowg(p1_before)[r], rowg(p1_after)[r], rowg(base)[r]
            if 1 <= shape <= 14 and g_before[0:2] == b"\0\0":
                env_ok &= g_after[0:2] == g_src[0:2]
            else:
                env_ok &= g_after[0:2] == g_before[0:2]
            env_ok &= g_after[2] == g_before[2]
        check(env_ok, "envelope periods carried only where needed, noise untouched")
        z.shot(out / "02_channel_pasted.png")
        z.press("sym_u", settle=1.2)
        check(wp() == p1_before, "SYM+U undid the channel paste")
        # whole-pattern clipboard still works
        z.press("sym_c", settle=0.8); z.press("enter", settle=0.6)
        check(b("copy_kind") == 0 and b("copy_src") == P1, "SYM+C copied the pattern")
        z.press("sym_o", settle=1.5)
        z.press("sym_v", settle=1.5)
        check(wp() == p1_before, "SYM+V pasted P1 over P0's editor")
        z.press("sym_u", settle=1.2)
        check(wp() == base, "SYM+U undid the pattern paste")
        z.press("sym_p", settle=1.5)                       # commits P0 (unchanged content) and moves on

        # ---- structural check
        slen = word(S["song_len"]); new = C.Song(rd(SLOT, slen))
        same = all(C.decode_pattern(new, p).key() == orig_pats[p].key() for p in range(orig.num_patterns()))
        check(same, "every pattern decodes as in the file")
        inst_ok = True
        for po, pn, stride in ((orig.sample_ptrs(), new.sample_ptrs(), 4), (orig.ornament_ptrs(), new.ornament_ptrs(), 1)):
            for a, bb in zip(po, pn):
                if a and bytes(orig.data[a:a + 2 + orig.data[a + 1] * stride]) != bytes(new.data[bb:bb + 2 + new.data[bb + 1] * stride]):
                    inst_ok = False
        check(inst_ok, "all instrument blocks intact")
    finally:
        if proc.poll() is None: proc.kill()
    print("PHASE6 TEST", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
