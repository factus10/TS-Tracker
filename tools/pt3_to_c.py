#!/usr/bin/env python3
"""Convert a .pt3 binary to a C source file that exposes it as a const array.

Usage: pt3_to_c.py <input.pt3> <output.c> <symbol>
"""
import sys, pathlib

def main():
    if len(sys.argv) != 4:
        print(__doc__); sys.exit(1)
    src = pathlib.Path(sys.argv[1]).read_bytes()
    out = pathlib.Path(sys.argv[2])
    sym = sys.argv[3]
    rows = []
    for i in range(0, len(src), 16):
        chunk = src[i:i+16]
        rows.append('    ' + ', '.join(f'0x{b:02X}' for b in chunk) + ',')
    body = '\n'.join(rows)
    text = (
        f'/* Auto-generated from {pathlib.Path(sys.argv[1]).name} '
        f'({len(src)} bytes). Do not edit. */\n\n'
        f'const unsigned char {sym}[{len(src)}] = {{\n{body}\n}};\n\n'
        f'const unsigned int  {sym}_size = {len(src)};\n'
    )
    out.write_text(text, encoding='ascii')
    print(f'wrote {out} ({len(src)} bytes -> {out.stat().st_size} bytes of C)')

if __name__ == '__main__':
    main()
