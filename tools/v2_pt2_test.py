#!/usr/bin/env python3
"""PT2 import parity: the Z80 converter must produce the same PT3 as tools/pt2conv.py.

For every songs/*.pt2: place the module at the top of the slot (where
pt2_import moves it), set pt2_src / pt2_len, call t_pt2 and compare the slot
from SLOT_BASE to song_len with the Python conversion, byte for byte. The
converted song must also decode cleanly with the reference codec.

Uses the codec harness's ZEsarUX launch and trap-call machinery (no `start`;
the machine stays in IM1).

Usage: v2_pt2_test.py [song.pt2 ...]
"""
import glob, pathlib, struct, sys, functools
print = functools.partial(print, flush=True)
HERE = pathlib.Path(__file__).resolve().parent; ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import pt3codec as C
import pt2conv as P
import v2_codec_test as H
H.PORT = 10013


def main():
    files = sys.argv[1:] or sorted(glob.glob(str(ROOT / "songs/*.pt2")))
    S = H.load_syms(ROOT / "build/v2/tracker2.sym")
    code = (ROOT / "build/v2/tracker2.bin").read_bytes()
    SLOT, SLOT_END = S["SLOT_BASE"], S["SLOT_END"]
    tpl = (ROOT / "build/v2/template.bin").read_bytes()
    proc, z = H.launch()
    ok = True
    try:
        z.write(0x8000, code)
        for f in files:
            pt2 = pathlib.Path(f).read_bytes()
            warn = []; expect = P.convert(pt2, tpl, warn)
            src = SLOT_END - len(pt2)
            print(f"\n=== {pathlib.Path(f).name}  PT2 {len(pt2)} B at ${src:04X}")
            z.write(src, pt2)
            z.write(S["pt2_src"], struct.pack("<H", src))
            z.write(S["pt2_len"], struct.pack("<H", len(pt2)))
            z.write(S["song_len"], b"\0\0")
            z.call(S["t_pt2"])
            failed = z.read(S["t_arg"], 1)[0]
            slen = struct.unpack("<H", z.read(S["song_len"], 2))[0]
            if failed:
                print("  FAIL converter reported no room"); ok = False; continue
            got = z.read(SLOT, slen)
            if got == expect:
                print(f"  OK   Z80 PT3 == Python PT3 ({slen} B, {C.Song(got).num_patterns()} patterns)")
            else:
                ok = False
                n = next((i for i in range(min(len(got), len(expect))) if got[i] != expect[i]), min(len(got), len(expect)))
                print(f"  FAIL differ: Z80 {slen} B, Python {len(expect)} B, first difference at offset {n}")
                print(f"       Z80    {got[max(0,n-8):n+8].hex()}")
                print(f"       Python {expect[max(0,n-8):n+8].hex()}")
            song = C.Song(got)
            try:
                for p in range(song.num_patterns()): C.decode_pattern(song, p)
                print(f"  OK   decodes cleanly")
            except Exception as e:
                ok = False; print(f"  FAIL decode: {e}")
            for w in warn[:3]: print("  note:", w)
    finally:
        if proc.poll() is None: proc.kill()
    print("\nPT2 IMPORT PARITY", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    main()
