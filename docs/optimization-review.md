# TS Tracker — deep optimization review: more RAM for songs

*Analysis-only review. No source files were modified. Every byte figure below is
**measured** from real z88dk/sjasmplus probe builds (compared against the exact
canonical baseline of 23,181 B), then independently re-built by an adversarial
verifier. Estimates that could not be built are explicitly flagged.*

Method: built the tracker with a size map (`zcc … -m`), attributed all 23,181 B
per function/section, then fanned out five probe-building deep-dives (compiler/CRT,
C-code, RAM/model, asm candidates, PTxPlay) plus an adversarial cross-check and a
memory-map synthesis. Probe dirs lived in the gitignored `build/`.

---

## 1. Executive summary

The image is **80 % `tracker.c` and ~20 % CRT/libc overhead**, and the single
biggest fact is that **the tracker uses no C stdio at all** — it prints with a
bare `RST $10` thunk and reads keys with `IN`. The default `crt0` nonetheless
links ~3.5 KB of terminal/console/stdio/heap drivers. Removing that dead weight,
plus a few safe source cleanups and stripping PT2 support from the tracker's
own PTxPlay copy, **nearly doubles the song slot — with no behavioural change.**

### Recommended outcome (CONSERVATIVE — all low-risk, all measured)

| Constant | Today | Recommended | Δ |
|---|---|---|---|
| C image size | 23,181 B (ends `$DA8D`) | **19,311 B** (ends `$CB6F`) | −3,870 |
| `PTX_ORIGIN` | `$DAC0` | **`$CB70`** | −3,920 |
| PTxPlay size (tracker copy) | 2,622 B | **2,275 B** (PT3-only) | −347 |
| `TAPE_SONG_BASE` | `$E500` | **`$D453`** | −4,269 |
| **`SONG_BUDGET`** | **5,632 B** | **≈ 9,901 B** | **+4,269 (+76 %)** |
| Margin over largest song (5,464 B) | 168 B | **≈ 4,437 B** | +4,269 |
| `MAX_PATTERNS` | 14 | 14 | 0 |

This comes entirely from dead-code removal (CRT diet + one dead function + PT2
strip + literal de-dup), needs no codegen change, and keeps the standalone player
untouched.

### Stretch outcome (AGGRESSIVE — adds med-risk, needs a functional test)

Add `--opt-code-size` + a larger register-allocator budget, the remaining
source cleanups, and the PT2 sample-converter strip:
**`SONG_BUDGET` ≈ 10,600 B (+4,996, +88 %)**, margin ≈ 5,160 B.

### What you do *not* get, and why

- **No extra patterns.** `MAX_PATTERNS` stays **14** in every safe scenario. A
  2-byte `cell_t` is *infeasible* (SDCC won't pack the four fields — they need 20
  bits — and refuses sub-`int` bitfield packing; verified by three failed probe
  builds). The only +1-pattern path (relocate the model to `$5CB6`, keep code at
  `$8000`) is mutually exclusive with the slot gain and lands the model in unsafe
  RAM (see below). Every bundled song uses < 14 patterns, so slot bytes are the
  better use of freed RAM.
- **Model relocation (lever #3) is NOT recommended as-is.** Dropping the code
  origin below `$8000` mechanically *would* add ~900 B, but it requires moving the
  decoded model to `$5CB6`, which is the ZX BASIC **channel-data area** that the
  ROM `RST $10` print path dereferences via `CURCHL`. It "builds clean" but was
  never run; the adversarial verifier rates it **high runtime risk** (likely
  screen corruption). Defer pending an emulator test, or only with channel
  relocation. The far larger, safe Area-A win makes this unnecessary.

---

## 2. Where the bytes are (measured size map)

Built `build/mapprobe/tracker-base.map` and attributed every byte in `$8000–$DA8D`
by sorting symbols and diffing addresses (`build/mapprobe/parse_map.py`,
`parse_top.py`). Total attributed = 23,181 B exactly.

### By module

| Module | Bytes | Share |
|---|--:|--:|
| **`tracker.c`** (code 15,935 + rodata 2,308 + bss ~250) | **18,493** | 80 % |
| CRT terminal driver (output 951 + input 860) | 1,811 | 8 % |
| console / stdio / inkey / fcntl / heap / math / arch | ~2,877 | 12 % |

### By section (top)

```
16,763  code_compiler          (compiled C — almost all tracker.c)
 2,308  rodata_compiler        (string literals + empty_pt3 + tables)
   951  code_driver_terminal_output   ┐ the RST-10-style C terminal driver
   860  code_driver_terminal_input    ┘ — DEAD WEIGHT (tracker uses raw RST $10)
   332  code_arch
   253  bss_compiler
   248  data_fcntl_stdio_heap_body     stdio heap — DEAD WEIGHT (no stdio)
   160  in_key_translation_table       inkey table — DEAD WEIGHT (raw IN)
   156  code_fcntl / 155 code_input / 134 code_math …
```

### Top logical functions in `tracker.c` (basic blocks re-aggregated)

```
2845  show_pattern          editor event loop / key dispatch  (poor asm target)
 882  encode_channel        PT3 encoder            [correctness-critical]
 773  se_draw               instrument-editor screen (string-heavy)
 768  show_instr_editor     editor key loop
 698  prompt_save_filename  text-entry UI
 691  decode_channel_row    PT3 decoder            [correctness-critical]
 513  show_song_info        info screen
 507  instr_resize          model edit + rebuild
 443  decode_pattern_streams 3-channel decode driver [crit]
 374  scan_tape    325 main   323 show_help_page   281 rebuild_song
 220  draw_pattern_row   211 put_dec5_right   116 put_note   (asm candidates)
```

### Top rodata items

```
233  empty_pt3 (the baked-in song template)
 40  text_key_chars   33 several ___str_N (help/UI text)
115 string literals total = 1,907 B; SDCC pools NONE of them, but only 9 are duplicated.
```

The headline: the C bulk is **fragmented** (largest function 294 B; no single fat
loop), so hand-asm has limited per-function ROI. The biggest leverage is the
**dead CRT layer**, not the C code.

---

## 3. Ranked opportunity table (by ROI)

`measured` = built and byte-counted. Slot bytes are ~1:1 with each lever
(image-shrink lowers `PTX_ORIGIN`; PTxPlay-shrink lowers `TAPE_SONG_BASE`; the two
**compound**).

| # | Opportunity | Lever | Bytes | Measured | Effort | Risk | Files |
|--:|---|---|--:|:--:|:--:|:--:|---|
| 1 | Drop crt0 driver instantiation (stdin/out/err terminals) | image | **3,145** | ✅ | low | **low** | Makefile, +empty `.m4` |
| 2 | Zero stdio/malloc heaps + exit/close machinery | image | **413** | ✅ | low | **low** | Makefile |
| 3 | Strip PT2/PT1 parser from tracker's PTxPlay copy | ptxplay | **323** | ✅ | med | low | PTxPlay.asm, build tool |
| 4 | `at_puts()` helper for 64 `at()+puts_str()` pairs | image | **144** | ✅ | low | low | tracker.c |
| 5 | Delete dead `load_song_from_tape()` (not auto-stripped) | image | **130** | ✅ | low | low | tracker.c |
| 6 | `put_dec5_right`: subtractive ÷10 (drop 16-bit divides) | image | **94** | ✅ | med | low | tracker.c |
| 7 | `wait_dismiss()` helper for 4 modal triples | image | **78** | ✅ | low | low | tracker.c |
| 8 | De-dup the 9 duplicated string literals | image | **38–80** | ✅ | low | low | tracker.c |
| 9 | `--opt-code-size` + `--max-allocs-per-node 2M` | image | **455** | ⚠️* | low | **med** | Makefile |
| 10 | LoopChecker off in tracker's PTxPlay copy | ptxplay | **24** | ✅ | low | low | build tool |
| 11 | Drop PT2 sample-converter (dead via self-modify) | ptxplay | **39** | ✅ | med | med | PTxPlay.asm |
| 12 | Drop dead `idx` param (draw_pattern_frame chain) | image | ~30 | ❌ | med | low | tracker.c |
| — | Hand-asm pattern-row render cluster | image | ~180 | ❌ | med | med | tracker.c, ts_io.c |
| — | Hand-asm PT3 codec (decode/encode_channel) | image | ~300 | ❌ | high | **high** | tracker.c, pt_engine.c |
| — | Model relocate `$6000→$5CB6` + drop code origin | model | ~900 | ⚠️ | med | **HIGH** | tracker.c, Makefile |
| — | 2-byte `cell_t` | model | **0** | ✅ infeasible | high | high | — |
| — | Shrink `DIR_MAX` 9→5 | image | 70 | ✅ | low | med (UX) | tracker.c |
| — | Custom crt0 | meta | ~0 | ❌ | high | high | — |

\* #9 the verifier could not reproduce the `MA2M` point in time (build too slow);
the −3,558 from #1+#2 reproduced exactly. Treat #9's −455 as plausible but
version-sensitive.

---

## 4. Detailed findings

### A. Compiler / linker / CRT — the cheapest big win (≈3,558 B firm)

**Confirmed and independently reproduced.** `putch` (`src/ts_io.c`) is a
`__naked __z88dk_fastcall` thunk doing `ld a,l / rst $10`; `read_row` is an `IN`
thunk. A grep of all four linked sources finds **zero** `printf/putchar/fopen/
malloc/atexit/in_inkey`. Yet the `+zx -clib=sdcc_iy` crt0 instantiates three file
drivers (stdin=inkey terminal, stdout=`char_32` windowed terminal, stderr=dup)
plus a stdio heap and exit/atexit machinery.

- **A-1 (−3,145 B):** `-pragma-define:CRT_INCLUDE_DRIVER_INSTANTIATION=1` plus an
  **empty** `crt_driver_instantiation.asm.m4` on the m4 include path instantiates
  *no* file descriptors. Map confirms the terminal/input/fcntl sections collapse
  to **zero length** (`__code_driver_terminal_input_head == _tail`). Measured
  23,181 → 20,036.
- **A-2 (−413 B):** `CLIB_STDIO_HEAP_SIZE=0`, `CLIB_MALLOC_HEAP_SIZE=0`,
  `CRT_ENABLE_CLOSE=0`, `CLIB_EXIT_STACK_SIZE=0`. All safe no-ops (no heap/atexit/
  files; `main()` ends in halt). Measured 20,036 → 19,623.
- **A-3 (−455 B, med risk):** `-Cs--opt-code-size` + `--max-allocs-per-node`
  2,000,000. The allocator budget interacts *non-monotonically* with opt-size —
  **do not lower `max-allocs`** (MA2000 → 24,080 B; MA0 → 30,274 B, both worse).
  Reaches 19,168. The verifier flags this as the only Area-A item that changes
  codegen (version-sensitive); functionally test after adopting.

**Boot safety (verified at crt0 source):** SP setup, IM, DI/EI, DATA+BSS init and
the exit/SP-restore path are all *independent* of the driver-instantiation block;
`RST $10` uses ROM (paged in under normal RAM mode). The −3,558 B subset (A-1+A-2)
needs **no compiler-flag change** and is the firm, low-risk floor.

> **Caveat:** with the drivers gone, any future call to a C stdio function would
> crash (no fd structs). Add a one-line comment/guard.

### B. C-code structure & strings (≈480 B, low risk)

Read all 2,629 lines; disassembled with `zcc -S` to ground every claim.

- **B-1 (−144 B):** every UI line is `at(r,c); puts_str(s)` → two arg-setups +
  two CALLs. One shared `at_puts(row,col,s)` helper over 63 clean sites. Measured.
- **B-2 (−130 B):** `load_song_from_tape()` (lines 168–198) has **zero call sites**
  (the live path is `tape_load_one_song` + `load_song_to_edit`) yet SDCC does *not*
  dead-strip it. Deleting it (and its now-orphan statics) is measured at −130.
- **B-3 (−94 B):** `put_dec5_right` does four 16-bit `÷` (`__divuint`) + `%`;
  a subtractive ÷10 loop produces byte-identical output without the call chain.
- **B-4 (−78 B):** 4 verbatim 3-line modal-dismiss `halt`-loops → one `wait_dismiss()`.
- **B-5 (−38…80 B):** only **9** of 115 literals are duplicated (`-- Pattern view --`
  ×3, etc.). SDCC pools none, so promoting each to a shared `const char[]` is a
  clean 1:1 rodata win. *Smaller than the brief expected* — the other 106 literals
  are unique. **Do not** trim the three trailing-space-padded strings: the padding
  is load-bearing (it overwrites longer prior text in place).

None of these touch the PT3 encode/decode/rebuild or tape I/O, so saved songs
still round-trip. Verify with the smoketest tape after combining.

### C. RAM / data structures & the model (lever #3) — mostly a dead end for *safe* gains

- **C-1: a 2-byte `cell_t` is infeasible.** The four fields need note(−2..95 ⇒ 7b)
  + sample(5b) + volume(4b) + ornament(4b) = **20 bits**. Even dropping ornament
  (16 bits), SDCC's z80 backend refuses to pack `unsigned int` bitfields below
  `int` width — three probe builds all asserted `sizeof==3`. Only a manual
  shift/mask `unsigned int` reaches 2 bytes, forcing ornament into a side table
  and rewriting ~12 access sites — high risk to the PT3 round-trip. **Note:** the
  encoder *does* now serialise ornament (lines 981-984), so the comment at
  `tracker.c:895-897` is stale and should be fixed — ornament can no longer be
  dropped "for free".
- **C-2: model relocation + code-origin drop — NOT recommended as-is.** Moving
  `MODEL_BASE` `$6000→$5CB6` lets the code origin drop to ~`$7C40`; a probe built
  clean and ends 697–857 B lower (mechanically this *compounds* with Area A for
  ~+900 slot bytes). **But** `$5CB6` is the ZX BASIC `CHANS` channel-data area that
  every `RST $10` print dereferences via `CURCHL`. It was never *run*; the
  adversarial verifier rates it **high runtime risk** (probable screen
  corruption). The model lives at `$6000` by deliberate design. Defer pending a
  ZEsarUX test (and likely channel relocation). Area A makes it unnecessary.
- **C-3: MAX_PATTERNS.** Stays **14**. The only +1 (to 15) path keeps code at
  `$8000` and relocates the model to `$5CB6` — mutually exclusive with C-2's slot
  gain, lands in the unsafe channel area, and benefits no bundled song.
- **C-4: BSS.** BSS sits atop the image, so a static-buffer shrink lowers the end
  1:1 — but the only buffer with slack is `directory[DIR_MAX=9]` (−70 B at
  `DIR_MAX=4`), a real UX regression (fewer listable tape songs). The big BSS waste
  (stdio heap) is already reclaimed by A-2.

### D. Hand-written Z80 asm candidates (defer)

The fattest function, `show_pattern` (2,845 B, 18 % of all code), is a branchy
key-dispatch loop — a **poor** asm target (bytes are the ~30 branches, not a
loop). The good shapes are:

- **Render cluster** (`draw_pattern_row` + `put_note` + `put_dec5_right` +
  `draw_cell_value`, 656 B of C): call-heavy leaf renderers; hand asm could reach
  ~45–55 %, ~**180 B** net. Pure rendering → no round-trip risk, but touches the
  screen contract (rows ≤ 21, INVERSE/PAPER codes). *Estimate only — not built.*
- **PT3 codec** (`decode_channel_row` + `encode_channel`, 1,573 B): compare-ladder
  + pointer-walk shrinks well (~**300 B**), but it's the **model↔PT3 round-trip
  shared with the player** — a single off-by-one silently corrupts saved songs.
  **High risk; only with a decode→encode→decode regression harness.**

Recommendation: skip asm until the (larger, safer) Area-A/B/E wins are banked.

### E. PTxPlay — strip PT2 from the tracker's PT3-only copy (≈386 B, low/med)

The tracker is **PT3-only** (decode gated on `tape_header[0]==3`; PT2 refused for
edit) and builds its **own** PTxPlay (separate from the player's), so PT2/PT1
support in *its* copy is dead. The player keeps full support. Baseline
reproduced at exactly 2,622 B with all 9 exports.

- **E-1 (−323 B):** gate `INITPT2` (104 B) + the PT2 pattern decoder `PD2_*`
  (212 B) behind a new `PT3Only` switch. sjasmplus Errors:0; `CurPos` still at
  `START+11`. The PT2 dispatch in INIT (`LD A,(START+10) / AND 2 / JR NZ,INITPT2`)
  is never taken — the tracker never sets `START+10` bit 1.
- **E-2 (−39 B, med):** drop the PT2 sample-converter (`SamCnv..e_`) — INIT
  self-modifies it to `JR e_` in PT3 mode, so it's already unreachable. Touches a
  shared `CHREGS` fall-through; verify playback.
- **E-3 (−24 B):** `LoopChecker EQU 0` for the tracker's copy — it never reads
  `SETUP` bit 7 (only `pt3_player.c` does). One-line change.

**Keep `CurPosCounter` (13 B):** `tracker.c:1404` reads `CurPos_ADDR` every frame
for the playhead highlight. Each removed byte lowers `TAPE_SONG_BASE` 1:1.
`ptxplay_addrs.h` auto-regenerates from the `.sym`, so moved symbols stay valid.

### F. The optimal memory map

Image-shrink (lever #1) and PTxPlay-shrink (lever #2) **compound** — both push the
slot floor down. Excluding the unsafe model relocation:

```
                         TODAY            CONSERVATIVE        AGGRESSIVE
$4000–$5AFF  display     (fixed)          (fixed)             (fixed)
$5C00–$5CB5  sysvars     (fixed)          (fixed)             (fixed)
$6000        model       $6000–$7F80      $6000–$7F80         $6000–$7F80   (unchanged)
$8000        C image     $8000–$DA8D      $8000–$CB6F         $8000–$C8B4
             PTX_ORIGIN  $DAC0            $CB70               $C8C0
             PTxPlay     2,622 B          2,275 B             2,236 B
             TAPE_SONG…  $E500            $D453               $D17C
  SONG SLOT              5,632 B          ≈ 9,901 B           ≈ 10,628 B
$FB00        stack/sys   (ceiling)        (ceiling)           (ceiling)
```

`SONG_BUDGET = $FB00 − TAPE_SONG_BASE`. The single largest bundled song is 5,464 B
(margin today: **168 B**; conservative: **~4,437 B**; aggressive: **~5,164 B**).

---

## 5. Recommended phased plan

### Phase 1 — safe, measured, ~+4,269 slot bytes (do this first)

All dead-code removal; no codegen change; player untouched.

1. **A-1 + A-2** — CRT diet (Makefile CFLAGS + empty `.m4`). *−3,558.*
2. **B-2** — delete dead `load_song_from_tape()` and its statics. *−130.*
3. **B-1** — `at_puts()` helper. *−144.*
4. **B-5** — de-dup the 9 duplicated literals. *−38…80.*
5. **E-1 + E-3** — `PT3Only` switch (strip PT2 parser) + `LoopChecker=0` in the
   tracker's PTxPlay build only. *−347.*
6. Lower `PTX_ORIGIN_HEX → ~$CB70` and `TAPE_SONG_BASE_HEX → ~$D453`; rebuild
   PTxPlay at the new origin; let the **overlap guard** validate.
7. **Verify in ZEsarUX:** boot → load a PT3 → edit → save → play back the 5,464 B
   tune. (Confirms the CRT diet boots and the PT3-only PTxPlay still plays.)

### Phase 2 — stretch, +~700 more, med risk (each verified before stacking)

8. **A-3** — `--opt-code-size` + `--max-allocs-per-node 2000000`. *−455, codegen
   change → full load/edit/save/playback regression.*
9. **B-3 / B-4 / B-6** — `put_dec5_right` rewrite, `wait_dismiss()`, drop dead
   `idx`. *~−202.*
10. **E-2** — drop the PT2 sample-converter. *−39; verify playback.*
11. **C-5** — fix the stale ornament comment (`tracker.c:895-897`); 0 bytes but
    prevents a future packing mistake.

### Leave alone

- **C-2 model relocation / code-origin drop** — high runtime risk (`$5CB6` channel
  area); only with an emulator proof + channel relocation, and Area A makes it
  unnecessary.
- **C-1 2-byte cell** — infeasible on this SDCC.
- **D codec / render asm** — defer; the shared save path is high risk for ~300 B.
- **`DIR_MAX` reduction** — real UX regression for 70 B.
- **Custom crt0** — high boot risk for sub-kB unmeasured gain.
- **The player's PTxPlay and `pt3_player.c`** — must keep full PT1/PT2/PT3 +
  `LoopChecker=1`. `PT3Only`/LoopChecker-off apply **only** to the tracker's copy.

---

## Appendix — illustrative diffs (NOT applied; verify before committing)

**A-1/A-2 (Makefile):** add to the tracker's `CFLAGS`, and add an empty
`build/crt_driver_instantiation.asm.m4`:

```make
OPT_TRACKER = -SO3 -O3 --max-allocs-per-node200000 \
  -pragma-define:CRT_INCLUDE_DRIVER_INSTANTIATION=1 -Cm-Ibuild \
  -pragma-define:CLIB_STDIO_HEAP_SIZE=0 -pragma-define:CLIB_MALLOC_HEAP_SIZE=0 \
  -pragma-define:CRT_ENABLE_CLOSE=0 -pragma-define:CLIB_EXIT_STACK_SIZE=0
# (the empty .m4 is REQUIRED — gm4 aborts without it)
```

**B-1 (`tracker.c`), near `put_dec()`:**
```c
static void at_puts(unsigned char row, unsigned char col, const char *s)
{ at(row, col); puts_str(s); }
```
then `at(R,C); puts_str(S);` → `at_puts(R, C, S);` at the 63 clean sites.

**B-2 (`tracker.c`):** delete `load_song_from_tape()` (lines 168–198) and the
orphaned `tape_song_loaded` / `tape_song_fmt` statics.

**E-1/E-3 (`tools/build_ptxplay_asm.py`):** emit `PT3Only EQU 1` and
`LoopChecker EQU 0` in the **tracker's** prelude only (keep `0`/`1` for the player),
and in `vendor/PTxPlay/PTxPlay.asm` wrap `INITPT2` + `PD2_*` and the
`LD A,(START+10)/AND 2/JR NZ,INITPT2` dispatch in `IF !PT3Only … ENDIF`.

---

*Reproduce the size map: `zcc +zx -compiler=sdcc -clib=sdcc_iy -SO3 -O3
--max-allocs-per-node200000 -DTS2068 -Isrc -Ibuild -DTAPE_SONG_BASE=0xE500 -m
-o build/mapprobe/tracker-base src/tracker.c src/ay_ts2068.c src/pt_engine.c
src/ts_io.c -create-app`, then `python3 build/mapprobe/parse_top.py`.*
