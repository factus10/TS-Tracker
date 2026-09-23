#!/usr/bin/env python3
"""Phase 4 UI test: edit step, note preview, command parameters, envelope period,
noise, transpose, copy/paste, follow-play with mutes, de-dup on save.

Boots build/v2/tracker2-demo.tap (Kenotron) and drives the pattern editor:
  SYM+K step 2, type C (note lands, preview returns, cursor moved 2), step back to 1
  command field: 1 + params 03 00 10, then 9 + param 5 (lone digit right-aligns),
                 SPACE clears, 9/05 again
  envelope: shape 8 on row 0 A, SYM+W period 01FE; row 1 (no shape) is refused
  noise: SYM+B 1F on row 1, blank -> none, lone 5 -> 05
  transpose: SYM+T / SYM+Y (+-1), CAPS+SYM+T / CAPS+SYM+Y (+-12) round trip
  copy/paste: SYM+C, SYM+P, SYM+V -> the next pattern equals the edited one
  play: SYM+A follows (row advances, position/WP follow), 1 mutes A, stop;
        SYM+L loops with row wrap
  save: SYM+S runs commit + de-dup, BREAK cancels; the two identical patterns
        now share their streams and the song shrank
Finally the edited pattern decodes to the Python model of the edits, the pasted
pattern decodes identically, every other pattern is unchanged and every
instrument block is byte-identical.

Usage: v2_phase4_test.py <out_dir>
"""
import copy, re, shutil, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import v2_ui_smoke as U
PORT = 10009; U.PORT = PORT
K = U.K
K.update({"sym_k": U.mask(r7=2, r6=0x04), "sym_w": U.mask(r7=2, r2=0x02), "sym_b": U.mask(r7=0x12),
          "sym_t": U.mask(r7=2, r2=0x10), "sym_y": U.mask(r7=2, r5=0x10),
          "caps_sym_t": U.mask(r0=1, r7=2, r2=0x10), "caps_sym_y": U.mask(r0=1, r7=2, r5=0x10),
          "sym_c": U.mask(r7=2, r0=0x08), "sym_v": U.mask(r7=2, r0=0x10), "sym_s": U.mask(r7=2, r1=0x02),
          "break": U.mask(r0=1, r7=1), "caps0": U.mask(r0=1, r4=0x01),
          "0": U.mask(r4=0x01), "1": U.mask(r3=0x01), "2": U.mask(r3=0x02), "5": U.mask(r3=0x10),
          "8": U.mask(r4=0x04), "9": U.mask(r4=0x02), "e": U.mask(r2=0x04), "a": U.mask(r1=0x01)})


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
    def cell(row, ch): return rd(WP + row * 24 + 3 + ch * 7, 7)
    def rowg(row): return rd(WP + row * 24, 3)
    def wp_notes(ch): return [cell(r, ch)[0] for r in range(b("wp_len"))]
    def hexprompt(text, width):
        for _ in range(width): z.press("caps0", settle=0.25)
        for ch in text: z.press(ch.lower() if ch.isalpha() else ch, settle=0.3)
        z.press("enter", settle=0.8)

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
        len0 = word(S["song_len"])
        print(f"booted: song {len0} B, pattern {b('wp_pat')} at position 0 (P0={P0}, P1={P1})")
        model = copy.deepcopy(orig_pats[P0])

        # ---- edit step + note entry with preview
        z.press("sym_k", settle=0.8); z.press("caps0", settle=0.3); z.press("caps0", settle=0.3)
        z.press("2", settle=0.3); z.press("enter", settle=0.8)
        check(b("edit_step") == 2, "edit step set to 2")
        z.press("z", hold=0.3, settle=1.0)                          # C of octave 4 = note 36, previewed while held
        c00 = cell(0, 0); model.rows[0].cells[0].note = 36
        check(c00[0] == 36 and b("cur_row") == 2, f"C-4 entered (note {c00[0]}), cursor advanced by the step (row {b('cur_row')})")
        z.press("sym_k", settle=0.8); z.press("caps0", settle=0.3); z.press("caps0", settle=0.3)
        z.press("1", settle=0.3); z.press("enter", settle=0.8)
        z.press("up", settle=0.3); z.press("up", settle=0.4)
        check(b("edit_step") == 1 and b("cur_row") == 0, "step back to 1, cursor on row 0")

        # ---- command field
        for _ in range(5): z.press("right", settle=0.25)          # field 5
        z.press("1", settle=0.8); z.shot(out / "01_params_prompt.png")
        hexprompt("030010", 6)
        c00 = cell(0, 0)
        check((c00[3] & 0x0F) == 1 and c00[4:7] == bytes([3, 0, 0x10]), f"command 1 with params 03 00 10 ({c00.hex()})")
        z.press("9", settle=0.8); hexprompt("5", 2)
        c00 = cell(0, 0)
        check((c00[3] & 0x0F) == 9 and c00[4] == 5, f"command 9, lone digit right-aligned to 05 ({c00.hex()})")
        z.shot(out / "02_cmd_detail.png")
        z.press("space", settle=0.5); c00 = cell(0, 0)
        check((c00[3] & 0x0F) == 0 and c00[4:7] == b"\0\0\0", "SPACE cleared command and params")
        z.press("9", settle=0.8); hexprompt("05", 2)
        model.rows[0].cells[0].cmd = 9; model.rows[0].cells[0].params = [5, 0, 0]

        # ---- envelope shape + period
        for _ in range(3): z.press("left", settle=0.25)           # field 2 = envelope
        z.press("8", settle=0.5)
        check((cell(0, 0)[2] >> 4) == 8, "envelope shape 8 on row 0 A")
        model.rows[0].cells[0].env = 8
        z.press("sym_w", settle=0.8); hexprompt("1FE", 4)
        check(rowg(0)[0:2] == bytes([0x01, 0xFE]), f"envelope period 01FE on row 0 ({rowg(0).hex()})")
        model.rows[0].envper = 0x01FE
        z.press("down", settle=0.4)
        z.press("sym_w", settle=0.8); z.shot(out / "03_noenv_msg.png"); z.press("enter", settle=0.6)
        check(rowg(1)[0:2] == b"\0\0", "row 1 without a shape refuses an envelope period")

        # ---- noise
        z.press("sym_b", settle=0.8); hexprompt("1F", 2)
        check(rowg(1)[2] == 0x1F, "noise 1F on row 1")
        z.press("sym_b", settle=0.8); z.press("caps0", settle=0.25); z.press("caps0", settle=0.25); z.press("enter", settle=0.8)
        check(rowg(1)[2] == 0xFF, "blank noise -> none")
        z.press("sym_b", settle=0.8); hexprompt("5", 2)
        check(rowg(1)[2] == 5, "lone digit -> noise 05")
        model.rows[1].noise = 5
        model.rows[1].cells[0].note = C.NOTE_EMPTY      # the noise rides on an empty event on A
        z.press("up", settle=0.4)

        # ---- transpose (channel A)
        before = wp_notes(0)
        z.press("sym_t", settle=0.8)
        exp = [n + 1 if n < 95 else n for n in before]
        check(wp_notes(0) == exp, "SYM+T: channel A up a semitone")
        z.press("sym_y", settle=0.8)
        check(wp_notes(0) == before, "SYM+Y: back down")
        z.press("caps_sym_t", settle=0.8)
        exp = [n + 12 if n < 84 else n for n in before]
        check(wp_notes(0) == exp, "CAPS+SYM+T: up an octave")
        z.press("caps_sym_y", settle=0.8)
        check(wp_notes(0) == before, "CAPS+SYM+Y: back down")

        # ---- copy / paste onto the next position's pattern
        z.press("sym_c", settle=0.8); z.press("enter", settle=0.6)
        check(b("copy_src") == P0, "SYM+C remembered the pattern")
        z.press("sym_p", settle=1.2)
        check(b("wp_pat") == P1 and b("cur_pos") == 1, "SYM+P committed and moved to position 1")
        z.press("sym_v", settle=1.2)
        c00 = cell(0, 0)
        check(b("wp_len") == model.length and c00[0] == 36 and (c00[3] & 0x0F) == 9, "SYM+V pasted the edited pattern")
        z.shot(out / "04_pasted.png")
        # probe: the WP must equal the Python decode of the committed source pattern
        slot_now = C.Song(rd(SLOT, word(S["song_len"]))); p0_now = C.decode_pattern(slot_now, P0)
        wp_now = [cell(r, 0)[0] for r in range(p0_now.length)]
        py_now = [p0_now.rows[r].cells[0].note for r in range(p0_now.length)]
        check(wp_now == py_now, "probe: WP channel A after paste == Python decode of the committed pattern")
        if wp_now != py_now: print("    wp", wp_now, "\n    py", py_now)

        # ---- follow-play with mutes
        z.press("sym_a", settle=2.5); z.shot(out / "05_playing.png")
        r1 = b("play_row"); z.cmd(f"set-ui-io-ports {K['1']}"); time.sleep(0.1); z.cmd(f"set-ui-io-ports {U.REL}"); time.sleep(0.8)
        r2 = b("play_row")
        check(r2 != r1 and b("cur_row") == b("play_shownrow"), f"follow: row advances ({r1} -> {r2}) and the grid tracks it")
        check(b("play_mute") == 1, "1 muted channel A without stopping")
        z.shot(out / "06_muted.png")
        z.cmd(f"set-ui-io-ports {K['1']}"); time.sleep(0.1); z.cmd(f"set-ui-io-ports {U.REL}"); time.sleep(0.5)
        check(b("play_mute") == 0, "1 again unmuted")
        z.press("space", settle=1.2)
        check(b("cur_row") > 0, f"stopped: the cursor stayed where playback was (row {b('cur_row')}, pos {b('cur_pos')})")
        slot_now = C.Song(rd(SLOT, word(S["song_len"])))
        a0 = C.decode_pattern(slot_now, P0); a1 = C.decode_pattern(slot_now, P1)
        n0 = [a0.rows[r].cells[0].note for r in range(a0.length)]; n1 = [a1.rows[r].cells[0].note for r in range(a1.length)]
        check(n0 == n1, "probe: after play, committed patterns P0 and P1 have the same channel-A notes")
        if n0 != n1: print("    P0", n0, "\n    P1", n1, "\n    WP", [cell(r, 0)[0] for r in range(b("wp_len"))])
        z.press("sym_l", settle=2.5); r1 = b("play_row"); time.sleep(0.8); r2 = b("play_row")
        check(r1 != r2 and b("play_loopmode") == 1, f"loop pattern: rows advance ({r1} -> {r2})")
        z.press("space", settle=1.2); z.shot(out / "07_after_play.png")

        # ---- de-dup on save (commit + dedup run before the name prompt; BREAK cancels)
        z.press("sym_o", settle=1.2)                             # back to position 0 (commits the paste)
        slen1 = word(S["song_len"]); pre = C.Song(rd(SLOT, slen1))
        (out / "pre_save.pt3").write_bytes(bytes(pre.data))
        pre_pats = [C.decode_pattern(pre, p) for p in range(pre.num_patterns())]
        def streams(song, pat):
            t = song.pat_table
            return [struct.unpack_from("<H", song.data, t + pat * 6 + 2 * ch)[0] for ch in range(3)]
        for pat in (P0, P1):
            offs = streams(pre, pat)
            print(f"    pattern {pat} streams at {offs}: " + " | ".join(bytes(pre.data[o:o + 12]).hex() for o in offs))
        def diff_rows(a, bm, what):
            for r, (ra, rb) in enumerate(zip(a.rows, bm.rows)):
                if ra.key() != rb.key():
                    print(f"    {what}: first difference at row {r}:\n      got   {C.dump(a)[r] if False else ra.key()}\n      model {rb.key()}")
                    return
            if a.length != bm.length: print(f"    {what}: length {a.length} vs {bm.length}")
        diff_rows(pre_pats[P0], model, f"pattern {P0} before save")
        diff_rows(pre_pats[P1], model, f"pattern {P1} before save")
        z.press("sym_s", settle=2.5); z.shot(out / "08_save_prompt.png"); z.press("break", settle=1.2)
        slen2 = word(S["song_len"]); new = C.Song(rd(SLOT, slen2))
        tbl = new.pat_table
        e0 = new.data[tbl + P0 * 6: tbl + P0 * 6 + 6]; e1 = new.data[tbl + P1 * 6: tbl + P1 * 6 + 6]
        (out / "post_save.pt3").write_bytes(bytes(new.data))
        check(bytes(e0) == bytes(e1) and slen2 < slen1, f"de-dup: patterns {P0} and {P1} share streams, song {slen1} -> {slen2} B (entries {bytes(e0).hex()} / {bytes(e1).hex()})")
        same = all(C.decode_pattern(new, p).key() == pre_pats[p].key() for p in range(new.num_patterns()))
        check(same, "every pattern decodes identically after de-dup")

        # ---- structural check against the model of the edits
        for p in range(orig.num_patterns()):
            dec = C.decode_pattern(new, p)
            if p == P0 or p == P1:
                if dec.key() != model.key():
                    check(False, f"pattern {p} differs from the edit model"); break
            elif dec.key() != orig_pats[p].key():
                check(False, f"untouched pattern {p} changed"); break
        else:
            check(True, f"patterns {P0}/{P1} match the edit model, all others unchanged")
        inst_ok = True
        for po, pn, stride in ((orig.sample_ptrs(), new.sample_ptrs(), 4), (orig.ornament_ptrs(), new.ornament_ptrs(), 1)):
            for a, bb in zip(po, pn):
                if a and bytes(orig.data[a:a + 2 + orig.data[a + 1] * stride]) != bytes(new.data[bb:bb + 2 + new.data[bb + 1] * stride]):
                    inst_ok = False
        check(inst_ok, "all instrument blocks intact")
    finally:
        if proc.poll() is None: proc.kill()
    print("PHASE4 TEST", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
