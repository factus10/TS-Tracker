#!/usr/bin/env python3
"""Emit a C header of #defines from an sjasmplus .sym file.

Usage: bin_to_c.py <in.sym> <out.h> [SYM1 SYM2 ...]

The companion .bin is shipped to the TS2068 as a separate tape CODE block
(see tools/append_code_block.py), so we only need its symbol addresses
on the C side -- no embedded array needed.
"""
import sys, pathlib, re

if len(sys.argv) < 4:
    print(__doc__); sys.exit(1)

sym_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
wanted   = sys.argv[3:]

syms = {}
for line in sym_path.read_text().split('\n'):
    m = re.match(r'^(\w+):\s+EQU\s+0x([0-9A-Fa-f]+)', line)
    if m:
        syms[m.group(1)] = int(m.group(2), 16)

missing = [s for s in wanted if s not in syms]
if missing:
    sys.exit(f'missing symbols in {sym_path}: {missing}')

guard = out_path.stem.upper().replace('-', '_') + '_H'
out = [f'/* Auto-generated from {sym_path.name}. */',
       f'#ifndef {guard}',
       f'#define {guard}',
       '']
for s in wanted:
    out.append(f'#define {s}_ADDR 0x{syms[s]:04X}')
out += ['', f'#endif']

out_path.write_text('\n'.join(out) + '\n', encoding='ascii')
print(f'wrote {out_path}: ' +
      ', '.join(f'{s}=0x{syms[s]:04X}' for s in wanted))
