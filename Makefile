# MiSTer Music Player — Makefile
# 13 libraries, 27 systems, 1 binary. FPGA audio.

GME_DIR         = game-music-emu/gme
SDL_PREFIX     ?= /opt/sdl12
MUSICLIBS_PREFIX ?= /opt/musiclibs

SDL_CFLAGS  = $(shell $(SDL_PREFIX)/bin/sdl-config --cflags 2>/dev/null || echo "-I$(SDL_PREFIX)/include/SDL")
SDL_LIBS    = $(shell $(SDL_PREFIX)/bin/sdl-config --static-libs 2>/dev/null || echo "-L$(SDL_PREFIX)/lib -lSDL -lpthread")
ML          = $(MUSICLIBS_PREFIX)

CXX      = g++
CC       = gcc
CXXFLAGS = -mcpu=cortex-a9 -mtune=cortex-a9 -mfloat-abi=hard -mfpu=neon \
           -Ofast -I$(GME_DIR) -Igame-music-emu $(SDL_CFLAGS) \
           -I$(ML)/include \
           -DBLARGG_LITTLE_ENDIAN=1 -DVGM_YM2612_NUKED \
           -DHAVE_SIDPLAYFP -DHAVE_OPENMPT -DHAVE_SC68 \
           -DHAVE_PSFLIB -DHAVE_HE -DHAVE_HT \
           -DHAVE_LAZYUSF -DHAVE_LAZYGSF \
           -DHAVE_ADPLUG -DHAVE_LIBVGM -DHAVE_MDXMINI -DHAVE_WSWAN \
           -ffunction-sections -fdata-sections -Wno-unused-result
CFLAGS   = $(CXXFLAGS)

# Link order matters — dependents before dependencies
LDFLAGS  = -static-libstdc++ -static-libgcc \
           -L$(ML)/lib \
           -lsidplayfp -lresid-builder -lstilview \
           -lopenmpt \
           -lsc68 -lfile68 \
           -lpsflib \
           -lhe -lht \
           -llazyusf -llazygsf \
           -ladplug -lbinio \
           -lvgm-player -lvgm-emu -lvgm-audio -lvgm-utils \
           -lmdxmini \
           -lwswan \
           $(SDL_LIBS) -lm -lpthread -lrt -lz \
           -Wl,--gc-sections -Wl,--as-needed

GME_SRC = $(wildcard $(GME_DIR)/*.cpp) $(GME_DIR)/ext/emu2413.c
GME_OBJ = $(patsubst %.cpp,%.o,$(patsubst %.c,%.o,$(GME_SRC)))

PLAYER_SRC = music_player.cpp
PLAYER_OBJ = $(PLAYER_SRC:.cpp=.o)
BIN = Music_Player

all: $(BIN)

$(BIN): $(GME_OBJ) $(PLAYER_OBJ)
	$(CXX) $^ -o $@ $(LDFLAGS)
	strip $@
	@echo "Built: $(BIN) — ALL 27 systems"
	@ls -lh $(BIN)

%.o: %.cpp
	$(CXX) -c $(CXXFLAGS) $< -o $@
%.o: %.c
	$(CC) -c $(CFLAGS) $< -o $@

clean:
	rm -f $(GME_OBJ) $(PLAYER_OBJ) $(BIN)

.PHONY: all clean
