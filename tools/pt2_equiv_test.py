#!/usr/bin/env python3
"""Does a converted PT3 sound exactly like its PT2 original?

Loads the universal PTxPlay (build/player/ptxplay.bin, PT2+PT3) into a bare
TS2068 in ZEsarUX, plays the PT2 in PT2 mode and the converted PT3 (from
tools/pt2conv.py) in PT3 mode, and compares the AY register shadow after every
frame, masked to the bits the chip latches. Identical streams mean the conversion is inaudible.

A tiny recorder stub in RAM calls PLAY N times and copies AYREGS into a buffer
after each call, so one CPU hijack records a whole run (the earlier version
hijacked per frame and made the emulator flash its menu for minutes). The CPU
is driven with the codec harness's trap-call technique (IM1, hijacked from the
ROM handler entry with interrupts off, so PLAY is never interrupted).

Usage: pt2_equiv_test.py [--frames N] [song.pt2 ...]   (default: songs/*.pt2, 600 frames)
"""
import glob, pathlib, re, struct, sys, time, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt2conv as P
import v2_codec_test as H          # ZRCP class, launch(), TRAP/SP_TOP
H.PORT = 10012

SONG_AT = 0x8000                   # the song module (PTxPlay relocates via MODADDR)
STUB_AT = 0x7000                   # recorder stub
COUNT_AT = 0x7080                  # its frame counter (word)
BUF_AT = 0xA000                    # AYREGS x frames (14 bytes each; 600 frames = 8.4 KB)


def syms():
    return {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/player/ptxplay.sym").read_text(), re.M)}


def stub(play, ayregs):
    """di; ld de,BUF / loop: push de; call PLAY; pop de; ld hl,AYREGS; ld bc,14; ldir;
       ld hl,(COUNT); dec hl; ld (COUNT),hl; ld a,h; or l; jr nz,loop; ret"""
    code = bytearray([0xF3, 0x11, BUF_AT & 0xFF, BUF_AT >> 8])     # di: PLAY must not be interrupted
    loop = len(code)
    code += bytes([0xD5, 0xCD, play & 0xFF, play >> 8, 0xD1,
                   0x21, ayregs & 0xFF, ayregs >> 8, 0x01, 14, 0, 0xED, 0xB0,
                   0x2A, COUNT_AT & 0xFF, COUNT_AT >> 8, 0x2B, 0x22, COUNT_AT & 0xFF, COUNT_AT >> 8,
                   0x7C, 0xB5])
    code += bytes([0x20, (loop - (len(code) + 2)) & 0xFF, 0xC9])
    return bytes(code)


def call_hl(z, addr, hl=None):
    """like ZRCP.call, with HL set for INIT"""
    z.cmd("enter-cpu-step")
    z.write(H.TRAP, bytes([0x18, 0xFE]))
    z.write(H.SP_TOP, bytes([H.TRAP & 0xFF, H.TRAP >> 8]))
    z.cmd(f"set-register SP={H.SP_TOP:04X}h")
    if hl is not None: z.cmd(f"set-register HL={hl:04X}h")
    z.cmd(f"set-register PC={addr:04X}h")
    z.cmd("exit-cpu-step")
    t0 = time.time()
    while time.time() - t0 < 30.0:
        time.sleep(0.1)
        z.cmd("enter-cpu-step")
        if z.pc() == H.TRAP: return
        z.cmd("exit-cpu-step")
    raise RuntimeError(f"routine {addr:04X} did not return (PC={z.pc():04X})")


# what the AY-3-8912 actually latches: 12-bit tone periods, 5-bit noise,
# 6-bit mixer, 5-bit amplitudes (bit 4 = envelope), 16-bit envelope period, 4-bit shape
AY_MASK = bytes([0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0x3F, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F])


def audible(regs):
    return bytes(r & m for r, m in zip(regs, AY_MASK))


def play_stream(z, S, song, pt2, frames):
    z.write(SONG_AT, song)
    z.write(S["SETUP"], bytes([2 if pt2 else 0]))
    call_hl(z, S["INIT"], SONG_AT)
    z.write(COUNT_AT, struct.pack("<H", frames))
    call_hl(z, STUB_AT)
    raw = z.read(BUF_AT, 14 * frames)
    return [raw[i * 14:(i + 1) * 14] for i in range(frames)]


def main():
    args = sys.argv[1:]; frames = 600
    if "--frames" in args:
        i = args.index("--frames"); frames = int(args[i + 1]); del args[i:i + 2]
    files = args or sorted(glob.glob(str(ROOT / "songs/*.pt2")))
    S = syms(); ptx = (ROOT / "build/player/ptxplay.bin").read_bytes()
    proc, z = H.launch()
    ok = True
    try:
        z.write(S["START"], ptx)
        z.write(STUB_AT, stub(S["PLAY"], S["AYREGS"]))
        for f in files:
            pt2 = pathlib.Path(f).read_bytes()
            warn = []; pt3 = P.convert(pt2, warn=warn)
            print(f"\n=== {pathlib.Path(f).name}  PT2 {len(pt2)} B -> PT3 {len(pt3)} B, {frames} frames")
            a = play_stream(z, S, pt2, True, frames)
            b = play_stream(z, S, pt3, False, frames)
            diff = [i for i in range(frames) if audible(a[i]) != audible(b[i])]
            raw = sum(1 for i in range(frames) if a[i] != b[i])
            if not diff:
                print(f"  OK   AY registers identical on all {frames} frames"
                      + (f" ({raw} differ only in bits the chip ignores: PTxPlay's PT2 path leaves the volume nibble in the tone high byte)" if raw else ""))
            else:
                ok = False
                print(f"  FAIL {len(diff)} of {frames} frames differ; first at frame {diff[0]}:")
                for i in diff[:5]:
                    print(f"       {i:4d}  PT2 {a[i].hex()}  PT3 {b[i].hex()}")
            for w in warn[:5]: print("  note:", w)
    finally:
        if proc.poll() is None: proc.kill()
    print("\nPT2 EQUIVALENCE", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
