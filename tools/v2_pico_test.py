#!/usr/bin/env python3
"""TS-PICO support test: TPI command frames, the SD-card flow and the scrolling
directory, in ZEsarUX with the stock ROM.

There is no TS-PICO in the emulator, so the tracker's three BIOS calls (tpi_tx,
tpi_rx, tpi_wait -> EXROM TX_A / RX_A / WF_NPH) are redirected to stubs in RAM
that log every byte sent and feed a scripted reply. What is checked:
  A. tpi_save / tpi_load send exactly the frames the TPI EXROM sends for
     SAVE "TPI:..." / LOAD "TPI:..." (EXROM $1B8D: "B" block, status, wait,
     "D" block, wait, status), report the Pico's status codes and timeouts,
     refuse to talk without the BIOS, and tape_enter sets TP_BANK / TP_SID.
  B. UI: the start screen offers P when the BIOS is present; the directory
     scrolls through 20 entries (cursor row inverted, window follows); P runs
     the SD flow (FMODE=RAW + REWIND frames, SD mode on), a scan with no tape
     ends on SPACE, Q sends FMODE=TAP.

Usage: v2_pico_test.py <out_dir>
"""
import re, socket, struct, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import v2_ui_smoke as U
import v2_codec_test as H          # TRAP / SP_TOP constants only
PORT = 10014
U.PORT = PORT
K = U.K
K.update({"q": U.mask(r2=0x01), "p": U.mask(r5=0x01), "3": U.mask(r3=0x04)})

fails = 0
def check(cond, what):
    global fails
    print(("  OK   " if cond else "  FAIL ") + what)
    if not cond: fails += 1


# ---------------------------------------------------------------------------
# the model: what EXROM $1B8D sends for SAVE/LOAD "TPI:xxx" (no CODE parameters)
# ---------------------------------------------------------------------------
def xor(bs):
    c = 0
    for b in bs: c ^= b
    return c

def frames(cmd, taddr=0):
    b = bytes([0x42, taddr, 0xFF, 0, 0, 0, 0, len(cmd), 0])
    d = bytes([0x44, len(cmd), 0]) + cmd.encode()
    return b + bytes([xor(b)]), d + bytes([xor(d)])


# ---------------------------------------------------------------------------
# emulator helpers on top of the smoke client
# ---------------------------------------------------------------------------
def syms():
    return {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M)}

def write(z, addr, data):
    for i in range(0, len(data), 256):
        z.cmd(f"write-memory-raw {addr + i} {data[i:i+256].hex()}")

def read(z, addr, n):
    return bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", z.cmd(f"read-memory {addr} {n}", limit=8)))

def reg_a(z):
    r = z.cmd("get-registers")
    m = re.search(r"\bA=([0-9a-fA-F]{2})", r) or re.search(r"\bAF=([0-9a-fA-F]{2})", r)
    return int(m.group(1), 16)

def call_hl(z, addr, hl):
    """trap-call: run addr with HL set and RET landing on a DI / JR $ trap (DI, so a
    pause never lands in the ROM's interrupt handler instead of on the trap)"""
    z.cmd("enter-cpu-step")
    write(z, H.TRAP, bytes([0xF3, 0x18, 0xFE]))
    write(z, H.SP_TOP, bytes([H.TRAP & 0xFF, H.TRAP >> 8]))
    z.cmd(f"set-register SP={H.SP_TOP:04X}h")
    z.cmd(f"set-register HL={hl:04X}h")
    z.cmd(f"set-register PC={addr:04X}h")
    z.cmd("exit-cpu-step")
    t0 = time.time()
    while time.time() - t0 < 20:
        time.sleep(0.05)
        z.cmd("enter-cpu-step")
        if z.pc() in (H.TRAP, H.TRAP + 1): return
        z.cmd("exit-cpu-step")
    regs = z.cmd("get-registers")
    raise RuntimeError(f"routine {addr:04X} did not return: {regs}")

def hijack(z, S, addr, SLOT):
    """stop inside our code (not in an interrupt handler) and continue at addr"""
    isr0, isr1 = S["isr_frames"], S["isr_frames_end"]
    for _ in range(80):
        z.cmd("enter-cpu-step")
        pc = z.pc()
        if 0x8000 <= pc < SLOT and not (isr0 <= pc < isr1): break
        z.cmd("exit-cpu-step"); time.sleep(0.02)
    z.cmd(f"set-register PC={addr:04X}h"); z.cmd("exit-cpu-step")

def glyph(z, row, col):
    base = 0x4000 | ((row & 0x18) << 8) | ((row & 7) << 5) | col
    return bytes(read(z, base + (y << 8), 1)[0] for y in range(8))

def rom_glyph(z, ch):
    return read(z, 0x3C00 + ord(ch) * 8, 8)

def attr(z, row, col):
    return read(z, 0x5800 + row * 32 + col, 1)[0]


# ---------------------------------------------------------------------------
# the fake Pico: stubs in MISC_FREE, log in the slot
# ---------------------------------------------------------------------------
class FakePico:
    def __init__(self, z, S):
        self.z, self.S = z, S
        base = S["MISC_FREE"]
        self.logp, self.rxp, self.rxbuf = base, base + 2, base + 8          # 16 B of replies
        self.log = S["SLOT_BASE"] + 0x200
        tx, rx, wok, wto = base + 32, base + 48, base + 64, base + 68
        def w16(a): return bytes([a & 0xFF, a >> 8])
        # push hl; ld hl,(LOGP); ld (hl),a; inc hl; ld (LOGP),hl; pop hl; and a; ret
        write(z, tx, b"\xE5\x2A" + w16(self.logp) + b"\x77\x23\x22" + w16(self.logp) + b"\xE1\xA7\xC9")
        # push hl; ld hl,(RXP); ld a,(hl); inc hl; ld (RXP),hl; pop hl; and a; ret
        write(z, rx, b"\xE5\x2A" + w16(self.rxp) + b"\x7E\x23\x22" + w16(self.rxp) + b"\xE1\xA7\xC9")
        write(z, wok, b"\xA7\xC9")            # and a; ret        (continue flag seen)
        write(z, wto, b"\x37\xC9")            # scf; ret          (2.8 ms timeout / BREAK)
        self.wok, self.wto = wok, wto
        write(z, S["tpi_tx"], b"\xC3" + w16(tx))
        write(z, S["tpi_rx"], b"\xC3" + w16(rx))
        self.wait(True)
        self.reset()
    def wait(self, ok):
        write(self.z, self.S["tpi_wait"], b"\xC3" + bytes([(self.wok if ok else self.wto) & 0xFF, (self.wok if ok else self.wto) >> 8]))
    def reset(self, replies=b"\x01" * 12):
        write(self.z, self.logp, bytes([self.log & 0xFF, self.log >> 8]))
        write(self.z, self.rxp, bytes([self.rxbuf & 0xFF, self.rxbuf >> 8]))
        write(self.z, self.rxbuf, (replies + b"\x00" * 16)[:16])
        write(self.z, self.log, b"\x00" * 128)
    def sent(self):
        end = struct.unpack("<H", read(self.z, self.logp, 2))[0]
        return read(self.z, self.log, end - self.log) if end > self.log else b""


def main():
    out = pathlib.Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
    if " " in str(out): sys.exit("out_dir must not contain spaces (ZRCP save-screen)")
    S = syms(); SLOT = S["SLOT_BASE"]
    code = (ROOT / "build/v2/tracker2.bin").read_bytes()
    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1)
    proc = subprocess.Popen([U.ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT), "--noconfigfile"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        for _ in range(40):
            try:
                s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
            except Exception: time.sleep(1)
        time.sleep(6)
        z = U.Z(); z.cmd("send-keys-ascii 200 13"); time.sleep(0.5)
        z.cmd("exit-cpu-step"); z.cmd("reset-cpu"); time.sleep(3)
        z.cmd("enter-cpu-step")
        write(z, 0x8000, code)
        z.cmd("exit-cpu-step")
        pico = FakePico(z, S)
        STR = SLOT + 0x100

        # ---- A. frames ----------------------------------------------------------
        print("=== A. TPI command frames (fake Pico in RAM)")
        write(z, S["tpi_ok"], b"\x01"); write(z, S["tp_hsr"], b"\x03")
        write(z, S["TP_BANK"], b"\x12"); write(z, S["TP_SID"], b"\x56\x34")       # poison
        for name, entry, taddr in (("TPI:FMODE=RAW", "tpi_save", 0), ("TPI:REWIND", "tpi_load", 1)):
            pico.reset(b"\x01\x01")
            write(z, STR, bytes([len(name)]) + name.encode())
            call_hl(z, S[entry], STR)
            b, d = frames(name, taddr)
            got = pico.sent()
            check(got == b + d, f"{entry} {name!r}: frames {got.hex()}" + ("" if got == b + d else f" != {(b + d).hex()}"))
            check(reg_a(z) == 1 and read(z, S["tpi_err"], 1) == b"\x01", "returns 1, status 1 kept")
        check(read(z, S["TP_BANK"], 1) == b"\xFF" and read(z, S["TP_SID"], 2) == b"\x00\x00", "tape_enter set TP_BANK=$FF, TP_SID=0 for the 16K EXROM")
        name = "TPI:FMODE=RAW"; b, d = frames(name)
        write(z, STR, bytes([len(name)]) + name.encode())
        def outcome():
            return pico.sent(), reg_a(z), read(z, S["tpi_err"], 1)[0]
        pico.reset(b"\x02\x01"); call_hl(z, S["tpi_save"], STR); got = outcome()
        check(got == (b, 0, 2), f"status 2 after the B block: fails with tpi_err=2, no D block  (sent {got[0].hex()} A={got[1]} err={got[2]:02X})")
        pico.wait(False); pico.reset(b"\x01\x01"); call_hl(z, S["tpi_save"], STR); pico.wait(True); got = outcome()
        check(got == (b, 0, 0xFF), f"no continue flag: fails with tpi_err=$FF after the B block  (sent {got[0].hex()} A={got[1]} err={got[2]:02X})")
        pico.reset(b"\x01\x02"); call_hl(z, S["tpi_save"], STR); got = outcome()
        check(got == (b + d, 0, 2), f"status 2 after the D block: fails with tpi_err=2  (sent {got[0].hex()} A={got[1]} err={got[2]:02X})")
        write(z, S["tpi_ok"], b"\x00"); pico.reset(); call_hl(z, S["tpi_save"], STR); got = outcome()
        check(got == (b"", 0, 0xFE), f"without the BIOS: nothing sent, tpi_err=$FE  (sent {got[0].hex()} A={got[1]} err={got[2]:02X})")

        # ---- B. UI --------------------------------------------------------------
        print("=== B. start screen, directory, SD flow")
        write(z, S["tp_hsr"], b"\x01")                       # the stock EXROM for any real tape call
        z.cmd("enter-cpu-step"); write(z, SLOT, b"\x00" * 32); z.cmd("set-register PC=8000h"); z.cmd("exit-cpu-step"); time.sleep(1.5)
        check(read(z, S["tpi_ok"], 1) == b"\x00", "stock ROM: tpi_detect finds no TPI BIOS")
        check(glyph(z, 14, 3) == bytes(8), "start screen without the BIOS has no P line")
        write(z, S["tpi_ok"], b"\x01"); write(z, S["tpi_vers"], b"\x15\x00")
        hijack(z, S, S["t_startscr"], SLOT); time.sleep(1.0)
        z.shot(out / "01_start_pico.png")
        check(glyph(z, 14, 3) == rom_glyph(z, "P") and glyph(z, 15, 24) == rom_glyph(z, "2") and glyph(z, 15, 25) == rom_glyph(z, "1")
              and attr(z, 15, 24) == 0x05 and attr(z, 15, 25) == 0x05, "start screen shows the P line and 'TPI BIOS 21' (visible)")
        # a 20-entry directory
        ents = b"".join(f"SONG_{i:02d}   ".encode()[:10] + struct.pack("<H", 1000 + i) + bytes([3 if i % 3 else 2, 0]) for i in range(20))
        hijack(z, S, S["t_startscr"], SLOT)                  # (somewhere harmless to stop again)
        z.cmd("enter-cpu-step"); write(z, S["DIR_BUF"], ents); write(z, S["dir_count"], b"\x14"); write(z, S["song_len"], b"\x00\x00"); z.cmd("exit-cpu-step")
        hijack(z, S, S["t_directory"], SLOT); time.sleep(1.0)
        z.shot(out / "02_directory.png")
        check(glyph(z, 4, 7) == rom_glyph(z, "S") and glyph(z, 18, 7) == rom_glyph(z, "S") and glyph(z, 19, 7) == bytes(8)
              and glyph(z, 4, 17) == bytes(8) and glyph(z, 4, 26) == bytes(8), "15 of 20 entries on rows 4-18, rows cleared first")
        check(attr(z, 4, 5) == 0x78 and attr(z, 5, 5) == 0x07 and glyph(z, 12, 1) == rom_glyph(z, "9") and glyph(z, 13, 1) == bytes(8),
              "entry 0 selected (inverted); digits 1-9 on the first nine rows")
        for _ in range(16): z.press("down", settle=0.15)
        z.shot(out / "03_scrolled.png")
        top, cur = read(z, S["dir_top"], 1)[0], read(z, S["dir_cur"], 1)[0]
        check((top, cur) == (2, 16) and attr(z, 18, 5) == 0x78 and attr(z, 4, 5) == 0x07 and glyph(z, 4, 13) == rom_glyph(z, "2"),
              f"16 x down: cursor 16, window from 2 (top={top} cur={cur}); last row inverted, row 4 shows SONG_02")
        for _ in range(5): z.press("down", settle=0.15)
        top, cur = read(z, S["dir_top"], 1)[0], read(z, S["dir_cur"], 1)[0]
        check((top, cur) == (5, 19), f"stops at the last entry (top={top} cur={cur})")
        for _ in range(25): z.press("up", settle=0.12)
        top, cur = read(z, S["dir_top"], 1)[0], read(z, S["dir_cur"], 1)[0]
        check((top, cur) == (0, 0), f"and back at the first (top={top} cur={cur})")
        z.press("3", settle=0.8)                              # load row 3 (tape mode -> rewind prompt)
        z.shot(out / "04_rewind_prompt.png")
        check(glyph(z, 23, 0) == rom_glyph(z, "R") and read(z, S["dir_cur"], 1) == b"\x02", "1-9 picks the row: rewind prompt for entry 2")
        z.press("q", settle=0.8)
        check(glyph(z, 23, 1) == rom_glyph(z, "E"), "Q at the prompt: back to the directory hint")
        # the SD flow: P on the start screen -> FMODE=RAW, REWIND, SD mode; scan with no tape ends on SPACE; Q -> FMODE=TAP
        z.press("q", settle=0.8)
        pico.reset(b"\x01" * 12)
        write(z, S["TP_MODE"], b"\x00")
        z.press("p", settle=1.5)
        z.shot(out / "05_sd_scanning.png")
        b1, d1 = frames("TPI:FMODE=RAW"); b2, d2 = frames("TPI:REWIND"); b3, d3 = frames("TPI:FMODE=TAP")
        check(pico.sent() == b1 + d1 + b2 + d2, "P sent FMODE=RAW then REWIND")
        check(read(z, S["sd_mode"], 1) == b"\x01" and read(z, S["sd_raw"], 1) == b"\x01" and read(z, S["TP_MODE"], 1) == b"\x02"
              and read(z, S["sd_changed"], 1) == b"\x01", "SD mode on (TP_MODE bit 1), raw files, mode remembered for quit")
        check(glyph(z, 1, 0) == rom_glyph(z, "S") and glyph(z, 1, 3) == rom_glyph(z, "C"), "title 'SD CARD'")
        z.press("space", hold=0.3, settle=1.5)                # BREAK ends the (tapeless) scan
        z.shot(out / "06_sd_empty.png")
        check(glyph(z, 4, 1) == rom_glyph(z, "("), "scan ended by SPACE: '(no songs found...)'")
        z.press("q", settle=1.0)
        check(pico.sent() == b1 + d1 + b2 + d2 + b3 + d3, "Q from the SD directory sent FMODE=TAP")
        check(glyph(z, 14, 3) == rom_glyph(z, "P"), "back on the start screen")
        z.shot(out / "07_start_again.png")
    finally:
        if proc.poll() is None: proc.kill()
    print("\nPICO TEST", "PASS" if not fails else f"FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
