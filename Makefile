# MiSTer Music Player — Makefile
# Builds inside arm32v7/debian:bullseye-slim container via QEMU

# ── Paths ────────────────────────────────────────────────────────
GME_DIR    = game-music-emu/gme
SDL_PREFIX ?= /opt/sdl12
SDL_CFLAGS = $(shell $(SDL_PREFIX)/bin/sdl-config --cflags 2>/dev/null || echo "-I$(SDL_PREFIX)/include/SDL -I$(SDL_PREFIX)/include")
SDL_LIBS   = $(shell $(SDL_PREFIX)/bin/sdl-config --static-libs 2>/dev/null || echo "-L$(SDL_PREFIX)/lib -lSDL -lpthread")

# ── Compiler flags (MiSTer ARM Cortex-A9) ────────────────────────
CXX      = g++
CC       = gcc
CXXFLAGS = -mcpu=cortex-a9 -mtune=cortex-a9 -mfloat-abi=hard -mfpu=neon \
           -Ofast -I$(GME_DIR) -Igame-music-emu $(SDL_CFLAGS) \
           -DBLARGG_LITTLE_ENDIAN=1 -DVGM_YM2612_NUKED \
           -ffunction-sections -fdata-sections \
           -Wno-unused-result
CFLAGS   = $(CXXFLAGS)
LDFLAGS  = -static-libstdc++ -static-libgcc \
           $(SDL_LIBS) -lm -ldl -lpthread -lrt \
           -Wl,--gc-sections -Wl,--as-needed

# ── GME sources ──────────────────────────────────────────────────
GME_SRC = $(wildcard $(GME_DIR)/*.cpp) $(GME_DIR)/ext/emu2413.c
GME_OBJ = $(patsubst %.cpp,%.o,$(patsubst %.c,%.o,$(GME_SRC)))

# ── Player ───────────────────────────────────────────────────────
PLAYER_SRC = mister_music_player.cpp
PLAYER_OBJ = $(PLAYER_SRC:.cpp=.o)
BIN = MiSTer-Music-Player

# ── Rules ────────────────────────────────────────────────────────
all: $(BIN)

$(BIN): $(GME_OBJ) $(PLAYER_OBJ)
	$(CXX) $^ -o $@ $(LDFLAGS)
	strip $@
	@echo ""
	@echo "Built: $(BIN)"
	@file $(BIN) 2>/dev/null || true
	@ls -lh $(BIN)

%.o: %.cpp
	$(CXX) -c $(CXXFLAGS) $< -o $@

%.o: %.c
	$(CC) -c $(CFLAGS) $< -o $@

clean:
	rm -f $(GME_OBJ) $(PLAYER_OBJ) $(BIN)

.PHONY: all clean
