#!/usr/bin/env python3
"""PT2 -> PT3 converter: the reference model for the on-machine import.

Everything here mirrors what asm/v2/pt2conv.asm does on the 2068, byte for
byte, so tools/v2_pt2_test.py can compare the two outputs directly.

PT2 layout (as PTxPlay's INITPT2 reads it; pointers are module-relative):
    0        delay
    1        number of positions
    2        loop position
    3..66    32 sample pointers      ->  [length, loop] + length x 3 bytes
    67..98   16 ornament pointers    ->  [length, loop] + length x 1 byte
    99..100  pattern table pointer   ->  3 words (channel streams) per pattern
    101..130 name (30 chars)
    131..    position list: pattern numbers, $FF ends

PT2 stream grammar (PTxPlay PD2_LOOP), one event = prefixes + terminator:
    E1..FF  sample n-E0            E0      release (terminator)
    80..DF  note n-80 (terminator) 7F      envelope off
    71..7E  envelope shape n-70, then period lo, hi
    70      end of event without a note (terminator)
    60..6F  ornament n-60          20..5F  skip: n-20+1 rows to the next event
    10..1F  volume n-10            0F      delay -> byte
    0E      gliss -> signed step   0D      portamento -> step, then 2 ignored bytes
    0C      stop slide (no PT3 equivalent, dropped)
    00..0B  noise -> byte (per channel in PT2; becomes the row's noise here)
    a 00 where channel A's next event should start ends the pattern

Sample line (3 bytes b0 b1 b2) -> PT3 line, exactly as PTxPlay's SamCnv:
    PT3 b0 = (b0 >> 2) & $3E if noise is on (b0 bit0 = 0) else 0   (envelope bit stays 0 = on)
    PT3 b1 = b0.bit0 << 7 | b0.bit1 << 4 | b1 >> 4                 (noise off, tone off, volume)
    tone   = (b1 & $0F) << 8 | b2, negated unless b0 bit2 is set   (16-bit two's complement)

Output layout (the on-machine converter builds the same):
    header 201 B (from the new-song template; version '5', tone table 1, name),
    positions (pattern*3, $FF), pattern table, samples (shared PT2 pointers stay
    shared), ornaments (an empty ornament 0 if PT2 had none), pattern streams
    A,B,C per pattern in canonical form.

Usage: pt2conv.py in.pt2 out.pt3 [--template build/v2/template.bin]
"""
import pathlib, re, struct, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pt3codec as C

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "build/v2/template.bin"


def default_template():
    """The new-song template (asm/v2/template.inc): build/v2/template.bin if one
    is lying around, else the bytes template_pt3..template_end straight out of
    build/v2/tracker2.bin (located through the .sym) -- so a fresh checkout only
    needs `make tracker2`."""
    if TEMPLATE.exists(): return TEMPLATE.read_bytes()
    S = {m.group(1): int(m.group(2), 16) for m in
         re.finditer(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]+)", (ROOT / "build/v2/tracker2.sym").read_text(), re.M)}
    code = (ROOT / "build/v2/tracker2.bin").read_bytes()
    return code[S["template_pt3"] - 0x8000:S["template_end"] - 0x8000]


class PT2:
    def __init__(self, data):
        d = self.d = bytes(data)
        self.delay, self.num_pos, self.loop = d[0], d[1], d[2]
        self.sample_ptrs = [struct.unpack_from("<H", d, 3 + 2 * i)[0] for i in range(32)]
        self.orn_ptrs = [struct.unpack_from("<H", d, 67 + 2 * i)[0] for i in range(16)]
        self.pat_table = struct.unpack_from("<H", d, 99)[0]
        self.name = d[101:131]
        self.positions = list(d[131:131 + self.num_pos])
        self.num_pats = max(self.positions) + 1 if self.positions else 1

    def streams(self, pat):
        return [struct.unpack_from("<H", self.d, self.pat_table + pat * 6 + 2 * ch)[0] for ch in range(3)]


def is_pt2(d):
    """Heuristic: no PT3 signature, sane header, position list closed by $FF."""
    if d[:13] == b"ProTracker 3." or d[:14] == b"Vortex Tracker": return False
    if len(d) < 140 or d[1] == 0 or d[2] >= d[1]: return False
    pt = struct.unpack_from("<H", d, 99)[0]
    if pt < 131 + d[1] + 1 or pt >= len(d): return False
    return d[131 + d[1]] == 0xFF


# ---------------------------------------------------------------------------
# pattern decode: PT2 streams -> pt3codec Pattern (the same model the editor uses)
# ---------------------------------------------------------------------------
def decode_pattern(song, pat, warn=None):
    d = song.d
    warn = warn if warn is not None else []
    p = C.Pattern()
    pos = song.streams(pat)
    skip = [1, 1, 1]           # rows until the next decode ("NNtSkp"): row 0 decodes
    count = [1, 1, 1]
    length = 64
    for row in range(64):
        r = p.rows[row]
        for ch in range(3):
            count[ch] -= 1
            if count[ch]: continue
            if ch == 0 and d[pos[0]] == 0x00:
                length = row; break
            cell = r.cells[ch]
            q = pos[ch]
            while True:
                c = d[q]; q += 1
                if c >= 0xE1: cell.sample = c - 0xE0
                elif c == 0xE0: cell.note = C.NOTE_REST; break
                elif c >= 0x80: cell.note = c - 0x80; break
                elif c == 0x7F: cell.env = C.ENV_OFF
                elif c >= 0x71:
                    cell.env = c - 0x70
                    per = d[q] | (d[q + 1] << 8); q += 2
                    if r.envper and r.envper != per: warn.append(f"pat {pat} row {row}: two envelope periods")
                    r.envper = per
                elif c == 0x70:
                    if cell.note == C.NOTE_NONE: cell.note = C.NOTE_EMPTY
                    break
                elif c >= 0x60: cell.orn = c - 0x60
                elif c >= 0x20: skip[ch] = c - 0x20 + 1
                elif c >= 0x10:
                    v = c - 0x10
                    if v == 0: warn.append(f"pat {pat} row {row} ch {ch}: volume 0 -> 1"); v = 1
                    cell.vol = v
                elif c == 0x0F: cell.cmd, cell.params = 9, [d[q], 0, 0]; q += 1
                elif c == 0x0E:
                    s = d[q]; q += 1
                    cell.cmd, cell.params = 1, [1, s, 0xFF if s & 0x80 else 0]
                elif c == 0x0D:
                    s = d[q]; q += 3
                    cell.cmd, cell.params = 2, [1, s, 0]
                elif c == 0x0C: warn.append(f"pat {pat} row {row} ch {ch}: stop-slide dropped")
                else:
                    n = d[q] & 0x1F; q += 1
                    if r.noise is not None and r.noise != n: warn.append(f"pat {pat} row {row}: two noise values")
                    r.noise = n
            if cell.note == C.NOTE_NONE and cell.has_fields(): cell.note = C.NOTE_EMPTY
            pos[ch] = q
            count[ch] = skip[ch]
        else:
            continue
        break
    p.length = length
    for row in range(length, 64):
        p.rows[row] = C.Row()
    return p


# ---------------------------------------------------------------------------
# instruments
# ---------------------------------------------------------------------------
def convert_sample(d, ptr):
    length, loop = d[ptr], d[ptr + 1]
    out = bytearray([loop, length])
    for i in range(length):
        b0, b1, b2 = d[ptr + 2 + 3 * i: ptr + 5 + 3 * i]
        tone = ((b1 & 0x0F) << 8) | b2
        if not (b0 & 0x04): tone = (-tone) & 0xFFFF
        p0 = ((b0 >> 2) & 0x3E) if not (b0 & 0x01) else 0
        p1 = ((b0 & 0x01) << 7) | ((b0 & 0x02) << 3) | (b1 >> 4)
        out += bytes([p0, p1, tone & 0xFF, tone >> 8])
    return bytes(out)


def convert_ornament(d, ptr):
    length, loop = d[ptr], d[ptr + 1]
    return bytes([loop, length]) + bytes(d[ptr + 2: ptr + 2 + length])


# ---------------------------------------------------------------------------
# whole song
# ---------------------------------------------------------------------------
def convert(pt2_bytes, template=None, warn=None):
    warn = warn if warn is not None else []
    song = PT2(pt2_bytes)
    tpl = bytes(template if template is not None else default_template())
    hdr = bytearray(tpl[:201])
    hdr[13] = ord("5")                         # PT3 v3.5: PTxPlay's PT2 portamento behaviour
    hdr[30:62] = (song.name + b"  ")[:32]
    hdr[66:99] = b" " * 33
    hdr[99] = 1                                # tone table 1, as PTxPlay uses for PT2
    hdr[100], hdr[101], hdr[102] = song.delay, song.num_pos, song.loop
    out = bytearray(hdr)
    out += bytes(p * 3 for p in song.positions) + b"\xFF"
    patptr = 201 + song.num_pos + 1
    struct.pack_into("<H", out, 103, patptr)
    table_at = len(out)
    out += b"\0" * (6 * song.num_pats)
    # samples: keep sharing (PT2 pointer -> PT3 offset)
    placed = {}
    for i, ptr in enumerate(song.sample_ptrs):
        if not ptr:
            struct.pack_into("<H", out, 105 + 2 * i, 0); continue      # unused: not the template's placeholder
        if ptr not in placed:
            placed[ptr] = len(out); out += convert_sample(song.d, ptr)
        struct.pack_into("<H", out, 105 + 2 * i, placed[ptr])
    placed = {}
    for i, ptr in enumerate(song.orn_ptrs):
        if not ptr:
            if i == 0:                         # PT3 needs an ornament 0
                struct.pack_into("<H", out, 169, len(out)); out += b"\0\1\0"
            else:
                struct.pack_into("<H", out, 169 + 2 * i, 0)
            continue
        if ptr not in placed:
            placed[ptr] = len(out); out += convert_ornament(song.d, ptr)
        struct.pack_into("<H", out, 169 + 2 * i, placed[ptr])
    for pat in range(song.num_pats):
        pattern = decode_pattern(song, pat, warn)
        for ch, stream in enumerate(C.encode_pattern(pattern)):
            struct.pack_into("<H", out, table_at + pat * 6 + 2 * ch, len(out))
            out += stream
    return bytes(out)


def main():
    args = sys.argv[1:]
    tpl = None
    if "--template" in args:
        i = args.index("--template"); tpl = pathlib.Path(args[i + 1]).read_bytes(); del args[i:i + 2]
    if len(args) != 2: sys.exit(__doc__)
    data = pathlib.Path(args[0]).read_bytes()
    if not is_pt2(data): sys.exit("not a PT2 file (or a PT3 already)")
    warn = []
    out = convert(data, tpl, warn)
    pathlib.Path(args[1]).write_bytes(out)
    song = C.Song(out)
    for p in range(song.num_patterns()): C.decode_pattern(song, p)      # must decode cleanly
    print(f"{args[0]}: {len(data)} B PT2 -> {len(out)} B PT3, {song.num_patterns()} patterns, {song.num_pos} positions")
    for w in warn[:20]: print("  note:", w)
    if len(warn) > 20: print(f"  ... {len(warn) - 20} more")


if __name__ == "__main__":
    main()
