#!/usr/bin/env python3
"""Phase 3 UI test: sample editor (SYM+E) and ornament editor (SYM+R).

Boots build/v2/tracker2-demo.tap (Kenotron) and drives the editors through
every operation, checking the slot after each step against a Python model of
the expected block:
  sample 1: toggle T, type/negate/zero a tone offset, type/negate an Ns offset,
            type a volume, cycle the amplitude slide, insert + delete a line,
            length 14 / 8 / 2 via the prompt, repeat line via the prompt
  sample 11 (no data): SPACE creates a one-line block at the end of the song
  ENTER preview (held) must return to the editor
  ornament 1: type/negate/zero values, insert/delete, length, repeat
  new song: editing shared sample 1 forks it to a private block
Finally every original pattern must still decode identically and every other
instrument block must be byte-identical (all the splices fixed every pointer).

Usage: v2_instr_test.py <out_dir>
"""
import re, shutil, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import v2_ui_smoke as U
PORT = 10008; U.PORT = PORT
K = U.K
K.update({"sym_e": U.mask(r7=2, r2=0x04), "sym_r": U.mask(r7=2, r2=0x08), "sym_n": U.mask(r7=0x0A),
          "i": U.mask(r5=0x04), "x": U.mask(r0=0x04), "l": U.mask(r6=0x02), "r": U.mask(r2=0x08),
          "o": U.mask(r5=0x02), "p": U.mask(r5=0x01), "q": U.mask(r2=0x01), "y": U.mask(r5=0x10), "a": U.mask(r1=0x01),
          "caps0": U.mask(r0=1, r4=0x01),
          "0": U.mask(r4=0x01), "1": U.mask(r3=0x01), "2": U.mask(r3=0x02), "4": U.mask(r3=0x08),
          "5": U.mask(r3=0x10), "7": U.mask(r4=0x08), "8": U.mask(r4=0x04)})


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

    def word(a): return struct.unpack("<H", rd(a, 2))[0]
    def smp_ptr(n): return word(SLOT + 105 + 2 * n)
    def orn_ptr(n): return word(SLOT + 169 + 2 * n)
    def smp_block(n):
        p = smp_ptr(n); ln = rd(SLOT + p + 1, 1)[0]; return rd(SLOT + p, 2 + 4 * ln)
    def orn_block(n):
        p = orn_ptr(n); ln = rd(SLOT + p + 1, 1)[0]; return rd(SLOT + p, 2 + ln)
    def song_len(): return word(S["song_len"])
    def prompt(keys):
        """the 2-digit prompt shows the current value with the cursor on the last cell"""
        z.press("caps0", settle=0.3); z.press("caps0", settle=0.3)
        for k in keys: z.press(k, settle=0.3)
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
        len0 = song_len()
        print(f"booted: song {len0} B, {rd(S['num_pats'], 1)[0]} patterns")

        # ---- sample editor on sample 1 (loop 2, 12 lines; line 0 = 01 8F 00 00)
        smp1 = bytearray(orig.data[orig.sample_ptrs()[1]:][:2 + 4 * 12])
        check(bytes(smp_block(1)) == bytes(smp1), "sample 1 as in the file")
        z.press("sym_e", settle=1.0); z.shot(out / "01_sample.png")
        check(rd(S["se_kind"], 1)[0] == 0 and rd(S["se_sel"], 1)[0] == 1, "sample editor opened on sample 1")
        z.press("space", settle=0.5); smp1[3] ^= 0x10
        check(bytes(smp_block(1)) == bytes(smp1), "SPACE on T: tone off (b1 |= $10)")
        z.press("space", settle=0.5); smp1[3] ^= 0x10
        check(bytes(smp_block(1)) == bytes(smp1), "SPACE again: tone on")
        for _ in range(3): z.press("right", settle=0.3)          # field 3 = tone
        z.press("1", settle=0.3); z.press("2", settle=0.4); smp1[4:6] = struct.pack("<h", 12)
        check(bytes(smp_block(1)) == bytes(smp1), "typed tone offset 12")
        z.press("space", settle=0.4); smp1[4:6] = struct.pack("<h", -12)
        check(bytes(smp_block(1)) == bytes(smp1), "SPACE negates the tone offset (-12)")
        z.press("5", settle=0.4); smp1[4:6] = struct.pack("<h", -125)
        check(bytes(smp_block(1)) == bytes(smp1), "digits roll in from the right (-125)")
        z.press("caps0", settle=0.4); smp1[4:6] = b"\0\0"
        check(bytes(smp_block(1)) == bytes(smp1), "CAPS+0 zeroes the tone offset")
        z.shot(out / "02_tone.png")
        for _ in range(2): z.press("right", settle=0.3)          # field 5 = Ns
        z.press("3", settle=0.4); smp1[2] = (smp1[2] & 0xC1) | (3 << 1)
        check(bytes(smp_block(1)) == bytes(smp1), "typed Ns offset +3")
        z.press("space", settle=0.4); smp1[2] = (smp1[2] & 0xC1) | (((-3) & 0x1F) << 1)
        check(bytes(smp_block(1)) == bytes(smp1), "SPACE negates the Ns offset (-3 = 29)")
        for _ in range(2): z.press("right", settle=0.3)          # field 7 = volume
        z.press("a", settle=0.4); smp1[3] = (smp1[3] & 0xF0) | 0x0A
        check(bytes(smp_block(1)) == bytes(smp1), "typed volume A")
        z.press("right", settle=0.3)                             # field 8 = amplitude slide
        z.press("space", settle=0.4); smp1[2] |= 0xC0
        check(bytes(smp_block(1)) == bytes(smp1), "amp slide: up")
        z.press("space", settle=0.4); smp1[2] &= 0xBF
        check(bytes(smp_block(1)) == bytes(smp1), "amp slide: down")
        z.press("space", settle=0.4); smp1[2] &= 0x3F
        check(bytes(smp_block(1)) == bytes(smp1), "amp slide: off")
        z.shot(out / "03_fields.png")
        # insert / delete a line at line 1 (the loop marker on line 2 follows its line)
        z.press("down", settle=0.4); z.press("i", settle=0.6)
        exp = bytearray(smp1); exp[1] = 13; exp[0] = 3; exp[6:6] = b"\0\0\0\0"
        check(bytes(smp_block(1)) == bytes(exp) and song_len() == len0 + 4, "I inserted an empty line 1, loop 2 -> 3")
        z.press("x", settle=0.6)
        check(bytes(smp_block(1)) == bytes(smp1) and song_len() == len0, "X deleted it again, loop back to 2")
        # length via the prompt
        z.press("l", settle=0.6); z.shot(out / "04_len_prompt.png"); prompt(["1", "4"])
        exp = bytearray(smp1); exp[1] = 14; exp += b"\0" * 8
        check(bytes(smp_block(1)) == bytes(exp) and song_len() == len0 + 8, "length 14: two zero lines appended")
        z.press("l", settle=0.6); prompt(["8"])                 # a lone digit right-aligns
        exp = bytearray(smp1[:2 + 4 * 8]); exp[1] = 8
        check(bytes(smp_block(1)) == bytes(exp) and song_len() == len0 - 16, "length 8: lines dropped, loop 2 kept")
        z.press("l", settle=0.6); prompt(["2"])
        exp = bytearray(smp1[:2 + 4 * 2]); exp[1] = 2; exp[0] = 1
        check(bytes(smp_block(1)) == bytes(exp), "length 2: loop clamped to 1")
        z.press("r", settle=0.6); prompt(["0", "0"])
        exp[0] = 0
        check(bytes(smp_block(1)) == bytes(exp), "repeat line 0 via the prompt")
        smp1_final = bytes(exp)
        z.shot(out / "05_short.png")
        # browse: P to sample 2, O back, then to sample 11 (no data)
        z.press("p", settle=0.5)
        check(rd(S["se_sel"], 1)[0] == 2, "P -> sample 2")
        z.shot(out / "06_sample2.png")
        z.press("o", settle=0.5)
        for _ in range(10): z.press("p", settle=0.25)
        check(rd(S["se_sel"], 1)[0] == 11 and smp_ptr(11) == 0, "sample 11 has no data")
        z.shot(out / "07_empty.png")
        len1 = song_len()
        z.press("space", settle=0.6)
        p11 = smp_ptr(11)
        check(p11 == len1 and song_len() == len1 + 6 and bytes(smp_block(11)) == bytes([0, 1, 0, 0x10, 0, 0]),
              "SPACE created a one-line block at the end of the song and toggled T")
        smp11_final = bytes([0, 1, 0, 0x10, 0, 0])
        # preview: hold ENTER -> PTxPlay must drive the AY (line 0 has the envelope on, so
        # channel A's amplitude register carries the envelope flag); release -> silence, editor back
        z.cmd(f"set-ui-io-ports {K['enter']}"); time.sleep(0.6)
        regs = rd(S["AYREGS"], 14)
        z.cmd(f"set-ui-io-ports {U.REL}"); time.sleep(0.8)
        check(regs[8] != 0, f"preview plays through PTxPlay (AY amp A = {regs[8]:02X}, mixer = {regs[7]:02X})")
        z.press("p", settle=0.5)
        check(rd(S["se_sel"], 1)[0] == 12, "preview note returned to the editor (P still works)")
        z.press("o", settle=0.4)
        z.press("q", settle=1.0); z.shot(out / "08_back.png")
        check(rd(S["cur_sample"], 1)[0] == 11, "Q: the edited sample became the current one")

        # ---- ornament editor on ornament 1 ([0, 5, 9], loop 0)
        orn1 = bytearray(orig.data[orig.ornament_ptrs()[1]:][:2 + 3])
        z.press("sym_r", settle=1.0); z.shot(out / "09_ornament.png")
        check(rd(S["se_kind"], 1)[0] == 1 and rd(S["se_sel"], 1)[0] == 1, "ornament editor opened on ornament 1")
        len2 = song_len()
        z.press("7", settle=0.4); orn1[2] = 7
        check(bytes(orn_block(1)) == bytes(orn1), "typed 7 on line 0")
        z.press("space", settle=0.4); orn1[2] = (-7) & 0xFF
        check(bytes(orn_block(1)) == bytes(orn1), "SPACE negated it (-7)")
        z.press("down", settle=0.3); z.press("2", settle=0.4); orn1[3] = 52
        check(bytes(orn_block(1)) == bytes(orn1), "line 1: 5 -> 52 (rolling digits)")
        z.press("caps0", settle=0.4); orn1[3] = 0
        check(bytes(orn_block(1)) == bytes(orn1), "CAPS+0 zeroed line 1")
        z.press("i", settle=0.6)
        exp = bytearray(orn1); exp[1] = 4; exp[3:3] = b"\0"
        check(bytes(orn_block(1)) == bytes(exp) and song_len() == len2 + 1, "I inserted a line (loop 0 stays)")
        z.press("x", settle=0.6)
        check(bytes(orn_block(1)) == bytes(orn1) and song_len() == len2, "X removed it")
        z.press("l", settle=0.6); prompt(["5"])
        exp = bytearray(orn1); exp[1] = 5; exp += b"\0\0"
        check(bytes(orn_block(1)) == bytes(exp), "ornament length 5")
        z.press("r", settle=0.6); prompt(["4"])
        exp[0] = 4
        check(bytes(orn_block(1)) == bytes(exp), "ornament repeat line 4")
        orn1_final = bytes(exp)
        z.shot(out / "10_ornament_edited.png")
        z.press("q", settle=1.0)

        # ---- structural check of the whole slot
        slen = song_len(); new = C.Song(rd(SLOT, slen))
        print(f"slot now {slen} B (was {len0}), {new.num_patterns()} patterns")
        for p in range(orig.num_patterns()):
            if C.decode_pattern(new, p).key() != orig_pats[p].key():
                check(False, f"original pattern {p} changed"); break
        else:
            check(True, "all original patterns decode identically")
        check(list(new.positions()) == list(orig.positions()), "position list unchanged")
        inst_ok = True
        for kind, po, pn, stride, edited in (("smp", orig.sample_ptrs(), new.sample_ptrs(), 4, (1, 11)),
                                             ("orn", orig.ornament_ptrs(), new.ornament_ptrs(), 1, (1,))):
            for i, (a, b) in enumerate(zip(po, pn)):
                if i in edited or not a: continue
                if bytes(orig.data[a:a + 2 + orig.data[a + 1] * stride]) != bytes(new.data[b:b + 2 + new.data[b + 1] * stride]):
                    inst_ok = False; print(f"    {kind} {i} differs")
        check(inst_ok, "every other sample and ornament block is byte-identical")
        check(bytes(smp_block(1)) == smp1_final and bytes(smp_block(11)) == smp11_final and bytes(orn_block(1)) == orn1_final,
              "edited blocks hold their final state")

        # ---- new song: shared blocks fork on edit
        z.press("sym_n", settle=0.8); z.press("y", settle=1.5)
        check(smp_ptr(1) == smp_ptr(2) == smp_ptr(31) and orn_ptr(0) == orn_ptr(15), "new song: all instruments share one block")
        lenn = song_len(); shared = smp_ptr(1)
        z.press("sym_e", settle=1.0)
        check(rd(S["se_sel"], 1)[0] == 1, "a new song resets the editor to sample 1")
        z.press("space", settle=0.6)
        check(smp_ptr(1) == lenn and smp_ptr(2) == shared and song_len() == lenn + 6, "editing sample 1 forked it to a private copy")
        check(bytes(smp_block(1)) == bytes([0, 1, 0, 0x9F, 0, 0]) and bytes(smp_block(2)) == bytes([0, 1, 0, 0x8F, 0, 0]),
              "the copy changed, the shared original did not")
        z.shot(out / "11_forked.png")
        z.press("q", settle=1.0)
    finally:
        if proc.poll() is None: proc.kill()
    print("INSTR TEST", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
