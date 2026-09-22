#!/usr/bin/env python3
"""TS Tracker v2 codec parity test: Z80 (in ZEsarUX) vs tools/pt3codec.py.

For every song: load the v2 binary into RAM, put the song in the slot, then
for every pattern call the Z80 decoder and encoder through ZRCP and compare
the working-pattern buffer and the canonical streams byte-for-byte with the
Python reference. Finally exercise commit_pattern (splice into the slot) and
check the rest of the song survived untouched.

Usage: v2_codec_test.py [--songs a.pt3 b.tap:NAME ...] [--keep] [--quick]
Needs: build/v2/tracker2.bin + .sym (make tracker2), ZEsarUX in /Applications.
"""
import os, re, socket, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C

ZESARUX = "/Applications/zesarux.app/Contents/MacOS/zesarux"
PORT = 10001            # our own ZRCP port: never touches an emulator the user launched
CODE_BASE, SLOT_BASE, WP_BASE, STAGE_BASE = 0x8000, 0xAB00, 0x6A00, 0x7000
TRAP, SP_TOP = 0x5B00, 0xFEFE
DEFAULT_SONGS = [
    "songs/3BIT - Debugger - SPRLZ4Ev2004.pt3",
    "songs/3BIT - Kenotron - KENO50 (Paradox version).pt3",
    "songs/newsongs.tap:KRISTINA",
    "songs/newsongs.tap:NOPOWER",
    "songs/newsongs.tap:POPCORN",
]


class ZRCP:
    """Line-oriented ZRCP client. Every reply ends with a prompt ("command> " or
    "command@cpu-step> "), so read until the prompt instead of waiting for a
    socket timeout -- that makes a command cost ~10 ms instead of 2 s."""
    PROMPT = re.compile(rb"command(@[\w-]+)?>\s*$")

    def __init__(self):
        self.s = socket.socket(); self.s.connect(("localhost", PORT))
        self.s.settimeout(0.05)
        self._read_reply(3.0)                     # banner + first prompt

    def _read_reply(self, limit):
        data = b""; t0 = time.time()
        while time.time() - t0 < limit:
            try:
                chunk = self.s.recv(65536)
                if chunk: data += chunk
            except socket.timeout:
                pass
            if self.PROMPT.search(data):
                break
        return data

    def cmd(self, c, wait=0.0, limit=5.0):
        try:
            self.s.sendall((c + "\n").encode())
            data = self._read_reply(limit)
        except (ConnectionResetError, BrokenPipeError):
            self.s = socket.socket(); self.s.connect(("localhost", PORT)); self.s.settimeout(0.05)
            self._read_reply(3.0)
            self.s.sendall((c + "\n").encode())
            data = self._read_reply(limit)
        if wait: time.sleep(wait)
        text = self.PROMPT.sub(b"", data).decode(errors="replace")
        return text.strip()

    def read(self, addr, n):
        out = bytearray()
        while n:
            k = min(n, 2048)
            h = self.cmd(f"read-memory {addr} {k}")
            h = re.sub(r"[^0-9A-Fa-f]", "", h)
            b = bytes.fromhex(h[:k * 2])
            if len(b) != k: raise RuntimeError(f"short read at {addr:04X}: {len(b)}/{k}")
            out += b; addr += k; n -= k
        return bytes(out)

    def write(self, addr, data):
        for i in range(0, len(data), 256):
            chunk = data[i:i + 256]
            self.cmd(f"write-memory-raw {addr + i} {chunk.hex()}")

    def pc(self):
        r = self.cmd("get-registers")
        m = re.search(r"PC=([0-9a-fA-F]{4})", r)
        return int(m.group(1), 16) if m else -1

    def call(self, addr, timeout=4.0):
        """Run the routine at addr with SP=SP_TOP and a trap return address."""
        self.cmd("enter-cpu-step")
        self.write(TRAP, bytes([0x18, 0xFE]))                    # JR -2
        self.write(SP_TOP, bytes([TRAP & 0xFF, TRAP >> 8]))      # return address
        self.cmd(f"set-register SP={SP_TOP:04X}h")
        self.cmd(f"set-register PC={addr:04X}h")
        self.cmd("exit-cpu-step")
        t0 = time.time()
        while time.time() - t0 < timeout:
            time.sleep(0.05)
            self.cmd("enter-cpu-step")
            pc = self.pc()
            if pc == TRAP:
                return True
            self.cmd("exit-cpu-step")                            # still running (or in the ROM ISR)
        raise RuntimeError(f"routine at {addr:04X} did not return (PC={self.pc():04X})")


def load_syms(path):
    syms = {}
    for m in re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", pathlib.Path(path).read_text(), re.M):
        syms[m.group(1)] = int(m.group(2), 16)
    return syms


def launch():
    """Start a private ZEsarUX on PORT and hard-reset it into ROM BASIC.
    (ZEsarUX may restore an autosave snapshot at start -- e.g. a Pro/File 2068
    session -- so never assume the machine is in BASIC until after a reset.)"""
    # a stale instance from an interrupted run may still own our private port:
    # kill only processes launched with OUR port flag (never the user's own emulator)
    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1.5)
    proc = subprocess.Popen([ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol",
                             "--remoteprotocol-port", str(PORT), "--noconfigfile"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        try:
            s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
        except Exception: time.sleep(1)
    time.sleep(6)
    z = ZRCP()
    z.cmd("send-keys-ascii 200 13", 0.6)      # dismiss the first-aid tip
    z.cmd("exit-cpu-step")                    # harmless if not in step mode
    # ZEsarUX restores its autosave snapshot at launch; reset-cpu (not hard-reset-cpu,
    # which is ignored in that state) runs the ROM's NEW and lands in BASIC.
    z.cmd("reset-cpu", 0.5)
    for _ in range(40):                        # wait for the ROM's NEW: IY=$5C3A and the BASIC stack at $61xx
        time.sleep(0.5)
        r = z.cmd("get-registers").lower()
        if "iy=5c3a" in r and "sp=61" in r:
            break
    else:
        raise RuntimeError("machine did not reach BASIC after reset: " + r[:120])
    time.sleep(1)
    return proc, z


def measure_py(song):
    """Mirror slot_measure: end of the furthest referenced block."""
    d = song.data
    end = 201 + song.num_pos + 1
    for p in range(song.num_patterns()):
        for ch in range(3):
            o = song.stream_offset(p, ch)
            end = max(end, C.stream_end(d, o))
    for ptr in song.sample_ptrs():
        if ptr: end = max(end, ptr + 2 + d[ptr + 1] * 4)
    for ptr in song.ornament_ptrs():
        if ptr: end = max(end, ptr + 2 + d[ptr + 1])
    return end


def w16(z, addr): b = z.read(addr, 2); return b[0] | (b[1] << 8)


def main():
    args = sys.argv[1:]
    keep = "--keep" in args; quick = "--quick" in args
    songs = DEFAULT_SONGS
    if "--songs" in args:
        songs = args[args.index("--songs") + 1:]
        songs = [s for s in songs if not s.startswith("--")]
    binp = ROOT / "build/v2/tracker2.bin"; symp = ROOT / "build/v2/tracker2.sym"
    code = binp.read_bytes(); S = load_syms(symp)
    need = ["t_init", "t_decode", "t_encode", "t_load", "t_commit", "t_arg", "wp_len", "dec_warn",
            "num_pats", "song_len", "enc_off", "enc_len", "enc_total", "enc_err", "wp_old_bytes", "wp_pat"]
    missing = [n for n in need if n not in S]
    if missing: sys.exit(f"symbols missing from .sym: {missing}")

    proc, z = launch()
    fails = 0
    try:
        print(f"loading {len(code)} B of code at ${CODE_BASE:04X} ...")
        z.write(CODE_BASE, code)
        for spec in songs:
            song = C.load_song(str(ROOT / spec) if not spec.startswith("/") else spec)
            data = bytes(song.data)
            print(f"\n=== {spec}  ({len(data)} B, {song.num_patterns()} patterns)")
            z.write(SLOT_BASE, data)
            # pad a little past the end so stream_end guards see clean memory
            z.write(SLOT_BASE + len(data), bytes(64))
            z.call(S["t_init"])
            npats = z.read(S["num_pats"], 1)[0]; slen = w16(z, S["song_len"])
            exp_len = measure_py(song)
            ok = npats == song.num_patterns() and slen == exp_len
            print(f"  init: num_pats {npats} (py {song.num_patterns()})  song_len {slen} (py {exp_len}, file {len(data)})  {'OK' if ok else 'FAIL'}")
            fails += not ok
            pats = range(song.num_patterns()) if not quick else range(min(3, song.num_patterns()))
            for p in pats:
                ref = C.decode_pattern(song, p)
                z.write(S["t_arg"], bytes([p]))
                z.call(S["t_decode"])
                wp = z.read(WP_BASE, C.ROWS * C.ROW_SIZE)
                wl = z.read(S["wp_len"], 1)[0]; warn = z.read(S["dec_warn"], 1)[0]
                dec_ok = (wp == ref.to_bytes()) and (wl == ref.length)
                # encoder
                z.call(S["t_encode"])
                err = z.read(S["enc_err"], 1)[0]
                lens = [w16(z, S["enc_len"] + 2 * i) for i in range(3)]
                total = w16(z, S["enc_total"])
                ref_streams = C.encode_pattern(ref)
                st = z.read(STAGE_BASE, total) if total else b""
                enc_ok = (err == 0) and (lens == [len(s) for s in ref_streams]) and (st == b"".join(ref_streams))
                flag = "OK " if (dec_ok and enc_ok) else "FAIL"
                fails += not (dec_ok and enc_ok)
                extra = ""
                if not dec_ok:
                    diff = next((i for i in range(len(wp)) if i >= len(ref.to_bytes()) or wp[i] != ref.to_bytes()[i]), None)
                    extra += f" dec: len {wl}/{ref.length}" + (f" first diff @{diff} (row {diff // 24}, +{diff % 24}) z80={wp[diff]:02X} py={ref.to_bytes()[diff]:02X}" if diff is not None else "")
                if not enc_ok:
                    refj = b"".join(ref_streams)
                    diff = next((i for i in range(min(len(st), len(refj))) if st[i] != refj[i]), None)
                    extra += f" enc: err {err} lens {lens}/{[len(s) for s in ref_streams]}" + (f" first diff @{diff} z80={st[diff]:02X} py={refj[diff]:02X}" if diff is not None else "")
                if warn: extra += f" warn={warn:02X}"
                print(f"  pat {p:2d}: {flag} len {wl:2d} enc {total:4d} B{extra}")
            # ---- commit test on pattern 1 (or 0): change one cell, splice, verify
            p = 1 if song.num_patterns() > 1 else 0
            z.write(S["t_arg"], bytes([p])); z.call(S["t_load"])
            ref = C.decode_pattern(song, p)
            row, ch = min(5, ref.length - 1), 1
            cell = ref.rows[row].cells[ch]
            cell.note, cell.sample, cell.vol = 36, 1, 15         # C-4, sample 1, vol F
            cell_addr = WP_BASE + row * C.ROW_SIZE + 3 + ch * C.CELL_SIZE
            z.write(cell_addr, cell.to_bytes())
            z.call(S["t_commit"])
            slen2 = w16(z, S["song_len"])
            new = C.Song(z.read(SLOT_BASE, slen2))
            c_ok = True; why = []
            for q in range(song.num_patterns()):
                got = C.decode_pattern(new, q)
                exp = ref if q == p else C.decode_pattern(song, q)
                if got.key() != exp.key():
                    c_ok = False; why.append(f"pattern {q} differs")
            # instruments must be byte-identical by content
            for kind, ptrs_o, ptrs_n, stride in (("smp", song.sample_ptrs(), new.sample_ptrs(), 4), ("orn", song.ornament_ptrs(), new.ornament_ptrs(), 1)):
                for i, (a, b) in enumerate(zip(ptrs_o, ptrs_n)):
                    if not a: continue
                    la = 2 + song.data[a + 1] * stride
                    if bytes(song.data[a:a + la]) != bytes(new.data[b:b + la]):
                        c_ok = False; why.append(f"{kind}{i} changed")
            if bytes(song.data[:103]) != bytes(new.data[:103]) or bytes(song.data[105:201 + song.num_pos + 1]) != bytes(new.data[105:201 + song.num_pos + 1]):
                pass  # sample/orn pointer tables legitimately move; header text must match
            if bytes(song.data[:100]) != bytes(new.data[:100]):
                c_ok = False; why.append("header text changed")
            fails += not c_ok
            print(f"  commit pat {p} row {row} chB=C-4: {'OK ' if c_ok else 'FAIL'} song_len {slen} -> {slen2}" + (("  " + "; ".join(why)) if why else ""))
    finally:
        # SIGKILL, never exit-emulator/SIGTERM: a clean exit makes ZEsarUX overwrite
        # its autosave snapshot (zesarux_autosave.zsf) with our test state
        if not keep and proc.poll() is None: proc.kill()
    print("\nRESULT:", "PASS" if fails == 0 else f"FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
