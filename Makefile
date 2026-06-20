# =============================================================================
# TS Tracker -- z88dk build
#
# Targets:
#   make pt3-player   Universal PT2/PT3 picker tape (primary build)
#   make smoketest    AY-3-8912 sanity-check tape
#   make pt3-mvp      Single-song MVP (legacy, mvac7 PT3 player)
#   make clean        Remove build outputs
# =============================================================================

Z88DK_HOME ?= $(HOME)/z88dk/z88dk
export ZCCCFG = $(Z88DK_HOME)/lib/config
export PATH := $(Z88DK_HOME)/bin:$(PATH)

# We target +zx (not +ts2068): the +ts2068 clibs are sccz80-only, but the
# upstream PT3 player uses SDCC inline asm. The TS2068 loads Spectrum tapes
# fine, and our AY library targets ports $F5/$F6 directly so the +zx clib's
# Spectrum-128 AY assumptions don't matter.
ZCC      ?= zcc
TARGET   ?= +zx
COMPILER ?= -compiler=sdcc
CLIB     ?= -clib=sdcc_iy
OPT      ?= -SO3 -O3 --max-allocs-per-node200000

# Memory layout (single source of truth). The C binary loads at $8000 and
# extends to whatever the linker gives us. PTxPlay loads just above the
# tracker's tail; the song slot starts immediately above PTxPlay. Bumping
# either constant requires re-running the build; the overlap checks below
# will fail loudly if the C binary outgrows PTX_ORIGIN.
#
# The Phase 1 RAM optimisations (docs/optimization-review.md) shrank the C image
# ~3.5 KB via the CRT diet (TRACKER_CRT, below) + a PT3-only PTxPlay
# (build_ptxplay_asm.py ... 1, 2275 B). That freed ~4 KB which now funds BOTH a
# bigger song slot and the sound-editor overhaul: as new editor code grows the
# image, PTX_ORIGIN/TAPE_SONG_BASE are nudged up (trading song-slot slack, which
# is large -- the largest bundled song is only 5464 B). Currently the image ends
# ~$CCE0; PTX_ORIGIN=CE00 (~290 B guard for in-progress editor work) and -- with
# the 2275 B PTxPlay ending ~$D6E3 -- TAPE_SONG_BASE=D6F0, so SONG_BUDGET =
# $FB00-$D6F0 = ~9232 B (~3.8 KB over the largest song). NB image size is mildly
# sensitive to PTX_ORIGIN (its address feeds the compiled-in ptxplay_addrs.h), so
# the guard is generous; the overlap check below is the backstop. The player is
# decoupled and keeps the original D700/E200 map + full PT1/PT2/PT3 PTxPlay.
PTX_ORIGIN_HEX     ?= CE00
TAPE_SONG_BASE_HEX ?= D6F0
PTX_ORIGIN_DEC     := $(shell printf '%d' 0x$(PTX_ORIGIN_HEX))
TAPE_SONG_BASE_DEC := $(shell printf '%d' 0x$(TAPE_SONG_BASE_HEX))
PLAYER_PTX_ORIGIN_HEX ?= D700
PLAYER_SONG_BASE_HEX  ?= E200
PLAYER_PTX_ORIGIN_DEC := $(shell printf '%d' 0x$(PLAYER_PTX_ORIGIN_HEX))

# TAPE_SONG_BASE is set per-app (player vs tracker), not here, since they differ.
CFLAGS   = $(TARGET) $(COMPILER) $(CLIB) $(OPT) -DTS2068 -Isrc -Ibuild

# Tracker-only CRT diet. The tracker uses NO C stdio -- it prints via a raw
# RST $10 thunk (putch) and reads keys via IN (read_row) -- so the default
# crt0's stdin/stdout/stderr terminal drivers, the stdio/malloc heaps and the
# exit/atexit machinery are all dead weight. Dropping them removes ~3.5 KB from
# the image, which (via the overlap-guarded map below) drops PTX_ORIGIN and
# TAPE_SONG_BASE ~1:1 and grows the song slot. crt/crt_driver_instantiation.asm.m4
# is the empty user driver file that CRT_INCLUDE_DRIVER_INSTANTIATION=1 needs.
# NOTE: with no drivers linked, any C stdio call (printf/putchar/...) would
# crash -- the tracker must keep printing only via putch.
TRACKER_CRT = -pragma-define:CRT_INCLUDE_DRIVER_INSTANTIATION=1 -Cm-Icrt \
              -pragma-define:CLIB_STDIO_HEAP_SIZE=0 -pragma-define:CLIB_MALLOC_HEAP_SIZE=0 \
              -pragma-define:CRT_ENABLE_CLOSE=0 -pragma-define:CLIB_EXIT_STACK_SIZE=0

BUILDDIR = build
SRCDIR   = src

AY_SRCS    = $(SRCDIR)/ay_ts2068.c

# Shared PTxPlay engine (asm thunks + 60->50Hz tempo divider). Both pt3-player
# and tracker link against this; previously each app had byte-identical local
# copies.
ENGINE_SRCS = $(SRCDIR)/pt_engine.c

# Shared screen + keyboard primitives (putch/at/read_row/key_* ...). Both apps
# link this instead of carrying byte-identical copies.
IO_SRCS = $(SRCDIR)/ts_io.c

# Single-song MVP still uses mvac7's C-only PT3 player.
PT3_SRCS   = $(SRCDIR)/PT3player.c $(AY_SRCS)

# Picker bundles every .pt2 / .pt3 in songs/. Songs are split between two
# memory regions at runtime:
#   * "low" group:  embedded as const arrays in the C binary (lives below
#                   PTX_ORIGIN_HEX)
#   * "high" group: separate flat tape block, loaded just above PTxPlay
# The split is greedy by file order; whatever doesn't fit in either cap is
# dropped with a warning at build time.
SONGS_DIR     ?= songs
SONGS         := $(sort $(wildcard $(SONGS_DIR)/*.pt2) $(wildcard $(SONGS_DIR)/*.pt3))
LOW_SONG_CAP  ?= 8192         # 8 KB embedded in main C binary
HIGH_SONG_CAP ?= 14336        # 14 KB above PTxPlay (TAPE_SONG_BASE..~$FB00)
HIGH_SONG_BASE := $(PLAYER_SONG_BASE_HEX)

# Pick which .pt3 to bundle into pt3-mvp.
SONG ?= songs/3BIT - Debugger - SPRLZ4Ev2004.pt3

.PHONY: all smoketest pt3-mvp pt3-player songs-tape tracker release clean

all: smoketest pt3-player songs-tape tracker

# ---- smoketest ---------------------------------------------------------------
smoketest: $(BUILDDIR)/smoketest.tap

$(BUILDDIR)/smoketest.tap: $(SRCDIR)/smoketest.c $(AY_SRCS) $(SRCDIR)/ay_ts2068.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/smoketest.c $(AY_SRCS) \
	    -o $(BUILDDIR)/smoketest \
	    -create-app

# ---- pt3-mvp (legacy, single-song mvac7 PT3 player) -------------------------
pt3-mvp: $(BUILDDIR)/pt3-mvp.tap

$(BUILDDIR)/song.pt3: | $(BUILDDIR)
	cp "$(SONG)" $(BUILDDIR)/song.pt3

$(BUILDDIR)/song.c: $(BUILDDIR)/song.pt3 tools/pt3_to_c.py
	python3 tools/pt3_to_c.py $(BUILDDIR)/song.pt3 $(BUILDDIR)/song.c song

$(BUILDDIR)/pt3-mvp.tap: $(SRCDIR)/pt3_mvp.c $(PT3_SRCS) $(BUILDDIR)/song.c \
                        $(SRCDIR)/ay_ts2068.h $(SRCDIR)/PT3player.h \
                        $(SRCDIR)/PT3player_NoteTable1.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/pt3_mvp.c $(PT3_SRCS) $(BUILDDIR)/song.c \
	    -o $(BUILDDIR)/pt3-mvp \
	    -create-app

# ---- PTxPlay pipeline (universal PT1/PT2/PT3 driver by S.V. Bulba) -----------
# Transform vendor source -> sjasmplus -> flat .bin -> embedded C blob.
# The origin is parameterised so we can pack PTxPlay tighter against the
# C binary's tail, freeing room for the song slot.
# The tracker's copy is built PT3-only (arg 3 = 1): it never plays PT2, so the
# PT2/PT1 init + pattern decoder are compiled out and LoopChecker is turned off,
# shrinking it 2622 -> 2275 B. The player's copy (below) stays full PT1/PT2/PT3.
$(BUILDDIR)/PTxPlay.asm: vendor/PTxPlay/PTxPlay.asm tools/build_ptxplay_asm.py \
                         $(MAKEFILE_LIST) | $(BUILDDIR)
	python3 tools/build_ptxplay_asm.py $(PTX_ORIGIN_HEX) $(BUILDDIR)/PTxPlay.asm 1

$(BUILDDIR)/ptxplay.bin $(BUILDDIR)/ptxplay.sym: $(BUILDDIR)/PTxPlay.asm
	cd $(BUILDDIR) && sjasmplus PTxPlay.asm --raw=ptxplay.bin --sym=ptxplay.sym

$(BUILDDIR)/ptxplay_addrs.h: $(BUILDDIR)/ptxplay.sym tools/bin_to_c.py
	python3 tools/bin_to_c.py $(BUILDDIR)/ptxplay.sym \
	    $(BUILDDIR)/ptxplay_addrs.h START SETUP MUTE INIT PLAY VARSEND AYREGS DelyCnt CurPos

# Player's own PTxPlay at PLAYER_PTX_ORIGIN_HEX, built into build/player/ so it
# keeps the original (larger) song slot independent of the tracker's higher map.
$(BUILDDIR)/player/PTxPlay.asm: vendor/PTxPlay/PTxPlay.asm tools/build_ptxplay_asm.py \
                                $(MAKEFILE_LIST) | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/player
	python3 tools/build_ptxplay_asm.py $(PLAYER_PTX_ORIGIN_HEX) $(BUILDDIR)/player/PTxPlay.asm

$(BUILDDIR)/player/ptxplay.bin $(BUILDDIR)/player/ptxplay.sym: $(BUILDDIR)/player/PTxPlay.asm
	cd $(BUILDDIR)/player && sjasmplus PTxPlay.asm --raw=ptxplay.bin --sym=ptxplay.sym

$(BUILDDIR)/player/ptxplay_addrs.h: $(BUILDDIR)/player/ptxplay.sym tools/bin_to_c.py
	python3 tools/bin_to_c.py $(BUILDDIR)/player/ptxplay.sym \
	    $(BUILDDIR)/player/ptxplay_addrs.h START SETUP MUTE INIT PLAY VARSEND AYREGS DelyCnt CurPos

# ---- pt3-player (universal PT2/PT3 picker) ----------------------------------
pt3-player: $(BUILDDIR)/pt3-player.tap

# Stage every song to no-space filenames so the build never has to quote.
# Stamp re-runs whenever any source song or the bundle tool changes.
$(BUILDDIR)/songs.stamp: $(MAKEFILE_LIST) tools/build_song_bundle.py | $(BUILDDIR)
	@rm -rf $(BUILDDIR)/songs_staged && mkdir -p $(BUILDDIR)/songs_staged
	@i=0; for f in $(SONGS_DIR)/*.pt2 $(SONGS_DIR)/*.pt3; do \
	    [ -f "$$f" ] || continue; \
	    ext=$${f##*.}; \
	    cp "$$f" "$(BUILDDIR)/songs_staged/song_$$(printf '%02d' $$i).$$ext"; \
	    i=$$((i+1)); \
	done
	python3 tools/build_song_bundle.py \
	    $(BUILDDIR)/song_bundle.c $(BUILDDIR)/songs_high.bin \
	    $(HIGH_SONG_BASE) $(LOW_SONG_CAP) $(HIGH_SONG_CAP) \
	    $(BUILDDIR)/songs_staged/*
	@touch $@

$(BUILDDIR)/song_bundle.c $(BUILDDIR)/songs_high.bin: $(BUILDDIR)/songs.stamp ;

$(BUILDDIR)/pt3-player-base.tap: $(SRCDIR)/pt3_player.c $(AY_SRCS) $(ENGINE_SRCS) $(IO_SRCS) \
                                  $(BUILDDIR)/player/ptxplay_addrs.h \
                                  $(SRCDIR)/ay_ts2068.h $(SRCDIR)/pt_engine.h $(SRCDIR)/ts_io.h \
                                  | $(BUILDDIR)
	$(ZCC) -I$(BUILDDIR)/player $(CFLAGS) -DTAPE_SONG_BASE=0x$(PLAYER_SONG_BASE_HEX) \
	    $(SRCDIR)/pt3_player.c $(AY_SRCS) $(ENGINE_SRCS) $(IO_SRCS) \
	    -o $(BUILDDIR)/pt3-player-base \
	    -create-app
	mv $(BUILDDIR)/pt3-player-base.tap $(BUILDDIR)/pt3-player-base.tap.tmp || true
	@if [ -f $(BUILDDIR)/pt3-player-base ]; then \
	    mv $(BUILDDIR)/pt3-player-base $(BUILDDIR)/pt3-player-base.bin || true; \
	fi
	@if [ -f $(BUILDDIR)/pt3-player-base.tap.tmp ]; then \
	    mv $(BUILDDIR)/pt3-player-base.tap.tmp $(BUILDDIR)/pt3-player-base.tap; \
	fi

# Append two extra CODE blocks: PTxPlay (loads at $PTX_ORIGIN_HEX) and the
# high song bundle. Each call to append_code_block.py adds one block and
# inserts a matching `LOAD ""CODE` clause into the BASIC loader, so the
# final tape has three LOAD ""CODE statements running in sequence.
$(BUILDDIR)/pt3-player-stage1.tap: $(BUILDDIR)/pt3-player-base.tap $(BUILDDIR)/player/ptxplay.bin tools/append_code_block.py
	python3 tools/append_code_block.py \
	    $(BUILDDIR)/pt3-player-base.tap \
	    $(BUILDDIR)/player/ptxplay.bin \
	    $(PLAYER_PTX_ORIGIN_DEC) ptxplay \
	    $(BUILDDIR)/pt3-player-stage1.tap

$(BUILDDIR)/pt3-player.tap: $(BUILDDIR)/pt3-player-stage1.tap
	@# Sanity-check: the C binary's CODE block must end below PTxPlay's origin
	@# (where PTxPlay loads), otherwise CODE 2 silently overwrites CODE 1.
	@end=$$(python3 -c "import os; print(0x8000 + os.path.getsize('$(BUILDDIR)/pt3-player-base_CODE.bin'))"); \
	if [ $$end -gt $(PLAYER_PTX_ORIGIN_DEC) ]; then \
	    printf "ERROR: pt3-player C binary ends at \$$%X, overlaps PTxPlay at \$$$(PLAYER_PTX_ORIGIN_HEX).\n" $$end >&2; \
	    printf "       Bump PLAYER_PTX_ORIGIN_HEX in the Makefile or shrink the program.\n" >&2; \
	    exit 1; \
	fi
	cp $(BUILDDIR)/pt3-player-stage1.tap $(BUILDDIR)/pt3-player.tap

# ---- tracker (separate app: edit PT3 songs from tape) -----------------------
# Same PTxPlay binary + tape-load infrastructure as the player; different C
# main + screens. Builds an independent build/tracker.tap.
tracker: $(BUILDDIR)/tracker.tap

$(BUILDDIR)/tracker-base.tap: $(SRCDIR)/tracker.c $(AY_SRCS) $(ENGINE_SRCS) $(IO_SRCS) \
                              $(BUILDDIR)/ptxplay_addrs.h \
                              $(SRCDIR)/ay_ts2068.h $(SRCDIR)/pt_engine.h $(SRCDIR)/ts_io.h \
                              | $(BUILDDIR)
	$(ZCC) $(CFLAGS) $(TRACKER_CRT) -DTAPE_SONG_BASE=0x$(TAPE_SONG_BASE_HEX) \
	    $(SRCDIR)/tracker.c $(AY_SRCS) $(ENGINE_SRCS) $(IO_SRCS) \
	    -o $(BUILDDIR)/tracker-base \
	    -create-app

$(BUILDDIR)/tracker.tap: $(BUILDDIR)/tracker-base.tap $(BUILDDIR)/ptxplay.bin tools/append_code_block.py
	@end=$$(python3 -c "import os; print(0x8000 + os.path.getsize('$(BUILDDIR)/tracker-base_CODE.bin'))"); \
	if [ $$end -gt $(PTX_ORIGIN_DEC) ]; then \
	    printf "ERROR: tracker C binary ends at \$$%X, overlaps PTxPlay at \$$$(PTX_ORIGIN_HEX).\n" $$end >&2; \
	    printf "       Bump PTX_ORIGIN_HEX in the Makefile or shrink the program.\n" >&2; \
	    exit 1; \
	fi
	python3 tools/append_code_block.py \
	    $(BUILDDIR)/tracker-base.tap \
	    $(BUILDDIR)/ptxplay.bin \
	    $(PTX_ORIGIN_DEC) ptxplay \
	    $(BUILDDIR)/tracker.tap

# ---- songs-tape (a separate .tap of song CODE blocks) -----------------------
# Lets the player's `L` key load arbitrary songs from tape at runtime: load
# pt3-player.tap first, then swap to songs.tap in the emulator and press L.
# Each CODE block lands at TAPE_SONG_BASE (currently $$(TAPE_SONG_BASE_HEX)).
songs-tape: $(BUILDDIR)/songs.tap

# Songs in songs/ have spaces in their names which break make's dep tracking;
# stage them through no-space filenames first, same trick as songs.stamp.
$(BUILDDIR)/songs.tap: $(MAKEFILE_LIST) tools/songs_to_tape.py | $(BUILDDIR)
	@rm -rf $(BUILDDIR)/tape_staged && mkdir -p $(BUILDDIR)/tape_staged
	@i=0; for f in $(SONGS_DIR)/*.pt2 $(SONGS_DIR)/*.pt3; do \
	    [ -f "$$f" ] || continue; \
	    cp "$$f" "$(BUILDDIR)/tape_staged/song_$$(printf '%02d' $$i).pt3"; \
	    i=$$((i+1)); \
	done
	python3 tools/songs_to_tape.py $(BUILDDIR)/songs.tap $(BUILDDIR)/tape_staged/*.pt3

# ---- release (downloadable zip of the prebuilt tapes + manual) --------------
# Bundles both apps' .tap, the sample songs, the manual PDF and a quick-start
# README into release/ts-tracker.zip, and refreshes the loose copies the
# top-level README links. docs/manual.pdf is committed (regenerate it with
# tools in ~/dotmatrix-pdf if the manual changes).
release: pt3-player tracker songs-tape
	@rm -rf $(BUILDDIR)/release && mkdir -p $(BUILDDIR)/release
	cp $(BUILDDIR)/tracker.tap $(BUILDDIR)/pt3-player.tap $(BUILDDIR)/songs.tap $(BUILDDIR)/release/
	cp docs/manual.pdf $(BUILDDIR)/release/TS-Tracker-Manual.pdf
	cp release/README.txt $(BUILDDIR)/release/README.txt
	cd $(BUILDDIR)/release && rm -f ../ts-tracker.zip && zip -q -X ../ts-tracker.zip \
	    tracker.tap pt3-player.tap songs.tap TS-Tracker-Manual.pdf README.txt
	cp $(BUILDDIR)/ts-tracker.zip release/ts-tracker.zip
	cp $(BUILDDIR)/tracker.tap $(BUILDDIR)/pt3-player.tap $(BUILDDIR)/songs.tap release/
	@echo "release/ts-tracker.zip ready ($$(du -h release/ts-tracker.zip | cut -f1))"

# ---- housekeeping ------------------------------------------------------------
$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)
