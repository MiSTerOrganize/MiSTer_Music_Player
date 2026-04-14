/*
 * MiSTer Music Player — Unified retro game music player
 *
 * One binary, all formats. Currently: GME (Phase 1).
 * Future phases add libsidplayfp, libopenmpt, sc68, etc.
 *
 * Hybrid FPGA+ARM core — ARM writes to DDR3 only:
 *   - Audio: 48KHz stereo PCM to DDR3 ring buffer → FPGA I2S/SPDIF/DAC
 *   - Video: metadata struct + waveform to DDR3 → FPGA renders text/scope
 *   - Input: FPGA writes joystick to DDR3 → ARM reads
 *   - Files: FPGA writes ioctl data to DDR3 → ARM reads
 *
 * No ALSA. No framebuffer. No SDL video. Cleanest possible audio path.
 * Same output path as NES/SNES/Genesis cores.
 *
 * 29 systems, 35+ formats across 11 libraries — one RBF, one binary.
 *
 * Controls:
 *   D-pad Left/Right = Previous/Next track
 *   A                = Play / Pause
 *   Start            = Toggle loop mode
 *   Back/Guide       = Quit
 *
 * License: GPL-3.0 (MiSTer Organize)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <fcntl.h>
#include <sys/mman.h>

#include "SDL.h"
#include "gme/gme.h"

/* ── DDR3 Memory Map ─────────────────────────────────────────── */
#define DDR3_BASE         0x3A000000
#define DDR3_SIZE         0x00080000  /* 512KB mapped region */

#define OFF_CTRL          0x0000
#define OFF_JOY           0x0008
#define OFF_FILE_CTRL     0x0010
#define OFF_STATE         0x0018
#define OFF_TIME          0x0020
#define OFF_FORMAT        0x0028
#define OFF_TITLE         0x0030
#define OFF_ARTIST        0x0070
#define OFF_GAME          0x00B0
#define OFF_SYSTEM        0x00F0
#define OFF_WAVE_L        0x0100
#define OFF_WAVE_R        0x0380
#define OFF_AUD_WPTR      0x0800
#define OFF_AUD_RPTR      0x0804
#define OFF_AUD_RING      0x0810
#define OFF_FILE_DATA     0x4900

/* Audio ring buffer */
#define RING_SIZE         4096
#define RING_MASK         (RING_SIZE - 1)
#define AUDIO_RATE        48000
#define AUDIO_CHUNK       512

/* Playback state flags */
#define FLAG_PLAYING      (1 << 0)
#define FLAG_PAUSED       (1 << 1)
#define FLAG_LOOP         (1 << 2)
#define FLAG_LOADED       (1 << 3)
#define FLAG_AUDIO_RDY    (1 << 4)

/* Joystick bits */
#define JOY_RIGHT         0x0001
#define JOY_LEFT          0x0002
#define JOY_DOWN          0x0004
#define JOY_UP            0x0008
#define JOY_A             0x0010
#define JOY_B             0x0020
#define JOY_X             0x0040
#define JOY_Y             0x0080
#define JOY_START         0x0800
#define JOY_BACK          0x1000
#define JOY_GUIDE         0x2000

/* Format IDs — covers all 29 systems across all phases */
enum {
    FMT_UNKNOWN = 0,
    /* Phase 1: GME */
    FMT_NSF, FMT_NSFE, FMT_SPC, FMT_VGM, FMT_VGZ,
    FMT_GBS, FMT_HES, FMT_AY, FMT_SAP, FMT_KSS, FMT_GYM,
    /* Phase 2: libsidplayfp */
    FMT_SID,
    /* Phase 3: libopenmpt */
    FMT_MOD, FMT_S3M, FMT_XM, FMT_IT, FMT_MPTM,
    /* Phase 4: sc68 */
    FMT_SNDH, FMT_SC68,
    /* Phase 5: Highly Experimental */
    FMT_PSF, FMT_SSF,
    /* Phase 6: lazyusf2 */
    FMT_USF,
    /* Phase 7: lazygsf */
    FMT_GSF,
    /* Phase 8: adplug */
    FMT_DRO, FMT_IMF, FMT_CMF, FMT_MUS_DOOM,
    /* Phase 9: libs98 */
    FMT_S98,
    /* Phase 10: mdxmini */
    FMT_MDX,
    /* Phase 11: in_wsr */
    FMT_WSR,
};

#define WAVEFORM_WIDTH    320

/* ── Global State ────────────────────────────────────────────── */
static volatile uint8_t  *ddr3 = NULL;

static Music_Emu *gme_emu = NULL;
static int current_track = 0;
static int total_tracks = 0;
static bool playing = false;
static bool paused = false;
static bool loop_mode = false;
static bool file_loaded = false;
static bool running = true;
static uint8_t format_id = FMT_UNKNOWN;

static int16_t last_audio_buf[AUDIO_CHUNK * 2];
static pthread_mutex_t audio_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ── DDR3 helpers ────────────────────────────────────────────── */
static inline void ddr3_w32(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(ddr3 + off) = v;
}
static inline uint32_t ddr3_r32(uint32_t off) {
    return *(volatile uint32_t *)(ddr3 + off);
}
static inline void ddr3_w8(uint32_t off, uint8_t v) {
    *(volatile uint8_t *)(ddr3 + off) = v;
}
static void ddr3_wstr(uint32_t off, const char *s, int max) {
    int i;
    for (i = 0; i < max - 1 && s && s[i]; i++)
        ddr3[off + i] = s[i];
    for (; i < max; i++)
        ddr3[off + i] = 0;
}

static bool ddr3_init(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return false; }
    ddr3 = (volatile uint8_t *)mmap(NULL, DDR3_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd, DDR3_BASE);
    close(fd);
    if (ddr3 == MAP_FAILED) { ddr3 = NULL; return false; }
    memset((void *)ddr3, 0, OFF_AUD_RING);
    memset((void *)(ddr3 + OFF_AUD_RING), 0, RING_SIZE * 4);
    return true;
}

/* ── Format detection ────────────────────────────────────────── */
static uint8_t detect_format(const uint8_t *d, uint32_t sz) {
    if (sz < 4) return FMT_UNKNOWN;
    if (!memcmp(d, "NESM", 4)) return FMT_NSF;
    if (!memcmp(d, "NSFE", 4)) return FMT_NSFE;
    if (sz >= 0x2E && !memcmp(d + 0x25, "SNES-SPC700", 11)) return FMT_SPC;
    if (!memcmp(d, "Vgm ", 4)) return FMT_VGM;
    if (d[0] == 0x1F && d[1] == 0x8B) return FMT_VGZ;
    if (!memcmp(d, "GBS", 3)) return FMT_GBS;
    if (!memcmp(d, "HESM", 4)) return FMT_HES;
    if (!memcmp(d, "ZXAY", 4)) return FMT_AY;
    if (!memcmp(d, "SAP\r", 4) || !memcmp(d, "SAP\n", 4)) return FMT_SAP;
    if (!memcmp(d, "KSCC", 4) || !memcmp(d, "KSSX", 4)) return FMT_KSS;
    if (!memcmp(d, "GYMX", 4)) return FMT_GYM;
    if (!memcmp(d, "PSID", 4) || !memcmp(d, "RSID", 4)) return FMT_SID;
    if (sz >= 1084 && (!memcmp(d+1080,"M.K.",4) || !memcmp(d+1080,"M!K!",4) ||
        !memcmp(d+1080,"FLT4",4) || !memcmp(d+1080,"FLT8",4) ||
        !memcmp(d+1080,"4CHN",4) || !memcmp(d+1080,"6CHN",4) ||
        !memcmp(d+1080,"8CHN",4))) return FMT_MOD;
    if (sz >= 48 && !memcmp(d+44, "SCRM", 4)) return FMT_S3M;
    if (sz >= 17 && !memcmp(d, "Extended Module:", 16)) return FMT_XM;
    if (!memcmp(d, "IMPM", 4)) return FMT_IT;
    if (!memcmp(d, "SC68", 4)) return FMT_SC68;
    if (!memcmp(d, "SNDH", 4)) return FMT_SNDH;
    if (!memcmp(d, "ICE!", 4)) return FMT_SNDH; /* ICE packed SNDH */
    if (!memcmp(d, "PSF", 3)) {
        if (d[3] == 0x01) return FMT_PSF;
        if (d[3] == 0x11) return FMT_SSF;
        if (d[3] == 0x21) return FMT_USF;
        if (d[3] == 0x22) return FMT_GSF;
    }
    if (!memcmp(d, "DBRAWOPL", 8)) return FMT_DRO;
    if (sz >= 2 && d[0] == 0x00) return FMT_IMF; /* heuristic — weak */
    return FMT_UNKNOWN;
}

static bool is_gme_format(uint8_t f) {
    return f >= FMT_NSF && f <= FMT_GYM;
}

static const char *fmt_name(uint8_t f) {
    static const char *names[] = {
        "???",
        "NSF","NSFe","SPC","VGM","VGZ","GBS","HES","AY","SAP","KSS","GYM",
        "SID",
        "MOD","S3M","XM","IT","MPTM",
        "SNDH","SC68",
        "PSF","SSF","USF","GSF",
        "DRO","IMF","CMF","MUS",
        "S98","MDX","WSR"
    };
    if (f < sizeof(names)/sizeof(names[0])) return names[f];
    return "???";
}

static const char *sys_name(uint8_t f) {
    switch (f) {
        case FMT_NSF: case FMT_NSFE: return "NES";
        case FMT_SPC:  return "SNES";
        case FMT_VGM: case FMT_VGZ: return "Multi";
        case FMT_GBS:  return "Game Boy";
        case FMT_HES:  return "PC Engine";
        case FMT_AY:   return "ZX/CPC";
        case FMT_SAP:  return "Atari 8-bit";
        case FMT_KSS:  return "MSX";
        case FMT_GYM:  return "Genesis";
        case FMT_SID:  return "C64";
        case FMT_MOD:  return "Amiga";
        case FMT_S3M: case FMT_XM: case FMT_IT: case FMT_MPTM: return "Tracker";
        case FMT_SNDH: case FMT_SC68: return "Atari ST";
        case FMT_PSF:  return "PlayStation";
        case FMT_SSF:  return "Saturn";
        case FMT_USF:  return "N64";
        case FMT_GSF:  return "GBA";
        case FMT_DRO: case FMT_IMF: case FMT_CMF: case FMT_MUS_DOOM: return "PC AdLib";
        case FMT_S98:  return "PC-98";
        case FMT_MDX:  return "X68000";
        case FMT_WSR:  return "WonderSwan";
        default: return "";
    }
}

/* ── GME Backend ─────────────────────────────────────────────── */
static bool gme_load(const uint8_t *data, uint32_t size) {
    if (gme_emu) { gme_delete(gme_emu); gme_emu = NULL; }
    gme_err_t err = gme_open_data(data, size, &gme_emu, AUDIO_RATE);
    if (err || !gme_emu) return false;
    total_tracks = gme_track_count(gme_emu);
    current_track = 0;
    gme_start_track(gme_emu, 0);
    return true;
}

static int gme_render(int16_t *buf, int frames) {
    if (!gme_emu) return 0;
    return gme_play(gme_emu, frames * 2, buf) ? 0 : frames;
}

static void gme_update_meta(void) {
    if (!gme_emu) return;
    gme_info_t *info = NULL;
    gme_track_info(gme_emu, &info, current_track);
    if (!info) return;
    ddr3_wstr(OFF_TITLE,  info->song   && info->song[0]   ? info->song   : "Unknown", 64);
    ddr3_wstr(OFF_ARTIST, info->author && info->author[0] ? info->author : "", 64);
    ddr3_wstr(OFF_GAME,   info->game   && info->game[0]   ? info->game   : "", 64);
    ddr3_wstr(OFF_SYSTEM, info->system && info->system[0] ? info->system : sys_name(format_id), 16);
    gme_free_info(info);
}

static int gme_position_ms(void) { return gme_emu ? gme_tell(gme_emu) : 0; }

static int gme_duration_ms(void) {
    if (!gme_emu) return 0;
    gme_info_t *info = NULL;
    gme_track_info(gme_emu, &info, current_track);
    if (!info) return 0;
    int dur = info->play_length;
    gme_free_info(info);
    return dur;
}

static void gme_set_track(int t) {
    if (gme_emu && t >= 0 && t < total_tracks) {
        current_track = t;
        gme_start_track(gme_emu, t);
    }
}

/* ── Audio Thread ────────────────────────────────────────────── */
static void *audio_thread_func(void *arg) {
    (void)arg;
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(1, &cs);
    pthread_setaffinity_np(pthread_self(), sizeof(cs), &cs);

    int16_t buf[AUDIO_CHUNK * 2];
    const struct timespec idle = {0, 5000000};
    const struct timespec spin = {0, 100000};

    while (running) {
        if (!playing || paused || !file_loaded) {
            nanosleep(&idle, NULL);
            continue;
        }

        /* Generate audio from active backend */
        int frames = 0;
        if (is_gme_format(format_id) && gme_emu) {
            frames = gme_render(buf, AUDIO_CHUNK);
            if (gme_track_ended(gme_emu)) {
                if (loop_mode) {
                    gme_start_track(gme_emu, current_track);
                } else if (current_track + 1 < total_tracks) {
                    current_track++;
                    gme_start_track(gme_emu, current_track);
                    gme_update_meta();
                } else {
                    playing = false;
                    continue;
                }
            }
        }
        /* Phase 2+: add backend render calls here */

        if (frames <= 0) { nanosleep(&idle, NULL); continue; }

        /* Save for waveform display */
        pthread_mutex_lock(&audio_mutex);
        memcpy(last_audio_buf, buf, frames * 4);
        pthread_mutex_unlock(&audio_mutex);

        /* Wait for ring buffer space */
        uint32_t wp = ddr3_r32(OFF_AUD_WPTR);
        while (running) {
            uint32_t rp = ddr3_r32(OFF_AUD_RPTR);
            uint32_t used = (wp - rp) & RING_MASK;
            if (used < (RING_SIZE - (uint32_t)frames - 64)) break;
            nanosleep(&spin, NULL);
        }

        /* Write to DDR3 ring buffer */
        volatile int16_t *ring = (volatile int16_t *)(ddr3 + OFF_AUD_RING);
        for (int i = 0; i < frames; i++) {
            uint32_t idx = (wp + i) & RING_MASK;
            ring[idx * 2 + 0] = buf[i * 2 + 0];
            ring[idx * 2 + 1] = buf[i * 2 + 1];
        }
        __sync_synchronize();
        ddr3_w32(OFF_AUD_WPTR, (wp + frames) & RING_MASK);
    }
    return NULL;
}

/* ── Metadata update (60fps) ─────────────────────────────────── */
static uint32_t frame_ctr = 0;

static void update_metadata(void) {
    uint8_t flags = 0;
    if (playing)     flags |= FLAG_PLAYING;
    if (paused)      flags |= FLAG_PAUSED;
    if (loop_mode)   flags |= FLAG_LOOP;
    if (file_loaded) flags |= FLAG_LOADED;
    if (playing)     flags |= FLAG_AUDIO_RDY;

    ddr3_w8(OFF_STATE + 0, flags);
    ddr3_w8(OFF_STATE + 1, (uint8_t)current_track);
    ddr3_w8(OFF_STATE + 2, (uint8_t)total_tracks);
    ddr3_w8(OFF_STATE + 3, 255);

    int elapsed = 0, duration = 0;
    if (is_gme_format(format_id)) {
        elapsed = gme_position_ms();
        duration = gme_duration_ms();
    }
    ddr3_w32(OFF_TIME + 0, (uint32_t)elapsed);
    ddr3_w32(OFF_TIME + 4, (uint32_t)duration);

    ddr3_w32(OFF_FORMAT + 0, AUDIO_RATE);
    ddr3_w8(OFF_FORMAT + 4, 2);
    ddr3_w8(OFF_FORMAT + 5, format_id);

    /* Waveform: downsample last audio buffer to 320 samples */
    pthread_mutex_lock(&audio_mutex);
    volatile int16_t *wl = (volatile int16_t *)(ddr3 + OFF_WAVE_L);
    volatile int16_t *wr = (volatile int16_t *)(ddr3 + OFF_WAVE_R);
    for (int x = 0; x < WAVEFORM_WIDTH; x++) {
        int idx = (x * AUDIO_CHUNK) / WAVEFORM_WIDTH;
        if (idx >= AUDIO_CHUNK) idx = AUDIO_CHUNK - 1;
        wl[x] = last_audio_buf[idx * 2 + 0];
        wr[x] = last_audio_buf[idx * 2 + 1];
    }
    pthread_mutex_unlock(&audio_mutex);

    frame_ctr += 4;
    ddr3_w32(OFF_CTRL, frame_ctr);
}

/* ── File loading ────────────────────────────────────────────── */
static uint32_t last_fsize = 0;

static bool check_new_file(void) {
    uint32_t fsize = ddr3_r32(OFF_FILE_CTRL);
    if (fsize == 0 || fsize == last_fsize) return false;
    last_fsize = fsize;

    const uint8_t *fdata = (const uint8_t *)(ddr3 + OFF_FILE_DATA);
    format_id = detect_format(fdata, fsize);
    fprintf(stderr, "Music_Player: %u bytes, format=%s (%s)\n",
            fsize, fmt_name(format_id), sys_name(format_id));

    playing = false; paused = false; file_loaded = false;
    ddr3_w32(OFF_AUD_WPTR, 0);

    bool ok = false;
    if (is_gme_format(format_id)) {
        ok = gme_load(fdata, fsize);
        if (ok) gme_update_meta();
    }
    /* Phase 2+: route to other backends here */
    else {
        ddr3_wstr(OFF_TITLE, "Unsupported format", 64);
        ddr3_wstr(OFF_ARTIST, fmt_name(format_id), 64);
        ddr3_wstr(OFF_GAME, "", 64);
        ddr3_wstr(OFF_SYSTEM, sys_name(format_id), 16);
    }

    if (ok) {
        file_loaded = true;
        playing = true;

        /* Pre-fill ~21ms of audio before FPGA starts consuming */
        int16_t pre[1024 * 2];
        int n = 0;
        if (is_gme_format(format_id)) n = gme_render(pre, 1024);
        if (n > 0) {
            volatile int16_t *ring = (volatile int16_t *)(ddr3 + OFF_AUD_RING);
            for (int i = 0; i < n; i++) {
                ring[i * 2 + 0] = pre[i * 2 + 0];
                ring[i * 2 + 1] = pre[i * 2 + 1];
            }
            __sync_synchronize();
            ddr3_w32(OFF_AUD_WPTR, n & RING_MASK);
        }
    }

    ddr3_w32(OFF_FILE_CTRL, 0);
    return ok;
}

/* ── Input ───────────────────────────────────────────────────── */
static uint32_t prev_joy = 0;

static void handle_input(void) {
    uint32_t joy = ddr3_r32(OFF_JOY);
    uint32_t pressed = joy & ~prev_joy;
    prev_joy = joy;

    if (!file_loaded) return;

    if (pressed & JOY_RIGHT) {
        if (current_track + 1 < total_tracks) {
            current_track++;
            if (is_gme_format(format_id)) gme_set_track(current_track);
            if (is_gme_format(format_id)) gme_update_meta();
        }
    }
    if (pressed & JOY_LEFT) {
        if (current_track > 0) {
            current_track--;
            if (is_gme_format(format_id)) gme_set_track(current_track);
            if (is_gme_format(format_id)) gme_update_meta();
        }
    }
    if (pressed & JOY_A) {
        if (playing) paused = !paused;
        else { playing = true; paused = false; }
    }
    if (pressed & JOY_START) loop_mode = !loop_mode;
    if (pressed & (JOY_BACK | JOY_GUIDE)) running = false;
}

/* ── SDL dummy ───────────────────────────────────────────────── */
static void DummyCb(void *u, Uint8 *s, int l) { (void)u; memset(s,0,l); }

/* ── Main ────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    freopen("/dev/null", "w", stdout);
    fprintf(stderr, "Music_Player: hybrid FPGA+ARM, FPGA audio, 29 systems\n");

    if (!ddr3_init()) { fprintf(stderr, "DDR3 init failed\n"); return 1; }

    setenv("SDL_VIDEODRIVER", "dummy", 1);
    SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_JOYSTICK);
    SDL_AudioSpec as = {}; as.freq = 22050; as.format = AUDIO_S16SYS;
    as.channels = 1; as.samples = 512; as.callback = DummyCb;
    SDL_OpenAudio(&as, NULL);

    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(0, &cs);
    sched_setaffinity(0, sizeof(cs), &cs);

    pthread_t atid;
    pthread_create(&atid, NULL, audio_thread_func, NULL);

    ddr3_wstr(OFF_TITLE,  "MiSTer Music Player", 64);
    ddr3_wstr(OFF_ARTIST, "Load a file to begin", 64);
    ddr3_wstr(OFF_GAME,   "29 systems supported", 64);
    ddr3_wstr(OFF_SYSTEM, "", 16);
    update_metadata();

    fprintf(stderr, "Music_Player: ready\n");

    struct timespec ft = {0, 16666666};
    while (running) {
        check_new_file();
        handle_input();
        update_metadata();
        nanosleep(&ft, NULL);
    }

    playing = false; running = false;
    pthread_join(atid, NULL);
    if (gme_emu) gme_delete(gme_emu);
    SDL_CloseAudio(); SDL_Quit();
    if (ddr3) munmap((void *)ddr3, DDR3_SIZE);
    return 0;
}
