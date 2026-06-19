# Debugging TS2068 fig-FORTH with ZEsarUX (and Fuse)

A practical guide for testing/debugging this project's Z80 code in emulators, written
from hard-won experience. **Read the "Gotchas" section first — two of them cost hours.**

---

## TL;DR / the rules that matter

1. **`read-memory`, `hexdump`, `write-memory-raw` take DECIMAL addresses.**
   `set-register` and breakpoint conditions take HEX (with an `h` suffix). Mixing these
   up silently reads/writes the wrong address and produces nonsense. This is the #1 trap.
2. **ZEsarUX does NOT autostart an LROS dock cartridge; Fuse does.** Use ZEsarUX for
   scripted ZRCP debugging (memory, breakpoints, OCR); use **Fuse as the source of truth**
   for "does the real `.dck` boot and run."
3. **RAM `load-binary` testing hides bank/ROM bugs.** Loading the image into RAM at `$8000`
   bypasses the DOCK chunk mapping and makes the code writable — so chunk-spec errors,
   EXROM bank-switching, and "wrote to ROM" bugs are INVISIBLE in ZEsarUX RAM tests. They
   only showed up running the actual cartridge on Fuse. Verify cartridge-specific behaviour
   on Fuse, not just ZEsarUX RAM.
4. **Drive the interpreter by poking the TIB — but only ONE line per run.** See the
   poke-test recipe below; a *second* poked line will not execute.
5. **Reliable signals:** `get-ocr`, `get-registers`, `hexdump` (decimal), breakpoints.
   **Unreliable here:** `cpu-step` single-stepping (PC often frozen), `send-keys-*`
   (keys sometimes land in the TIB but ENTER won't submit). Don't trust them.

---

## Launching ZEsarUX with the remote protocol (ZRCP)

```bash
pkill -f zesarux; sleep 2
nohup /Applications/zesarux.app/Contents/MacOS/zesarux \
  --machine TS2068 --enable-remoteprotocol --noconfigfile \
  > /tmp/zesarux.log 2>&1 &
sleep 9            # give it time to come up before connecting
echo "get-version" | nc -w 2 localhost 10000   # sanity check (ZRCP on port 10000)
```

Tips:
- **Launch ZEsarUX in its own Bash call, then run your Python/ZRCP script in a separate
  call.** Doing `launch; sleep; python …` in one command is fragile (timing) and long
  commands auto-background through the harness, scrambling output.
- `--noconfigfile` avoids loading saved state/config.
- The verbose startup log (`--verbose 4`) is useful to confirm what got loaded (e.g. it
  prints `Loading 8kb block at Segment 8000H-9FFFH` when a `.dck`'s chunks load).

## A reusable Python ZRCP helper

ZRCP is line-based text over TCP. Responses can be split; drain fully each time.

```python
import socket, time, re
s = socket.socket(); s.connect(('localhost', 10000)); s.settimeout(2)
def drain():
    d = b''
    try:
        while True: d += s.recv(4096)
    except: pass
    return d.decode(errors='replace')
drain()                              # eat the welcome banner
def cmd(c, w=0.5):
    s.sendall((c + '\n').encode()); time.sleep(w); return drain()
```

---

## GOTCHA #1 — decimal vs hex addresses

| Command | Address radix |
|---|---|
| `read-memory ADDR LEN` | **DECIMAL** |
| `hexdump ADDR LEN` | **DECIMAL** |
| `write-memory-raw ADDR HEXBYTES` | **DECIMAL** addr, hex data |
| `set-register PC=8000h` | HEX (`h` suffix) |
| `set-breakpoint N PC=97CDh` | HEX (`h` suffix) |
| `set-breakpoint N MWA>=8000h and MWA<=BFFFh` | HEX |

`hexdump 8000 8` reads address **8000 decimal = $1F40**, not `$8000`. To read `$8000`,
use `hexdump 32768 8`. This single mistake makes every memory inspection lie to you.

Handy decimal conversions for this project:

| Symbol | Hex | Decimal |
|---|---|---|
| Code entry / load addr | `$8000` | 32768 |
| Dictionary / vocab head | `$C000` | 49152 |
| Block buffer (`BUF_START`) | `$F000` | 61440 |
| Param stack top (`PS_TOP`) | `$F600` | 62976 |
| TIB (`TIB_START`) | `$F800` | 63488 |
| USER base (`USER_START`) | `$F9C0` | 63936 |
| U_DP (HERE), +12 | `$F9CC` | 63948 |
| U_BLK, +16 | `$F9D0` | 63952 |
| U_IN (>IN), +18 | `$F9D2` | 63954 |
| U_BASE, +32 | `$F9E0` | 63968 |
| U_RS_PTR (return stk), +44 | `$F9EC` | 63980 |
| LAST_K sysvar | `$5C08` | 23560 |
| Scratch page (`SCRATCH_START`) | `$FA00` | 64000 |

Get build-specific label addresses from the symbol file (these are HEX):
```bash
grep -iE '^(_DO_INTERPRET|FORTH_DODOES|CREATE_CODE|_DICT_SEARCH):' build/forth.sym
```

---

## Loading and running the image (RAM smoke test)

This loads the raw binary into RAM and jumps to it. Fast, but see GOTCHA about masking
bank/ROM bugs.

```python
cmd('load-binary /abs/path/build/forth.bin 32768 0')  # 32768 = $8000, len 0 = whole file
cmd('set-register PC=8000h')                            # CART_ENTRY
cmd('run'); time.sleep(2.0)
```
After boot you should see the banner; confirm with screen capture or `get-ocr`.

---

## Looking at the screen

`sips` cannot read ZEsarUX's BMP variant, and `save-screen *.png` produced nothing here.
Two things that DO work:

### A. `get-ocr` — screen text (best for quick checks)
```python
for l in cmd('get-ocr', 1.0).splitlines():
    if l.strip(): print(repr(l.rstrip()))
```

### B. Render the raw Spectrum screen (`.scr`) to PNG
```python
cmd('save-screen /tmp/s.scr')   # 6912-byte raw Spectrum screen
```
```python
# scr2png.py  —  run:  python3 scr2png.py /tmp/s.scr /tmp/s.png
import sys; from PIL import Image
scr = open(sys.argv[1],'rb').read()
img = Image.new('1',(256,192),1); px = img.load()
for y in range(192):
    addr = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2)
    for xb in range(32):
        b = scr[addr+xb]
        for bit in range(8):
            if b & (0x80>>bit): px[xb*8+bit, y] = 0
img.resize((512,384)).save(sys.argv[2])
```
Then `Read` the PNG. (Spectrum bitmap layout is interleaved — that addressing formula is
the whole trick.)

---

## Driving the Forth interpreter WITHOUT a keyboard (the poke-test)

The keyboard path is hard to drive over ZRCP (see send-keys notes). Instead, write a line
straight into the TIB and jump into the machine-code outer interpreter `_DO_INTERPRET`.

```python
DOI = '81C6'   # grep _DO_INTERPRET from build/forth.sym (hex), changes per build
def line(text):
    h = ''.join('%02X' % ord(c) for c in text) + '00'   # ASCII + null terminator
    cmd('write-memory-raw 63488 ' + h)        # TIB  = $F800
    cmd('write-memory-raw 63952 00000000')    # U_BLK=0 (63952) and U_IN=0 (63954)
    cmd('write-memory-raw 63980 00F8')        # U_RS_PTR = $F800 (RS_TOP) — reset return stk
    cmd('set-register SP=F600h')              # param stack top
    cmd('set-register PC=' + DOI + 'h')
    cmd('exit-cpu-step'); cmd('run', 1.5); cmd('enter-cpu-step')
```
Boot first (`PC=8000h; run; sleep 2; enter-cpu-step`), then call `line(...)`, then read the
screen with `get-ocr`. Output (`.`, `."`, the ` ok` prompt) appears on screen.

### GOTCHA #2 — the poke-test runs only ONE line
A *second* `line(...)` after the first will NOT execute — after the first line finishes,
the CPU sits in `_DO_QUERY`'s `halt` and re-entering `_DO_INTERPRET` from there misbehaves.
**Symptom:** the first line works, the second silently does nothing (no second ` ok`).
This wasted hours chasing a non-existent `DOES>` bug.

**Fix: put the whole multi-step test on ONE line.** Compile-and-use on one line is fine —
the interpreter switches STATE as it scans:
```python
line(': K CREATE , DOES> @ ; 5 K FIVE FIVE .')   # prints 5
line('VARIABLE V  42 V !  V @ .')                 # prints 42
line(': SQ DUP * ; 7 SQ .')                        # prints 49
```
Quote characters (`"`) are painful to pass through bash→python→ZRCP; build them with
`chr(34)` in Python rather than escaping.

---

## Breakpoints (reliable) and single-stepping (not)

```python
cmd('clear-membreakpoints'); cmd('enable-breakpoints')
cmd('set-breakpoint 1 PC=97CDh')                  # stop when PC hits CREATE_CODE
cmd('set-breakpoint 2 MWA>=8000h and MWA<=BFFFh') # stop on any WRITE into $8000-$BFFF
# ... run ..., then:
m = re.search(r'PC=([0-9a-f]+)', cmd('get-registers'))
```
- `MWA` = memory-write-address; great for proving **ROM-safety**: arm a write-breakpoint
  over the ROM window (`$8000-$BFFF`) and run a session — it must NEVER fire.
- Breakpoint quirk: calling `run` while PC is *already on* a breakpoint can re-report the
  same hit. Step off it first if needed.
- **`cpu-step` single-stepping was unreliable in this setup** (PC stayed frozen across
  steps). Prefer breakpoints + `get-registers` + `hexdump` to observe state, and `get-ocr`
  for results.

---

## Why you also need Fuse (the LROS oracle)

ZEsarUX loads a `.dck`'s chunks into dock memory (`smartload file.dck`) but does **not**
emulate the TS2068 EXROM's LROS autostart scan, so it boots to BASIC, not the cartridge.
**Fuse autostarts the LROS** and is the real test for the shipped `.dck`.

Three bugs this session were INVISIBLE to ZEsarUX RAM tests and only caught on Fuse:
- **Chunk-spec wrong** (`$EF` mapped only chunk 4, so half the dictionary was unmapped) —
  RAM tests load the full 16K as RAM, so the chunk mapping is never exercised.
- **EXROM tape bank-switch** rebooting — depends on real DOCK/EXROM banking.
- (Keyboard-input quirks likewise differ between emulators.)

Lesson: prove logic in ZEsarUX (scriptable), but **confirm cartridge/bank/ROM behaviour by
having the user run the `.dck` on Fuse**, and trust their report over a green RAM test.

To at least sanity-map a `.dck` into ZEsarUX manually (it won't autostart): the OS would
set HSR via `OUT ($F4)` and jump to the entry — but `OUT`-from-cartridge banking is exactly
what's fiddly, so don't over-invest here; use Fuse.

---

## Quick reference — ZRCP commands used most

| Command | Purpose |
|---|---|
| `get-version` | connectivity check |
| `load-binary FILE ADDR LEN` | load raw bytes (ADDR decimal; LEN 0 = all) |
| `set-register PC=8000h` / `SP=F600h` | set registers (hex) |
| `get-registers` | dump CPU registers |
| `run` / `enter-cpu-step` / `exit-cpu-step` | run / pause / resume |
| `hexdump ADDR LEN` | formatted hex+ascii (ADDR **decimal**) |
| `read-memory ADDR LEN` | raw hex (ADDR **decimal**) |
| `write-memory-raw ADDR HEX` | poke bytes (ADDR **decimal**) |
| `get-ocr` | OCR the screen to text |
| `save-screen FILE.scr` | raw 6912-byte screen (render with scr2png.py) |
| `set-breakpoint N COND` / `clear-membreakpoints` / `enable-breakpoints` | breakpoints (hex) |
| `smartload FILE` | load tape/dck/etc by type |
| `hard-reset-cpu` | reset |

---

## Build & artifacts (context)

```
make        # build/forth.bin + forth.dck (cartridge) + forth.tap
make dck    # just the .dck
make verify # sanity checks (uses build/forth.sym; BASE = $8000)
```
- `build/forth.bin` is ORG'd at `$8000`; load it into RAM at 32768 for smoke tests.
- `build/forth.dck` is the autostarting LROS cartridge — test on Fuse.
- The banner prints a version string (`TS2068 fig-FORTH  vX.Y`); bump it when handing a
  new build to the user so they can confirm they're running the latest.
```
