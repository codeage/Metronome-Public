#ifndef METRONOME_RENDERER_H
#define METRONOME_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct MetronomeRenderer MetronomeRenderer;

typedef struct {
    uint32_t bpm, beats, rhythm, sound;
    uint32_t trainerStart, trainerTarget, trainerStep, trainerBars;
    uint32_t audibleBars, silentBars;
    uint64_t accents;
    float volume, balance;
} MetronomeRenderSettings;

typedef struct {
    uint64_t serial;
    double hostSeconds;
    uint32_t beat, bpm, accent;
    bool audible, ghost;
} MetronomeBeatEvent;

MetronomeRenderer *metronome_create(double sampleRate);
void metronome_destroy(MetronomeRenderer *renderer);
void metronome_configure(MetronomeRenderer *renderer, MetronomeRenderSettings settings);
// Only call while the audio engine is stopped.
void metronome_reset(MetronomeRenderer *renderer);
void metronome_render(MetronomeRenderer *renderer, float *left, float *right,
                      uint32_t frames, double hostSeconds);
bool metronome_event_at(MetronomeRenderer *renderer, double hostSeconds, MetronomeBeatEvent *event);
// Load each beat's mono voice clip once on the control thread. Unloaded clips use the wood sound.
bool metronome_load_voice(MetronomeRenderer *renderer, uint32_t beat,
                          const float *samples, uint32_t frames);

#endif
