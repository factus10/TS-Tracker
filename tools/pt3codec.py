#!/usr/bin/env python3
"""PT3 pattern codec -- the host-side REFERENCE for TS Tracker v2's Z80 codec.

The grammar is transcribed from PTxPlay's PT3 pattern decoder (PD_LP2 dispatch
in vendor/PTxPlay/PTxPlay.asm) so it matches what the player actually does:

    byte        meaning
    00          end of pattern (checked on channel A when its skip expires)
    01..0F      special command; handler runs AFTER the row terminator and
                reads its parameters from the stream then (1 gliss=3 B,
                2 portamento=5 B (2 are an ignored precalc delta), 3 smp-pos=1,
                4 orn-pos=1, 5 vibrato=2, 8 env-slide=3, 9 delay=1, others 0)
    10          sample: next byte >>1, envelope OFF
    11..1F      envelope shape (n-10) + period (hi,lo), then sample byte >>1
    20..3F      noise base (n-20), chip-global
    40..4F      ornament (n-40)
    50..AF      NOTE (n-50)          -- row terminator
    B0          envelope off
    B1 nn       skip: rows between decodes (1 = every row)
    B2..BF      envelope shape (n-B1) + period (hi,lo)
    C0          RELEASE              -- row terminator
    C1..CF      volume (n-C0)
    D0          empty event          -- row terminator (no new note)
    D1..EF      sample (n-D0), envelope unchanged
    F0..FF      ornament (n-F0) + sample byte >>1, envelope OFF

Model (mirrors the Z80 working-pattern buffer, 24 bytes per row, 64 rows):
    row: envper (16-bit, 0 = unset), noise (None = unset, else 0..31)
    cell: note (0..95 | REST | EMPTY | NONE), sample (0 = unset, 1..31),
          env (0 unset, 1..14 shape, 15 off), orn (None unset, 0..15),
          vol (0 unset, 1..15), cmd (0 none, 1..15), params (3 bytes)

Usage:
    pt3codec.py info      <song.pt3|tap:NAME>
    pt3codec.py dump      <song> <pattern>            # screen-style listing
    pt3codec.py roundtrip <song>                      # decode->encode->decode == ?
    pt3codec.py model     <song> <pattern> <out.bin>  # 1536-byte working buffer
    pt3codec.py streams   <song> <pattern> <out.bin>  # canonical A,B,C streams
"""
import struct, sys, pathlib

NOTE_NONE, NOTE_REST, NOTE_EMPTY = 0xFF, 0xFE, 0xFD
ENV_OFF = 15
ROWS = 64
CELL_SIZE, ROW_SIZE = 7, 24
PARAM_COUNT = {1: 3, 2: 5, 3: 1, 4: 1, 5: 2, 8: 3, 9: 1}
NOTE_NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
BASE32 = "0123456789ABCDEFGHIJKLMNOPQRSTUV"


class Cell:
    __slots__ = ("note", "sample", "env", "orn", "vol", "cmd", "params")

    def __init__(self):
        self.note, self.sample, self.env, self.orn = NOTE_NONE, 0, 0, None
        self.vol, self.cmd, self.params = 0, 0, [0, 0, 0]

    def has_fields(self):
        return self.sample or self.env or self.orn is not None or self.vol or self.cmd

    def key(self):
        return (self.note, self.sample, self.env, self.orn, self.vol, self.cmd, tuple(self.params))

    def to_bytes(self):
        b1 = self.sample | (0x20 if self.orn is not None else 0)
        b2 = (self.env << 4) | (self.orn or 0)
        b3 = (self.vol << 4) | self.cmd
        return bytes([self.note, b1, b2, b3] + self.params)

    @classmethod
    def from_bytes(cls, b):
        c = cls()
        c.note = b[0]
        c.sample = b[1] & 0x1F
        c.orn = (b[2] & 0x0F) if (b[1] & 0x20) else None
        c.env = b[2] >> 4
        c.vol, c.cmd = b[3] >> 4, b[3] & 0x0F
        c.params = list(b[4:7])
        return c


class Row:
    __slots__ = ("envper", "noise", "cells")

    def __init__(self):
        self.envper, self.noise, self.cells = 0, None, [Cell(), Cell(), Cell()]

    def key(self):
        return (self.envper, self.noise, tuple(c.key() for c in self.cells))

    def to_bytes(self):
        out = bytes([self.envper >> 8, self.envper & 0xFF, 0xFF if self.noise is None else self.noise])
        for c in self.cells:
            out += c.to_bytes()
        return out

    @classmethod
    def from_bytes(cls, b):
        r = cls()
        r.envper = (b[0] << 8) | b[1]
        r.noise = None if b[2] == 0xFF else b[2]
        r.cells = [Cell.from_bytes(b[3 + i * CELL_SIZE: 3 + (i + 1) * CELL_SIZE]) for i in range(3)]
        return r


class Pattern:
    def __init__(self, length=ROWS):
        self.length = length
        self.rows = [Row() for _ in range(ROWS)]
        self.warnings = []

    def key(self):
        return (self.length, tuple(r.key() for r in self.rows))

    def to_bytes(self):
        return b"".join(r.to_bytes() for r in self.rows)

    @classmethod
    def from_bytes(cls, b, length):
        p = cls(length)
        p.rows = [Row.from_bytes(b[i * ROW_SIZE:(i + 1) * ROW_SIZE]) for i in range(ROWS)]
        return p


# ---------------------------------------------------------------------------
# Song container
# ---------------------------------------------------------------------------
class Song:
    def __init__(self, data):
        self.data = bytearray(data)

    @property
    def speed(self): return self.data[100]
    @property
    def num_pos(self): return self.data[101]
    @property
    def loop_pos(self): return self.data[102]
    @property
    def pat_table(self): return self.data[103] | (self.data[104] << 8)

    def positions(self):
        return [b // 3 for b in self.data[201:201 + self.num_pos]]

    def num_patterns(self):
        return max(self.positions()) + 1 if self.num_pos else 0

    def stream_offset(self, pat, ch):
        e = self.pat_table + pat * 6 + ch * 2
        return self.data[e] | (self.data[e + 1] << 8)

    def sample_ptrs(self):
        return [self.data[105 + i * 2] | (self.data[106 + i * 2] << 8) for i in range(32)]

    def ornament_ptrs(self):
        return [self.data[169 + i * 2] | (self.data[170 + i * 2] << 8) for i in range(16)]


# ---------------------------------------------------------------------------
# Decoder -- one channel stream, PTxPlay semantics
# ---------------------------------------------------------------------------
class ChanState:
    def __init__(self, data, off):
        self.data, self.p = data, off
        self.skip = 0            # NNtSkp: PTxPlay INIT zeroes it; streams set B1 before
        self.count = 1           # NtSkCn: INIT = 1, so row 0 always decodes
        self.ended = False


def decode_event(st, row, rowidx, warn):
    """Decode one event (up to and including the terminator + command params).
    Returns None at end-of-pattern (0x00), else the Cell. Row-global effects
    (noise, envelope period) are applied to `row`."""
    d = st.data
    cell = Cell()
    cmds = []
    while True:
        c = d[st.p]; st.p += 1
        if c == 0x00:
            return None
        if c >= 0xF0:                                   # OrSm
            cell.orn = c - 0xF0
            cell.env = ENV_OFF
            s = d[st.p] >> 1; st.p += 1
            cell.sample = s
            if s == 0: warn.append(f"row {rowidx}: explicit sample 0")
        elif c == 0xD0:                                 # empty terminator
            cell.note = NOTE_EMPTY
            break
        elif c >= 0xD1:                                 # sample, env unchanged
            cell.sample = c - 0xD0
        elif c == 0xC0:                                 # release
            cell.note = NOTE_REST
            break
        elif c >= 0xC1:                                 # volume
            cell.vol = c - 0xC0
        elif c == 0xB0:                                 # env off
            cell.env = ENV_OFF
        elif c == 0xB1:                                 # skip
            st.skip = d[st.p]; st.p += 1
        elif c >= 0xB2:                                 # env shape + period
            cell.env = c - 0xB1
            per = (d[st.p] << 8) | d[st.p + 1]; st.p += 2
            cell_envper(cell, row, per, warn)
        elif c >= 0x50:                                 # note
            cell.note = c - 0x50
            break
        elif c >= 0x40:                                 # ornament
            cell.orn = c - 0x40
        elif c >= 0x20:                                 # noise base (global)
            cell_noise(row, c - 0x20, warn)
        elif c >= 0x10:                                 # ESAM
            sh = c - 0x10
            if sh:
                cell.env = sh
                per = (d[st.p] << 8) | d[st.p + 1]; st.p += 2
                cell_envper(cell, row, per, warn)
            else:
                cell.env = ENV_OFF
            s = d[st.p] >> 1; st.p += 1
            cell.sample = s
            if s == 0: warn.append(f"row {rowidx}: explicit sample 0")
        else:                                           # 01..0F special command
            cmds.append(c)
    # terminator reached: commands' parameters follow, LAST pushed runs first
    if len(cmds) > 1:
        warn.append(f"row {rowidx}: {len(cmds)} commands on one event, keeping the last")
    for c in reversed(cmds):
        n = PARAM_COUNT.get(c, 0)
        raw = list(d[st.p:st.p + n]); st.p += n
        if c == cmds[-1]:
            cell.cmd = c
            if c == 2:            # portamento: drop the 2-byte precalc delta
                raw = [raw[0], raw[3], raw[4]]
            cell.params = (raw + [0, 0, 0])[:3]
    return cell


def cell_envper(cell, row, per, warn):
    row.envper = per


def cell_noise(row, n, warn):
    row.noise = n


def decode_pattern(song, pat):
    """Decode pattern `pat` into a Pattern (length from channel A)."""
    p = Pattern()
    warn = p.warnings
    st = [ChanState(song.data, song.stream_offset(pat, ch)) for ch in range(3)]
    length = ROWS
    for row in range(ROWS):
        r = p.rows[row]
        # channel A first: it decides the pattern length
        st[0].count -= 1
        if st[0].count == 0 and not st[0].ended:
            cell = decode_event(st[0], r, row, warn)
            if cell is None:
                length = row
                break
            r.cells[0] = cell
            st[0].count = st[0].skip
            if st[0].skip == 0:
                warn.append(f"row {row}: channel A event without skip set (stalls)")
                st[0].ended = True
        for ch in (1, 2):
            s = st[ch]
            if s.ended: continue
            s.count -= 1
            if s.count == 0:
                cell = decode_event(s, r, row, warn)
                if cell is None:
                    s.ended = True
                    warn.append(f"channel {'BC'[ch-1]} ended at row {row} before channel A")
                    continue
                r.cells[ch] = cell
                s.count = s.skip
    p.length = length
    if length == 0:
        warn.append("zero-length pattern")
    # rows >= length are blank by construction
    for row in range(length, ROWS):
        p.rows[row] = Row()
    return p


def stream_end(data, off):
    """Offset just past the 0x00 that ends the stream at `off` (grammar-aware)."""
    class _R: pass
    st = ChanState(data, off)
    row = _R(); row.envper = 0; row.noise = None
    while True:
        if decode_event(st, row, 0, []) is None:
            return st.p


# ---------------------------------------------------------------------------
# Canonical encoder
# ---------------------------------------------------------------------------
def encode_pattern(pat):
    """Return [streamA, streamB, streamC] (each ends with 0x00)."""
    L = pat.length
    # decide which channel carries each row's global noise / env period
    noise_carrier = [None] * L
    env_carrier = [None] * L
    for row in range(L):
        r = pat.rows[row]
        if r.noise is not None:
            for ch in range(3):
                c = r.cells[ch]
                if c.note != NOTE_NONE or c.has_fields():
                    noise_carrier[row] = ch; break
            else:
                noise_carrier[row] = 0            # synthesise an empty event on A
        if r.envper:
            for ch in range(3):
                if r.cells[ch].env not in (0, ENV_OFF):
                    env_carrier[row] = ch; break
    out = []
    for ch in range(3):
        rows_with_event = []
        for row in range(L):
            c = pat.rows[row].cells[ch]
            if c.note != NOTE_NONE or c.has_fields() or noise_carrier[row] == ch:
                rows_with_event.append(row)
        s = bytearray()
        cur_skip = 0                          # unknown/inherited: first event always sets B1
        if not rows_with_event or rows_with_event[0] != 0:
            # leading gap: an empty event at row 0 skipping to the first event / end
            first = rows_with_event[0] if rows_with_event else L
            if first != cur_skip:
                s += bytes([0xB1, first]); cur_skip = first
            s.append(0xD0)
        for i, row in enumerate(rows_with_event):
            r = pat.rows[row]
            c = r.cells[ch]
            nxt = rows_with_event[i + 1] if i + 1 < len(rows_with_event) else L
            # --- ornament / sample / envelope group
            if c.env == ENV_OFF:
                if c.sample:
                    if c.orn is not None:
                        s += bytes([0xF0 + c.orn, c.sample << 1])
                    else:
                        s += bytes([0x10, c.sample << 1])
                else:
                    if c.orn is not None: s.append(0x40 + c.orn)
                    s.append(0xB0)
            elif c.env:
                if c.orn is not None: s.append(0x40 + c.orn)
                # every channel with a shape carries the row's period: the player
                # applies them A,B,C and keeps the last, so all-equal is lossless
                per = r.envper
                if c.sample:
                    s += bytes([0x10 + c.env, per >> 8, per & 0xFF, c.sample << 1])
                else:
                    s += bytes([0xB1 + c.env, per >> 8, per & 0xFF])
            else:
                if c.orn is not None: s.append(0x40 + c.orn)
                if c.sample: s.append(0xD0 + c.sample)
            # --- volume
            if c.vol: s.append(0xC0 + c.vol)
            # --- noise (row-global, one carrier)
            if noise_carrier[row] == ch: s.append(0x20 + r.noise)
            # --- command byte (params after the terminator)
            if c.cmd: s.append(c.cmd)
            # --- skip
            need = nxt - row
            if need != cur_skip:
                s += bytes([0xB1, need]); cur_skip = need
            # --- terminator
            if c.note == NOTE_REST: s.append(0xC0)
            elif c.note == NOTE_EMPTY or c.note == NOTE_NONE: s.append(0xD0)
            else: s.append(0x50 + c.note)
            # --- command parameters
            if c.cmd:
                n = PARAM_COUNT.get(c.cmd, 0)
                p = c.params
                if c.cmd == 2:
                    s += bytes([p[0], 0, 0, p[1], p[2]])
                elif n:
                    s += bytes(p[:n])
        s.append(0x00)
        out.append(bytes(s))
    return out


def decode_streams(streams, length_hint=ROWS):
    """Decode three standalone streams (as produced by encode_pattern)."""
    data = bytearray()
    offs = []
    for s in streams:
        offs.append(len(data)); data += s
    # fake a song around them: build a minimal header with one pattern
    fake = bytearray(300) + data
    tbl = 230
    fake[103], fake[104] = tbl & 0xFF, tbl >> 8
    fake[101] = 1; fake[201] = 0; fake[202] = 0xFF
    for ch in range(3):
        o = 300 + offs[ch]
        fake[tbl + ch * 2], fake[tbl + ch * 2 + 1] = o & 0xFF, o >> 8
    return decode_pattern(Song(fake), 0)


# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
def note_str(n):
    if n == NOTE_NONE: return "---"
    if n == NOTE_REST: return "R--"
    if n == NOTE_EMPTY: return "---"
    return NOTE_NAMES[n % 12] + str(n // 12 + 1)


def cell_str(c):
    smp = BASE32[c.sample] if c.sample else "."
    env = "." if c.env == 0 else ("0" if c.env == ENV_OFF else "%X" % c.env)
    orn = "." if c.orn is None else "%X" % c.orn
    vol = "." if c.vol == 0 else "%X" % c.vol
    cmd = "." if c.cmd == 0 else "%X" % c.cmd
    return f"{note_str(c.note)} {smp}{env}{orn}{vol}{cmd}"


def dump_pattern(p):
    print(f"length {p.length}")
    for row in range(p.length):
        r = p.rows[row]
        g = f"{r.envper:04X} {'..' if r.noise is None else '%02X' % r.noise}"
        print(f"{row:02d} {g} | " + " | ".join(cell_str(c) for c in r.cells))
    for w in p.warnings: print("  ! " + w)


def load_song(spec):
    """'file.pt3' or 'file.tap:NAME' (CODE block name inside a .tap)."""
    if ".tap:" in spec:
        path, name = spec.rsplit(":", 1)
        b = pathlib.Path(path).read_bytes(); pos = 0; blocks = []
        while pos < len(b):
            n = struct.unpack("<H", b[pos:pos + 2])[0]; pos += 2
            blocks.append(b[pos:pos + n]); pos += n
        for i in range(0, len(blocks) - 1, 2):
            if blocks[i][2:12].decode(errors="replace").strip() == name:
                return Song(blocks[i + 1][1:-1])
        sys.exit(f"no block named {name!r} in {path}")
    return Song(pathlib.Path(spec).read_bytes())


def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    op, spec = sys.argv[1], sys.argv[2]
    song = load_song(spec)
    if op == "info":
        print(f"{spec}: {len(song.data)} B, speed {song.speed}, {song.num_pos} positions, "
              f"loop {song.loop_pos}, {song.num_patterns()} patterns, table @{song.pat_table}")
        for p in range(song.num_patterns()):
            pat = decode_pattern(song, p)
            print(f"  pat {p:2d}: len {pat.length:2d}  streams @ "
                  + ",".join(str(song.stream_offset(p, ch)) for ch in range(3))
                  + (("  ! " + "; ".join(pat.warnings)) if pat.warnings else ""))
    elif op == "dump":
        dump_pattern(decode_pattern(song, int(sys.argv[3])))
    elif op == "roundtrip":
        bad = 0
        for p in range(song.num_patterns()):
            a = decode_pattern(song, p)
            streams = encode_pattern(a)
            b = decode_streams(streams)
            orig = sum(stream_end(song.data, song.stream_offset(p, ch)) - song.stream_offset(p, ch) for ch in range(3))
            ok = a.key() == b.key()
            bad += not ok
            print(f"  pat {p:2d}: {'OK ' if ok else 'FAIL'} orig {orig:4d} B -> canonical {sum(map(len, streams)):4d} B"
                  + (("  ! " + "; ".join(a.warnings)) if a.warnings else ""))
        print("ROUNDTRIP", "PASS" if not bad else f"FAIL ({bad})")
        sys.exit(1 if bad else 0)
    elif op == "model":
        pat = decode_pattern(song, int(sys.argv[3]))
        pathlib.Path(sys.argv[4]).write_bytes(pat.to_bytes())
        print(f"wrote {sys.argv[4]}: {ROWS * ROW_SIZE} B, length {pat.length}")
    elif op == "streams":
        pat = decode_pattern(song, int(sys.argv[3]))
        streams = encode_pattern(pat)
        pathlib.Path(sys.argv[4]).write_bytes(b"".join(streams))
        print(f"wrote {sys.argv[4]}: " + "+".join(str(len(s)) for s in streams) + " B")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
