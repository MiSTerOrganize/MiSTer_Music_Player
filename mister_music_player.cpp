/*
 * MiSTer Music Player — Retro game music jukebox for MiSTer FPGA
 *
 * Plays NSF (NES), SPC (SNES), VGM/VGZ (Genesis/Master System/arcade),
 * GBS (Game Boy), HES (PC Engine), AY (Spectrum), SAP (Atari), KSS (MSX),
 * GYM (Genesis) via Blargg's Game_Music_Emu library.
 *
 * Built following MiSTer-FPGA-Build-Guide.md conventions:
 *   - SDL 1.2 fbcon video (320x240 RGB565)
 *   - ALSA audio via dlopen (blocking snd_pcm_writei, NO usleep)
 *   - DummyAudioCallback for SDL timer init
 *   - SDL state polling for d-pad + joystick hat + analog
 *   - Audio thread pinned to core 1, main on core 0
 *   - vmode in launcher script
 *
 * Controls (gamepad):
 *   D-pad Up/Down  = Browse files / scroll track list
 *   D-pad Left/Right = Previous/Next track
 *   A (Enter)      = Select file / Play
 *   B (Escape)     = Back / Stop
 *   X              = Pause/Resume
 *   Start          = Toggle loop mode
 *
 * License: LGPL 2.1 (matching GME)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sched.h>
#include <time.h>

#include "SDL.h"
#include "gme/gme.h"

/* ── Display ─────────────────────────────────────────────────── */
#define SCREEN_W    320
#define SCREEN_H    240
#define SCOPE_H     80
#define LIST_Y      (SCOPE_H + 16)
#define LIST_H      (SCREEN_H - LIST_Y)
#define LINE_H      10
#define MAX_VISIBLE (LIST_H / LINE_H)

/* ── Audio ───────────────────────────────────────────────────── */
#define SAMPLE_RATE  44100
#define CHANNELS     2
#define AUDIO_BUFSZ  1024

/* ── Colors (RGB565) ─────────────────────────────────────────── */
#define COL_BG       0x0000
#define COL_SCOPE_BG 0x0841
#define COL_SCOPE    0x07E0  /* green */
#define COL_TEXT     0xFFFF  /* white */
#define COL_HILITE   0x001F  /* blue highlight */
#define COL_DIM      0x7BEF  /* grey */
#define COL_TITLE    0xFFE0  /* yellow */
#define COL_SYSTEM   0x07FF  /* cyan */

/* ── ALSA function pointers (dlopen) ─────────────────────────── */
typedef long snd_pcm_t;
typedef long snd_pcm_sframes_t;

static void *alsa_lib = NULL;
static snd_pcm_t *pcm_handle = NULL;

static int (*p_snd_pcm_open)(snd_pcm_t**, const char*, int, int);
static int (*p_snd_pcm_set_params)(snd_pcm_t*, int, int, unsigned int,
                                    unsigned int, int, unsigned int);
static snd_pcm_sframes_t (*p_snd_pcm_writei)(snd_pcm_t*, const void*,
                                              unsigned long);
static int (*p_snd_pcm_recover)(snd_pcm_t*, int, int);
static int (*p_snd_pcm_close)(snd_pcm_t*);
static int (*p_snd_pcm_prepare)(snd_pcm_t*);
static int (*p_snd_pcm_drop)(snd_pcm_t*);

static bool alsa_init(void) {
    alsa_lib = dlopen("/usr/lib/libasound.so.2", RTLD_NOW);
    if (!alsa_lib) {
        /* Fallback for build environment */
        alsa_lib = dlopen("libasound.so.2", RTLD_NOW);
    }
    if (!alsa_lib) return false;

    p_snd_pcm_open      = (decltype(p_snd_pcm_open))dlsym(alsa_lib, "snd_pcm_open");
    p_snd_pcm_set_params = (decltype(p_snd_pcm_set_params))dlsym(alsa_lib, "snd_pcm_set_params");
    p_snd_pcm_writei    = (decltype(p_snd_pcm_writei))dlsym(alsa_lib, "snd_pcm_writei");
    p_snd_pcm_recover   = (decltype(p_snd_pcm_recover))dlsym(alsa_lib, "snd_pcm_recover");
    p_snd_pcm_close     = (decltype(p_snd_pcm_close))dlsym(alsa_lib, "snd_pcm_close");
    p_snd_pcm_prepare   = (decltype(p_snd_pcm_prepare))dlsym(alsa_lib, "snd_pcm_prepare");
    p_snd_pcm_drop      = (decltype(p_snd_pcm_drop))dlsym(alsa_lib, "snd_pcm_drop");

    if (!p_snd_pcm_open || !p_snd_pcm_writei) return false;

    int err = p_snd_pcm_open(&pcm_handle, "default", 0 /* PLAYBACK */, 0);
    if (err < 0) return false;

    err = p_snd_pcm_set_params(pcm_handle,
        2,  /* SND_PCM_FORMAT_S16_LE */
        3,  /* SND_PCM_ACCESS_RW_INTERLEAVED */
        CHANNELS,
        SAMPLE_RATE,
        1,      /* allow resampling */
        80000); /* 80ms latency */

    return err >= 0;
}

/* ── GME state ───────────────────────────────────────────────── */
static Music_Emu *emu = NULL;
static gme_info_t *track_info = NULL;
static int current_track = 0;
static int track_count = 0;
static bool paused = false;
static bool looping = false;
static volatile bool audio_running = false;
static volatile bool g_running = true;
static short scope_buf[SCREEN_W * 2]; /* stereo scope buffer */
static pthread_t audio_tid;

/* ── Audio thread (core 1, blocking writei, NO usleep) ───────── */
static void *audio_thread_func(void *arg) {
    (void)arg;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(1, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    int16_t buffer[AUDIO_BUFSZ * CHANNELS];

    while (audio_running) {
        if (emu && !paused) {
            gme_play(emu, AUDIO_BUFSZ * CHANNELS, buffer);

            /* Copy to scope buffer for visualization */
            int copy_len = SCREEN_W * 2;
            if (copy_len > AUDIO_BUFSZ * CHANNELS)
                copy_len = AUDIO_BUFSZ * CHANNELS;
            memcpy(scope_buf, buffer, copy_len * sizeof(int16_t));

            /* Blocking write — ALSA paces us, DO NOT add usleep */
            snd_pcm_sframes_t frames = p_snd_pcm_writei(pcm_handle,
                buffer, AUDIO_BUFSZ);
            if (frames < 0) {
                p_snd_pcm_recover(pcm_handle, (int)frames, 1);
            }
        } else {
            /* Paused or no emu — write silence */
            memset(buffer, 0, sizeof(buffer));
            p_snd_pcm_writei(pcm_handle, buffer, AUDIO_BUFSZ);
        }
    }
    return NULL;
}

static void audio_start(void) {
    if (!audio_running) {
        audio_running = true;
        pthread_create(&audio_tid, NULL, audio_thread_func, NULL);
    }
}

static void audio_stop(void) {
    if (audio_running) {
        audio_running = false;
        pthread_join(audio_tid, NULL);
        if (p_snd_pcm_drop) p_snd_pcm_drop(pcm_handle);
        if (p_snd_pcm_prepare) p_snd_pcm_prepare(pcm_handle);
    }
}

/* ── Simple pixel font (4x6 built-in) ───────────────────────── */
/* Minimal built-in bitmap font for text rendering without dependencies */
static const uint8_t font_4x6[96][6] = {
    /* space ! " # $ % & ' ( ) * + , - . / */
    {0,0,0,0,0,0},{4,4,4,0,4,0},{10,10,0,0,0,0},{10,15,10,15,10,0},
    {4,7,4,14,4,0},{9,2,4,9,0,0},{4,10,4,10,5,0},{4,4,0,0,0,0},
    {2,4,4,4,2,0},{4,2,2,2,4,0},{0,10,4,10,0,0},{0,4,14,4,0,0},
    {0,0,0,4,4,8},{0,0,14,0,0,0},{0,0,0,0,4,0},{1,2,4,8,0,0},
    /* 0-9 */
    {6,9,9,9,6,0},{4,12,4,4,14,0},{6,9,2,4,15,0},{6,9,2,9,6,0},
    {2,6,10,15,2,0},{15,8,14,1,14,0},{6,8,14,9,6,0},{15,1,2,4,4,0},
    {6,9,6,9,6,0},{6,9,7,1,6,0},
    /* : ; < = > ? @ */
    {0,4,0,4,0,0},{0,4,0,4,8,0},{2,4,8,4,2,0},{0,15,0,15,0,0},
    {8,4,2,4,8,0},{6,1,2,0,2,0},{6,9,11,8,6,0},
    /* A-Z */
    {6,9,15,9,9,0},{14,9,14,9,14,0},{6,9,8,9,6,0},{14,9,9,9,14,0},
    {15,8,14,8,15,0},{15,8,14,8,8,0},{6,8,11,9,6,0},{9,9,15,9,9,0},
    {14,4,4,4,14,0},{1,1,1,9,6,0},{9,10,12,10,9,0},{8,8,8,8,15,0},
    {9,15,15,9,9,0},{9,13,11,9,9,0},{6,9,9,9,6,0},{14,9,14,8,8,0},
    {6,9,9,10,5,0},{14,9,14,10,9,0},{7,8,6,1,14,0},{14,4,4,4,4,0},
    {9,9,9,9,6,0},{9,9,9,6,6,0},{9,9,15,15,9,0},{9,6,6,6,9,0},
    {9,9,6,4,4,0},{15,2,4,8,15,0},
    /* [ \ ] ^ _ ` */
    {6,4,4,4,6,0},{8,4,2,1,0,0},{6,2,2,2,6,0},{4,10,0,0,0,0},
    {0,0,0,0,15,0},{4,2,0,0,0,0},
    /* a-z */
    {0,6,10,10,5,0},{8,14,9,9,14,0},{0,6,8,8,6,0},{1,7,9,9,7,0},
    {0,6,11,8,7,0},{2,4,6,4,4,0},{0,7,9,7,1,6},{8,14,9,9,9,0},
    {4,0,4,4,4,0},{2,0,2,2,2,4},{8,10,12,10,9,0},{4,4,4,4,2,0},
    {0,9,15,9,9,0},{0,14,9,9,9,0},{0,6,9,9,6,0},{0,14,9,14,8,0},
    {0,7,9,7,1,0},{0,5,6,4,4,0},{0,7,4,2,14,0},{4,14,4,4,2,0},
    {0,9,9,9,7,0},{0,9,9,6,6,0},{0,9,15,15,6,0},{0,9,6,6,9,0},
    {0,9,9,7,1,6},{0,15,2,4,15,0},
    /* { | } ~ */
    {2,4,8,4,2,0},{4,4,4,4,4,0},{8,4,2,4,8,0},{0,5,10,0,0,0},
};

static void draw_char(SDL_Surface *s, int x, int y, char c, uint16_t color) {
    if (c < 32 || c > 126) c = '?';
    const uint8_t *glyph = font_4x6[c - 32];
    uint16_t *pixels = (uint16_t*)s->pixels;
    int pitch = s->pitch / 2;

    for (int row = 0; row < 6; row++) {
        for (int col = 0; col < 4; col++) {
            if (glyph[row] & (8 >> col)) {
                int px = x + col;
                int py = y + row;
                if (px >= 0 && px < SCREEN_W && py >= 0 && py < SCREEN_H)
                    pixels[py * pitch + px] = color;
            }
        }
    }
}

static void draw_text(SDL_Surface *s, int x, int y, const char *text,
                      uint16_t color) {
    while (*text) {
        if (x + 4 > SCREEN_W) break;
        draw_char(s, x, y, *text, color);
        x += 5; /* 4px char + 1px gap */
        text++;
    }
}

static void draw_text_clipped(SDL_Surface *s, int x, int y, const char *text,
                              uint16_t color, int max_w) {
    int chars = max_w / 5;
    int len = strlen(text);
    if (len <= chars) {
        draw_text(s, x, y, text, color);
    } else {
        char buf[256];
        if (chars > 3) {
            strncpy(buf, text, chars - 3);
            buf[chars - 3] = '.';
            buf[chars - 2] = '.';
            buf[chars - 1] = '.';
            buf[chars] = '\0';
        } else {
            strncpy(buf, text, chars);
            buf[chars] = '\0';
        }
        draw_text(s, x, y, buf, color);
    }
}

/* ── Scope drawing ───────────────────────────────────────────── */
static void draw_scope(SDL_Surface *s) {
    uint16_t *pixels = (uint16_t*)s->pixels;
    int pitch = s->pitch / 2;

    /* Clear scope area */
    for (int y = 0; y < SCOPE_H; y++)
        for (int x = 0; x < SCREEN_W; x++)
            pixels[y * pitch + x] = COL_SCOPE_BG;

    /* Center line */
    int center = SCOPE_H / 2;
    for (int x = 0; x < SCREEN_W; x++)
        pixels[center * pitch + x] = 0x2104; /* dark grey */

    /* Draw waveform */
    for (int x = 0; x < SCREEN_W - 1; x++) {
        int idx = x * 2; /* stereo: left channel */
        int s1 = scope_buf[idx] + scope_buf[idx + 1]; /* L+R average */
        int s2 = scope_buf[idx + 2] + scope_buf[idx + 3];
        s1 = center - (s1 >> 10); /* scale to scope height */
        s2 = center - (s2 >> 10);
        if (s1 < 0) s1 = 0; if (s1 >= SCOPE_H) s1 = SCOPE_H - 1;
        if (s2 < 0) s2 = 0; if (s2 >= SCOPE_H) s2 = SCOPE_H - 1;

        /* Draw line between s1 and s2 */
        int y0 = s1 < s2 ? s1 : s2;
        int y1 = s1 > s2 ? s1 : s2;
        for (int y = y0; y <= y1; y++)
            pixels[y * pitch + x] = COL_SCOPE;
    }
}

/* ── File browser ────────────────────────────────────────────── */
#define MAX_FILES 512

typedef struct {
    char name[256];
    char path[512];
    bool is_dir;
} FileEntry;

static FileEntry files[MAX_FILES];
static int file_count = 0;
static int file_cursor = 0;
static int file_scroll = 0;
static char current_dir[512] = "/media/fat/Music";

static bool has_music_ext(const char *name) {
    const char *ext = strrchr(name, '.');
    if (!ext) return false;
    ext++;
    return (strcasecmp(ext, "nsf") == 0 || strcasecmp(ext, "nsfe") == 0 ||
            strcasecmp(ext, "spc") == 0 || strcasecmp(ext, "vgm") == 0 ||
            strcasecmp(ext, "vgz") == 0 || strcasecmp(ext, "gbs") == 0 ||
            strcasecmp(ext, "hes") == 0 || strcasecmp(ext, "ay") == 0 ||
            strcasecmp(ext, "sap") == 0 || strcasecmp(ext, "kss") == 0 ||
            strcasecmp(ext, "gym") == 0);
}

static int file_compare(const void *a, const void *b) {
    const FileEntry *fa = (const FileEntry*)a;
    const FileEntry *fb = (const FileEntry*)b;
    if (fa->is_dir != fb->is_dir) return fa->is_dir ? -1 : 1;
    return strcasecmp(fa->name, fb->name);
}

static void scan_directory(const char *path) {
    file_count = 0;
    file_cursor = 0;
    file_scroll = 0;
    strncpy(current_dir, path, sizeof(current_dir) - 1);

    DIR *dir = opendir(path);
    if (!dir) {
        /* Try fallback directories */
        dir = opendir("/media/fat");
        if (dir) strncpy(current_dir, "/media/fat", sizeof(current_dir) - 1);
        else return;
    }

    /* Add parent directory entry */
    if (strcmp(path, "/") != 0) {
        strcpy(files[file_count].name, "..");
        snprintf(files[file_count].path, sizeof(files[0].path), "%s/..", path);
        files[file_count].is_dir = true;
        file_count++;
    }

    struct dirent *ent;
    while ((ent = readdir(dir)) && file_count < MAX_FILES) {
        if (ent->d_name[0] == '.') continue; /* skip hidden files */

        char fullpath[512];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", path, ent->d_name);

        struct stat st;
        if (stat(fullpath, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            strncpy(files[file_count].name, ent->d_name, 255);
            strncpy(files[file_count].path, fullpath, 511);
            files[file_count].is_dir = true;
            file_count++;
        } else if (has_music_ext(ent->d_name)) {
            strncpy(files[file_count].name, ent->d_name, 255);
            strncpy(files[file_count].path, fullpath, 511);
            files[file_count].is_dir = false;
            file_count++;
        }
    }
    closedir(dir);

    qsort(files, file_count, sizeof(FileEntry), file_compare);
}

/* ── Draw info bar ───────────────────────────────────────────── */
static void draw_info_bar(SDL_Surface *s) {
    int y = SCOPE_H;
    uint16_t *pixels = (uint16_t*)s->pixels;
    int pitch = s->pitch / 2;

    /* Dark bar background */
    for (int r = y; r < y + 14; r++)
        for (int x = 0; x < SCREEN_W; x++)
            pixels[r * pitch + x] = 0x10A2;

    if (emu && track_info) {
        char buf[128];
        int ms = gme_tell(emu);
        int secs = ms / 1000;
        int total = track_info->length > 0 ? track_info->length / 1000 : 0;

        /* Track info: system | game | song | time */
        if (track_info->system[0])
            draw_text_clipped(s, 2, y + 1, track_info->system, COL_SYSTEM, 60);

        if (track_info->game[0])
            draw_text_clipped(s, 65, y + 1, track_info->game, COL_TITLE, 120);

        if (track_info->song[0])
            draw_text_clipped(s, 2, y + 7, track_info->song, COL_TEXT, 200);

        /* Time + track number */
        if (total > 0)
            snprintf(buf, sizeof(buf), "%d:%02d/%d:%02d [%d/%d]%s%s",
                secs / 60, secs % 60, total / 60, total % 60,
                current_track + 1, track_count,
                paused ? " PAUSED" : "",
                looping ? " LOOP" : "");
        else
            snprintf(buf, sizeof(buf), "%d:%02d [%d/%d]%s%s",
                secs / 60, secs % 60,
                current_track + 1, track_count,
                paused ? " PAUSED" : "",
                looping ? " LOOP" : "");
        draw_text(s, 210, y + 7, buf, COL_DIM);
    } else {
        draw_text(s, 2, y + 4, "MiSTer Music Player - No file loaded", COL_DIM);
    }
}

/* ── Draw file browser ───────────────────────────────────────── */
static void draw_file_list(SDL_Surface *s) {
    uint16_t *pixels = (uint16_t*)s->pixels;
    int pitch = s->pitch / 2;

    /* Clear list area */
    for (int y = LIST_Y; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++)
            pixels[y * pitch + x] = COL_BG;

    /* Directory header */
    draw_text_clipped(s, 2, LIST_Y, current_dir, COL_DIM, SCREEN_W - 4);

    int start_y = LIST_Y + LINE_H;
    for (int i = 0; i < MAX_VISIBLE - 1 && (file_scroll + i) < file_count; i++) {
        int idx = file_scroll + i;
        int y = start_y + i * LINE_H;
        bool selected = (idx == file_cursor);

        /* Highlight bar */
        if (selected) {
            for (int r = y; r < y + LINE_H && r < SCREEN_H; r++)
                for (int x = 0; x < SCREEN_W; x++)
                    pixels[r * pitch + x] = COL_HILITE;
        }

        /* Icon prefix */
        uint16_t color = selected ? COL_TEXT : (files[idx].is_dir ? COL_TITLE : COL_TEXT);
        const char *prefix = files[idx].is_dir ? "[DIR] " : "  ";
        char display[300];
        snprintf(display, sizeof(display), "%s%s", prefix, files[idx].name);
        draw_text_clipped(s, 2, y + 2, display, color, SCREEN_W - 4);
    }
}

/* ── Load and play a file ────────────────────────────────────── */
static bool load_file(const char *path) {
    audio_stop();

    if (emu) { gme_delete(emu); emu = NULL; }
    if (track_info) { gme_free_info(track_info); track_info = NULL; }

    gme_err_t err = gme_open_file(path, &emu, SAMPLE_RATE);
    if (err) {
        fprintf(stderr, "GME error: %s\n", err);
        return false;
    }

    track_count = gme_track_count(emu);
    current_track = 0;
    paused = false;

    /* Start first track */
    gme_start_track(emu, 0);
    gme_track_info(emu, &track_info, 0);

    if (track_info->length <= 0)
        track_info->length = track_info->intro_length +
                             track_info->loop_length * 2;
    if (track_info->length <= 0)
        track_info->length = (long)(2.5 * 60 * 1000);

    if (!looping)
        gme_set_fade_msecs(emu, track_info->length, 8000);

    audio_start();
    return true;
}

static void start_track(int track) {
    if (!emu || track < 0 || track >= track_count) return;

    audio_stop();
    current_track = track;
    paused = false;

    gme_start_track(emu, track);

    if (track_info) gme_free_info(track_info);
    track_info = NULL;
    gme_track_info(emu, &track_info, track);

    if (track_info->length <= 0)
        track_info->length = track_info->intro_length +
                             track_info->loop_length * 2;
    if (track_info->length <= 0)
        track_info->length = (long)(2.5 * 60 * 1000);

    if (!looping)
        gme_set_fade_msecs(emu, track_info->length, 8000);
    else
        gme_set_fade_msecs(emu, -1, 8000);

    audio_start();
}

/* ── DummyAudioCallback (REQUIRED per build guide) ───────────── */
static void DummyAudioCallback(void *userdata, Uint8 *stream, int len) {
    (void)userdata;
    memset(stream, 0, len);
}

/* ── Signal handler ──────────────────────────────────────────── */
#include <signal.h>

static void signal_handler(int sig) {
    (void)sig;
    g_running = false;
    /* Silence audio immediately */
    if (pcm_handle && p_snd_pcm_drop) {
        p_snd_pcm_drop(pcm_handle);
        int16_t silence[1024];
        memset(silence, 0, sizeof(silence));
        if (p_snd_pcm_prepare) p_snd_pcm_prepare(pcm_handle);
        if (p_snd_pcm_writei) p_snd_pcm_writei(pcm_handle, silence, 512);
        if (p_snd_pcm_close) p_snd_pcm_close(pcm_handle);
        pcm_handle = NULL;
    }
}

/* ── Main ────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    /* Pin main thread to core 0 */
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(0, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    /* Set SDL environment for MiSTer fbcon */
    setenv("SDL_VIDEODRIVER", "fbcon", 0);
    setenv("SDL_FBDEV", "/dev/fb0", 0);

    /* Init SDL */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_JOYSTICK) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    atexit(SDL_Quit);

    /* DummyAudioCallback — REQUIRED for SDL timer init (build guide §4) */
    SDL_AudioSpec want = {0};
    SDL_AudioSpec have;
    want.freq = 22050;
    want.format = AUDIO_S16LSB;
    want.channels = 1;
    want.samples = 512;
    want.callback = DummyAudioCallback;
    SDL_OpenAudio(&want, &have);
    SDL_CloseAudio();

    /* Set video mode */
    SDL_ShowCursor(SDL_DISABLE);
    SDL_Surface *screen = SDL_SetVideoMode(SCREEN_W, SCREEN_H, 16,
                                           SDL_SWSURFACE);
    if (!screen) {
        fprintf(stderr, "SDL_SetVideoMode failed: %s\n", SDL_GetError());
        return 1;
    }

    /* Clear framebuffer 3 times (build guide §3) */
    for (int i = 0; i < 3; i++) {
        SDL_FillRect(screen, NULL, 0);
        SDL_Flip(screen);
    }

    /* Open joystick */
    SDL_Joystick *joy = NULL;
    if (SDL_NumJoysticks() > 0)
        joy = SDL_JoystickOpen(0);

    /* Init ALSA */
    if (!alsa_init()) {
        fprintf(stderr, "ALSA init failed — audio disabled\n");
    }

    /* Determine music directory */
    const char *music_dir = "/media/fat/Music";
    if (argc > 1) {
        struct stat st;
        if (stat(argv[1], &st) == 0) {
            if (S_ISDIR(st.st_mode))
                music_dir = argv[1];
            else {
                /* Direct file argument — load it */
                music_dir = "/media/fat/Music";
                load_file(argv[1]);
            }
        }
    }

    scan_directory(music_dir);
    memset(scope_buf, 0, sizeof(scope_buf));

    /* ── Main loop ───────────────────────────────────────────── */
    uint32_t last_input_time = 0;
    const uint32_t INPUT_REPEAT_MS = 200;

    while (g_running) {
        uint32_t now = SDL_GetTicks();

        /* Process events (buttons only, not directions — build guide §5) */
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT:
                g_running = false;
                break;
            case SDL_KEYDOWN:
                if (ev.key.keysym.sym == SDLK_ESCAPE) {
                    /* B = Go back a folder in browser */
                    if (strcmp(current_dir, "/") != 0) {
                        char resolved[512];
                        strncpy(resolved, current_dir, sizeof(resolved));
                        char *last = strrchr(resolved, '/');
                        if (last && last != resolved)
                            *last = '\0';
                        else
                            strcpy(resolved, "/");
                        scan_directory(resolved);
                    }
                }
                if (ev.key.keysym.sym == SDLK_RETURN) {
                    /* A = Select file/folder in browser, OR Pause/Resume during playback */
                    if (file_count > 0) {
                        FileEntry *f = &files[file_cursor];
                        if (f->is_dir) {
                            char resolved[512];
                            if (strcmp(f->name, "..") == 0) {
                                char *last = strrchr(current_dir, '/');
                                if (last && last != current_dir) {
                                    *last = '\0';
                                    strncpy(resolved, current_dir, sizeof(resolved));
                                } else {
                                    strcpy(resolved, "/");
                                }
                            } else {
                                strncpy(resolved, f->path, sizeof(resolved));
                            }
                            scan_directory(resolved);
                        } else {
                            load_file(f->path);
                        }
                    } else if (emu) {
                        /* No file selected but music playing — pause/resume */
                        paused = !paused;
                    }
                }
                break;
            case SDL_JOYBUTTONDOWN:
                if (ev.jbutton.button == 0) {
                    /* A = Pause/Resume during playback (also handled via Enter above for select) */
                    if (emu) paused = !paused;
                }
                if (ev.jbutton.button == 7) {
                    /* Start = Toggle loop */
                    looping = !looping;
                    if (emu) {
                        if (looping)
                            gme_set_fade_msecs(emu, -1, 8000);
                        else if (track_info)
                            gme_set_fade_msecs(emu, track_info->length, 8000);
                    }
                }
                /* Button 6 (Back/Select) = DO NOTHING */
                /* Button 8 (Guide) = DO NOTHING — MiSTer OSD handles Guide natively */
                break;
            }
        }

        /* Direction input: SDL state polling (build guide §5) */
        if (now - last_input_time > INPUT_REPEAT_MS) {
            int up = 0, down = 0, left = 0, right = 0;

            /* Keyboard state (d-pad → arrow keys) */
            const Uint8 *keys = SDL_GetKeyState(NULL);
            if (keys[SDLK_UP])    up = 1;
            if (keys[SDLK_DOWN])  down = 1;
            if (keys[SDLK_LEFT])  left = 1;
            if (keys[SDLK_RIGHT]) right = 1;

            /* Joystick hat */
            if (joy) {
                Uint8 hat = SDL_JoystickGetHat(joy, 0);
                if (hat & SDL_HAT_UP)    up = 1;
                if (hat & SDL_HAT_DOWN)  down = 1;
                if (hat & SDL_HAT_LEFT)  left = 1;
                if (hat & SDL_HAT_RIGHT) right = 1;

                /* Analog stick with deadzone (build guide: min 8000) */
                Sint16 ax = SDL_JoystickGetAxis(joy, 0);
                Sint16 ay = SDL_JoystickGetAxis(joy, 1);
                if (ay < -8000) up = 1;
                if (ay >  8000) down = 1;
                if (ax < -8000) left = 1;
                if (ax >  8000) right = 1;
            }

            if (up || down || left || right)
                last_input_time = now;

            /* Apply directions */
            if (up && file_cursor > 0) {
                file_cursor--;
                if (file_cursor < file_scroll)
                    file_scroll = file_cursor;
            }
            if (down && file_cursor < file_count - 1) {
                file_cursor++;
                if (file_cursor >= file_scroll + MAX_VISIBLE - 1)
                    file_scroll = file_cursor - MAX_VISIBLE + 2;
            }
            if (left && emu) {
                /* Previous track */
                if (current_track > 0)
                    start_track(current_track - 1);
            }
            if (right && emu) {
                /* Next track */
                if (current_track < track_count - 1)
                    start_track(current_track + 1);
            }
        }

        /* Auto-advance track when current one ends */
        if (emu && !paused && gme_track_ended(emu)) {
            if (current_track < track_count - 1)
                start_track(current_track + 1);
            else if (looping)
                start_track(0);
            else
                paused = true;
        }

        /* ── Render ──────────────────────────────────────────── */
        draw_scope(screen);
        draw_info_bar(screen);
        draw_file_list(screen);

        SDL_UpdateRect(screen, 0, 0, SCREEN_W, SCREEN_H);

        /* Frame pacing (~30fps for UI — audio runs independently) */
        SDL_Delay(33);
    }

    /* Cleanup */
    audio_stop();
    if (emu) gme_delete(emu);
    if (track_info) gme_free_info(track_info);
    if (joy) SDL_JoystickClose(joy);
    if (pcm_handle && p_snd_pcm_close) p_snd_pcm_close(pcm_handle);
    if (alsa_lib) dlclose(alsa_lib);

    return 0;
}
