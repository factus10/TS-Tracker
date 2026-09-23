#!/usr/bin/env python3
"""Boot build/v2/tracker2-demo.tap in a private ZEsarUX, drive the editor via
the keyboard matrix, and save screenshots (PNG, 3x) into an output directory.

Usage: v2_ui_smoke.py <out_dir> [tap]     (default tap: build/v2/tracker2-demo.tap)
"""
import os, re, shutil, socket, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
ZESARUX = "/Applications/zesarux.app/Contents/MacOS/zesarux"
PORT = 10002
REL = "FFFFFFFFFFFFFFFF00"
# key masks: 8 rows ($FE..$7F) + joystick; 0 bit = pressed
def mask(**rows):
    m = [0xFF] * 8
    for r, bits in rows.items(): m[int(r[1])] &= ~bits & 0xFF
    return "".join(f"{b:02X}" for b in m) + "00"
K = {
    "down":  mask(r0=1, r4=0x10), "up": mask(r0=1, r4=0x08), "left": mask(r0=1, r3=0x10), "right": mask(r0=1, r4=0x04),
    "sym_p": mask(r7=2, r5=0x01), "sym_o": mask(r7=2, r5=0x02), "sym_a": mask(r7=2, r1=0x01), "sym_l": mask(r7=2, r6=0x02),
    "sym_h": mask(r7=2, r6=0x10), "sym_i": mask(r7=2, r5=0x04), "sym_x": mask(r7=2, r0=0x04),
    "z": mask(r0=0x02), "c": mask(r0=0x08), "space": mask(r7=0x01), "enter": mask(r6=0x01), "n": mask(r7=0x08),
    "3": mask(r3=0x04), "f": mask(r1=0x08), "any": mask(r7=0x04),
}


class Z:
    PROMPT = re.compile(rb"command(@[\w-]+)?>\s*$")
    def __init__(self):
        self.s = socket.socket(); self.s.connect(("localhost", PORT)); self.s.settimeout(0.05); self._reply(3)
    def _reply(self, limit):
        d = b""; t0 = time.time()
        while time.time() - t0 < limit:
            try:
                c = self.s.recv(65536)
                if c: d += c
            except socket.timeout: pass
            if self.PROMPT.search(d): break
        return d
    def cmd(self, c, limit=5.0):
        self.s.sendall((c + "\n").encode()); return self.PROMPT.sub(b"", self._reply(limit)).decode(errors="replace").strip()
    def pc(self):
        m = re.search(r"PC=([0-9a-fA-F]{4})", self.cmd("get-registers")); return int(m.group(1), 16) if m else -1
    def press(self, name, hold=0.08, settle=0.35):
        self.cmd(f"set-ui-io-ports {K[name]}"); time.sleep(hold); self.cmd(f"set-ui-io-ports {REL}"); time.sleep(settle)
    def shot(self, path):
        scr = str(path) + ".scr"
        self.cmd(f"save-screen {scr}"); time.sleep(0.3)
        scr_to_png(scr, str(path)); os.remove(scr)


def scr_to_png(scr, png, scale=3):
    from PIL import Image
    d = open(scr, "rb").read()
    pal = [(0,0,0),(0,0,192),(192,0,0),(192,0,192),(0,192,0),(0,192,192),(192,192,0),(192,192,192)]
    palb = [(0,0,0),(0,0,255),(255,0,0),(255,0,255),(0,255,0),(0,255,255),(255,255,0),(255,255,255)]
    im = Image.new("RGB", (256, 192)); px = im.load()
    for y in range(192):
        base = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
        for cx in range(32):
            b = d[base + cx]; a = d[6144 + (y // 8) * 32 + cx]
            p = palb if a & 0x40 else pal
            for x in range(8):
                px[cx * 8 + x, y] = p[a & 7] if (b >> (7 - x)) & 1 else p[(a >> 3) & 7]
    im.resize((256 * scale, 192 * scale), Image.NEAREST).save(png)


def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    tap = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "build/v2/tracker2-demo.tap"
    safe = out / "demo.tap"; shutil.copy(tap, safe)              # ZRCP paths must not contain spaces
    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1.5)
    proc = subprocess.Popen([ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol",
                             "--remoteprotocol-port", str(PORT), "--noconfigfile"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        for _ in range(40):
            try:
                s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
            except Exception: time.sleep(1)
        time.sleep(6)
        z = Z(); z.cmd("send-keys-ascii 200 13"); time.sleep(0.5)
        z.cmd("exit-cpu-step"); z.cmd("reset-cpu"); time.sleep(3)
        z.cmd(f"smartload {safe.resolve()}")
        t0 = time.time(); running = False
        while time.time() - t0 < 240:                  # a 14 KB tape takes over a minute
            time.sleep(2)
            r = z.cmd("get-registers").lower()
            m = re.search(r"pc=([0-9a-f]{4})", r); pc = int(m.group(1), 16) if m else -1
            if 0x8000 <= pc < 0xC800 or (pc < 0x100 and "sp=fe" in r):   # our code, or the ISR on our stack
                running = True; break
        time.sleep(1.5)
        print("running" if running else "NOT RUNNING", "PC=%04X after %.0fs" % (z.pc(), time.time() - t0))
        z.shot(out / "01_boot.png")
        for _ in range(3): z.press("down")
        z.press("right"); z.press("right")
        z.shot(out / "02_cursor.png")
        z.press("left"); z.press("left")
        z.press("c")                                    # C in the note field (octave 4) -> C-4, auto-advance
        z.press("3"); z.press("z")                      # octave 3, Z -> C-3
        z.press("enter")                                # rest
        z.shot(out / "03_notes.png")
        z.press("sym_p"); z.shot(out / "04_nextpos.png")   # commit + next position
        z.press("sym_o"); z.shot(out / "05_prevpos.png")   # back: our edits must still be there
        z.press("sym_h"); z.shot(out / "06_help.png"); z.press("any")
        z.press("sym_a", hold=0.1, settle=2.5); z.shot(out / "07_playing.png")
        z.press("space"); time.sleep(0.6); z.shot(out / "08_after_play.png")
        print("PC=%04X" % z.pc(), "done")
    finally:
        if proc.poll() is None: proc.kill()      # SIGKILL: no autosave-snapshot overwrite on exit


if __name__ == "__main__":
    main()
