#!/usr/bin/env python3
"""Produce build/PTxPlay.asm from vendor/PTxPlay/PTxPlay.asm for sjasmplus.

We strip the original's leading test driver and trailing incbin/scratch,
flip the conditional-assembly switches to TS2068, and splice in a TS2068
ROUT branch. The resulting file assembles to a flat binary (.bin) that we
load at a fixed address at runtime and call into via inline-asm thunks.

Usage: build_ptxplay_asm.py [ORIGIN_HEX]

ORIGIN_HEX is the 16-bit load address PTxPlay assembles at, as a hex
string (no `$` or `0x` prefix), e.g. "B500". Defaults to "C000". Picking
this dynamically based on the C binary's tail lets us shrink the gap
between the C image and the song slot, instead of leaving 5+ KB of dead
RAM between them.
"""
import pathlib, re, sys

origin_hex = sys.argv[1].upper() if len(sys.argv) > 1 else 'C000'
if not re.fullmatch(r'[0-9A-F]{4}', origin_hex):
    sys.exit(f'bad origin hex {origin_hex!r}: want a 4-char hex string')

src_path = pathlib.Path('vendor/PTxPlay/PTxPlay.asm')
dst_path = pathlib.Path('build/PTxPlay.asm')
dst_path.parent.mkdir(parents=True, exist_ok=True)

raw = src_path.read_text(encoding='latin1')
lines = raw.split('\n')

start_idx = next(i for i, l in enumerate(lines) if l.startswith('TonA'))
mdl_idx   = next(i for i, l in enumerate(lines) if l.startswith('MDLADDR EQU'))
body = lines[start_idx:mdl_idx]

ts2068_rout = """
    IF TS2068
;TS2068 version of ROUT - same shape as MSX, ports $F5/$F6
    XOR A
    LD C,#F5
    LD HL,AYREGS
LOUT_TS:
    OUT (C),A
    INC C
    OUTI
    DEC C
    INC A
    CP 13
    JR NZ,LOUT_TS
    OUT (C),A
    LD A,(HL)
    AND A
    RET M
    INC C
    OUT (C),A
    RET
    ENDIF
""".strip('\n').split('\n')

for i, line in enumerate(body):
    if re.match(r'\s*IF\s+ZX\s*$', line):
        body = body[:i] + ts2068_rout + [''] + body[i:]
        break
else:
    sys.exit("could not splice TS2068 ROUT")

prelude = [
    '; Auto-generated from vendor/PTxPlay/PTxPlay.asm by tools/build_ptxplay_asm.py.',
    '; Universal PT2/PT3 player by S.V. Bulba; assembled with sjasmplus to a',
    '; flat .bin that the C side memcpys to a fixed address at runtime.',
    '',
    '    DEVICE NOSLOT64K',
    '',
    'ZX     EQU 0',
    'MSX    EQU 0',
    'RC     EQU 0',
    'TS2068 EQU 1',
    'CurPosCounter EQU 1',  # exposes a CurPos byte at START+11 holding the
                            # current position-list index; we read it from
                            # the editor to highlight the playing pattern.
    'ACBBAC        EQU 0',
    'LoopChecker   EQU 1',  # PTxPlay sets bit 7 of SETUP each time the song
                            # passes its loop point; we use that for auto-advance.
    'Id            EQU 0',
    'Release       EQU 1',
    '',
    f'    ORG ${origin_hex}        ; final runtime address; the .bin is position-dependent',
    '                     ; (self-modifying) so this must match the LOAD address.',
    '',
    '; The original used MDLADDR as a fallback song-data label after the code,',
    '; for the START+0 entry. We never use START+0 (callers always pass HL),',
    '; so a dummy is enough to satisfy the reference.',
    'MDLADDR EQU 0',
    '',
]

# We need a stable label at the very start so we can reference its address from
# the symbol table; that anchor IS the START label of the original code, so we
# add a duplicate marker `_PTX_BASE` that aliases START's address.
postlude_top = ['_PTX_BASE EQU $']

dst_path.write_text(
    '\n'.join(prelude + postlude_top + body) + '\n',
    encoding='ascii', errors='replace'
)
print(f'wrote {dst_path}: {len(prelude) + len(postlude_top) + len(body)} lines')
