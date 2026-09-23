#!/usr/bin/env python3
"""Capture the v2 screens for the manual and README.

Boots build/v2/tracker2-demo.tap (Kenotron) and photographs: the pattern
editor after a couple of edits (with the '*' modified flag), the help page, the
sample and ornament editors, the arrangement editor, song info, the save prompt
and playback with a channel muted. Then boots build/v2/tracker2.tap alone for
the start screen. PNGs land in <out_dir>; copy the ones you want into
docs/screenshots/.

Usage: v2_shots.py <out_dir>
"""
import re, shutil, socket, subprocess, sys, time, pathlib, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import v2_ui_smoke as U
PORT = 10010; U.PORT = PORT
K = U.K
K.update({"sym_e": U.mask(r7=2, r2=0x04), "sym_r": U.mask(r7=2, r2=0x08), "sym_f": U.mask(r7=2, r1=0x08),
          "sym_g": U.mask(r7=2, r1=0x10), "sym_s": U.mask(r7=2, r1=0x02), "q": U.mask(r2=0x01),
          "break": U.mask(r0=1, r7=1), "2": U.mask(r3=0x02), "b": U.mask(r7=0x10)})


def boot(z, tap, slot):
    z.cmd("send-keys-ascii 200 13"); time.sleep(0.5); z.cmd("exit-cpu-step"); z.cmd("reset-cpu"); time.sleep(3)
    z.cmd(f"smartload {tap.resolve()}")
    t0 = time.time()
    while time.time() - t0 < 240:
        time.sleep(2); r = z.cmd("get-registers").lower()
        m = re.search(r"pc=([0-9a-f]{4})", r); pc = int(m.group(1), 16) if m else -1
        if 0x8000 <= pc < slot or (pc < 0x100 and "sp=fe" in r): break
    time.sleep(2.0)


def launch():
    subprocess.run(["pkill", "-9", "-f", f"remoteprotocol-port {PORT}"], capture_output=True); time.sleep(1)
    proc = subprocess.Popen([U.ZESARUX, "--machine", "TS2068", "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT), "--noconfigfile"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        try:
            s = socket.socket(); s.settimeout(1); s.connect(("localhost", PORT)); s.close(); break
        except Exception: time.sleep(1)
    time.sleep(6)
    return proc, U.Z()


def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    slot = int(re.search(r"^SLOT_BASE:\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M).group(1), 16)
    demo = out / "demo.tap"; shutil.copy(ROOT / "build/v2/tracker2-demo.tap", demo)
    plain = out / "plain.tap"; shutil.copy(ROOT / "build/v2/tracker2.tap", plain)
    proc, z = launch()
    try:
        boot(z, demo, slot)
        z.shot(out / "editor-clean.png")
        for _ in range(4): z.press("down")
        z.press("c"); z.press("down"); z.press("b")              # C-4, then G-4 two rows down (the '*' appears)
        z.press("up"); z.press("up"); z.press("up")
        z.shot(out / "editor.png")
        z.press("sym_h", settle=0.8); z.shot(out / "help.png"); z.press("any", settle=0.8)
        z.press("sym_e", settle=1.0); z.shot(out / "sample.png"); z.press("q", settle=1.0)
        z.press("sym_r", settle=1.0); z.shot(out / "ornament.png"); z.press("q", settle=1.0)
        z.press("sym_f", settle=1.0); z.shot(out / "arrangement.png"); z.press("enter", settle=1.2)
        z.press("sym_g", settle=1.0); z.shot(out / "songinfo.png"); z.press("enter", settle=1.0)
        z.press("sym_s", settle=2.5); z.shot(out / "save.png"); z.press("break", settle=1.2)
        z.press("sym_a", hold=0.1, settle=2.0)
        z.cmd(f"set-ui-io-ports {K['2']}"); time.sleep(0.1); z.cmd(f"set-ui-io-ports {U.REL}"); time.sleep(1.0)
        z.shot(out / "playing.png"); z.press("space", settle=1.0)
        print("demo screens done")
    finally:
        if proc.poll() is None: proc.kill()
    proc, z = launch()
    try:
        boot(z, plain, slot)
        z.shot(out / "start.png")
        print("start screen done")
    finally:
        if proc.poll() is None: proc.kill()


if __name__ == "__main__":
    main()
