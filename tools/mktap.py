#!/usr/bin/env python3
"""Wrap a raw Z80 binary in a Spectrum/TS2068 .tap with a BASIC loader.

Usage: mktap.py <in.bin> <org_decimal> <out.tap> [name] [extra.bin@org ...]

Emits: BASIC header + one-line loader, then a CODE header + body for the
main binary, then one CODE header + body per extra file (each with its own
load address). The loader is

    10 CLEAR org-1: LOAD "" CODE [: LOAD "" CODE ...]: RANDOMIZE USR org

using VAL "..." for the numbers so the tokenised line needs no 5-byte
float trailers. Pure ROM-BASIC, so it runs unchanged on a TS2068.
"""
import struct, sys, pathlib

def xor(b):
    x = 0
    for c in b: x ^= c
    return x

def block(payload):
    return struct.pack('<H', len(payload) + 1) + payload + bytes([xor(payload)])

def header(ftype, name, length, p1, p2):
    nm = (name.encode('ascii', 'replace') + b' ' * 10)[:10]
    return block(bytes([0x00, ftype]) + nm + struct.pack('<HHH', length, p1, p2))

def basic_loader(org, n_code_blocks):
    # tokens: CLEAR=$FD VAL=$B0 LOAD=$EF CODE=$AF RANDOMIZE=$F9 USR=$C0
    line = bytes([0xFD, 0xB0]) + b'"%d"' % (org - 1)
    for _ in range(n_code_blocks):
        line += bytes([0x3A, 0xEF, 0x22, 0x22, 0xAF])         # : LOAD "" CODE
    line += bytes([0x3A, 0xF9, 0xC0, 0xB0]) + b'"%d"' % org    # : RANDOMIZE USR VAL "org"
    line += b'\r'
    prog = struct.pack('>H', 10) + struct.pack('<H', len(line)) + line
    return prog

def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    src  = pathlib.Path(sys.argv[1]).read_bytes()
    org  = int(sys.argv[2])
    out  = pathlib.Path(sys.argv[3])
    name = sys.argv[4] if len(sys.argv) > 4 else out.stem[:10]
    extras = []
    for spec in sys.argv[5:]:
        path, at = spec.rsplit('@', 1)
        extras.append((pathlib.Path(path).read_bytes(), int(at, 0)))

    prog = basic_loader(org, 1 + len(extras))
    tap  = header(0, name, len(prog), 10, len(prog)) + block(bytes([0xFF]) + prog)
    tap += header(3, name, len(src), org, 0x8000) + block(bytes([0xFF]) + src)
    for data, at in extras:
        tap += header(3, name, len(data), at, 0x8000) + block(bytes([0xFF]) + data)
    out.write_bytes(tap)
    print(f'wrote {out}: main {len(src)} B @ {org} (${org:04X}), '
          f'{len(extras)} extra block(s), {len(tap)} B total')

if __name__ == '__main__':
    main()
