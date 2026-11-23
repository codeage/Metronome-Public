#include "MetronomeRenderer.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { eventCount = 128, voiceFrames = 24000, maxBeats = 32 };
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
typedef atomic_ullong AtomicWord;

typedef struct {
    AtomicWord sequence, accents, tempo, trainer, ghost, gain;
} SettingsMailbox;

typedef struct {
    AtomicWord sequence, host, data;
} EventSlot;

typedef struct {
    const float *samples;
    uint32_t count, position;
    float gain;
} Click;

struct MetronomeRenderer {
    SettingsMailbox mailbox;
    EventSlot events[eventCount];
    AtomicWord published;
    AtomicWord voiceCounts[maxBeats];
    uint64_t applied, serial, bar, frame, trainerFirstBar;
    uint32_t beat, tempo, pulse, toneFrames;
    double sampleRate, nextBeat, beatStart, beatDuration;
    bool ghost;
    MetronomeRenderSettings settings;
    Click primary, secondary;
    float tones[3][3][4096];
    float voices[maxBeats][voiceFrames];
};

static uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double bits_double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static uint64_t pack(uint32_t a, uint32_t b, uint32_t c, uint32_t d) {
    return a | ((uint64_t)b << 16) | ((uint64_t)c << 32) | ((uint64_t)d << 48);
}

static uint32_t unpack(uint64_t word, int field) {
    return (uint32_t)((word >> (field * 16)) & 0xffff);
}

void metronome_configure(MetronomeRenderer *r, MetronomeRenderSettings s) {
    SettingsMailbox *m = &r->mailbox;
    uint64_t gain;
    float channels[2] = {s.volume, s.balance};
    memcpy(&gain, channels, sizeof(gain));
    // Sequentially consistent atomics make every successful read a coherent snapshot.
    atomic_fetch_add(&m->sequence, 1);
    atomic_store(&m->tempo, pack(s.bpm, s.beats, s.rhythm, s.sound));
    atomic_store(&m->trainer, pack(s.trainerStart, s.trainerTarget, s.trainerStep, s.trainerBars));
    atomic_store(&m->ghost, pack(s.audibleBars, s.silentBars, 0, 0));
    atomic_store(&m->accents, s.accents);
    atomic_store(&m->gain, gain);
    atomic_fetch_add(&m->sequence, 1);
}

static void read_settings(MetronomeRenderer *r) {
    SettingsMailbox *m = &r->mailbox;
    uint64_t sequence = atomic_load(&m->sequence);
    if ((sequence & 1) || sequence == r->applied) return;
    uint64_t tempo = atomic_load(&m->tempo);
    uint64_t trainer = atomic_load(&m->trainer);
    uint64_t ghost = atomic_load(&m->ghost);
    uint64_t accents = atomic_load(&m->accents);
    uint64_t gain = atomic_load(&m->gain);
    if (sequence != atomic_load(&m->sequence)) return;
    float channels[2];
    memcpy(channels, &gain, sizeof(channels));
    MetronomeRenderSettings s = {
        unpack(tempo, 0), unpack(tempo, 1), unpack(tempo, 2), unpack(tempo, 3),
        unpack(trainer, 0), unpack(trainer, 1), unpack(trainer, 2), unpack(trainer, 3),
        unpack(ghost, 0), unpack(ghost, 1), accents, channels[0], channels[1]
    };
    if (s.beats < 1 || s.beats > maxBeats || s.bpm < 20 || s.bpm > 300) return;
    if (s.beats != r->settings.beats) {
        r->beat = 0;
        r->pulse = 4;
    }
    if (s.trainerBars && (s.trainerBars != r->settings.trainerBars || s.trainerStart != r->settings.trainerStart
        || s.trainerStep != r->settings.trainerStep || s.trainerTarget != r->settings.trainerTarget)) {
        r->trainerFirstBar = r->bar + (r->beat != 0);
    }
    if (!s.trainerBars && r->beatDuration > 0 && r->tempo != s.bpm) {
        double phase = ((double)r->frame - r->beatStart) / r->beatDuration;
        if (phase >= 0 && phase < 1) {
            r->beatDuration = r->sampleRate * 60.0 / s.bpm;
            r->beatStart = (double)r->frame - phase * r->beatDuration;
            r->nextBeat = r->beatStart + r->beatDuration;
        }
        r->tempo = s.bpm;
    }
    r->settings = s;
    r->applied = sequence;
}

MetronomeRenderer *metronome_create(double sampleRate) {
    if (sampleRate <= 0) return NULL;
    MetronomeRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->sampleRate = sampleRate;
    atomic_init(&r->published, 0);
    atomic_init(&r->mailbox.sequence, 0);
    atomic_init(&r->mailbox.tempo, 0);
    atomic_init(&r->mailbox.trainer, 0);
    atomic_init(&r->mailbox.ghost, 0);
    atomic_init(&r->mailbox.accents, 0);
    atomic_init(&r->mailbox.gain, 0);
    for (int i = 0; i < eventCount; ++i) {
        atomic_init(&r->events[i].sequence, 0);
        atomic_init(&r->events[i].host, 0);
        atomic_init(&r->events[i].data, 0);
    }
    for (int i = 0; i < maxBeats; ++i) atomic_init(&r->voiceCounts[i], 0);
    r->settings = (MetronomeRenderSettings){.bpm = 120, .beats = 4, .volume = 1, .accents = 0xa8};
    r->toneFrames = (uint32_t)fmin(4096, sampleRate * 0.065);
    for (int sound = 0; sound < 3; ++sound) {
        for (int accent = 0; accent < 3; ++accent) {
            const double tuning = 1.0 - accent * 0.14;
            float peak = 0;
            for (uint32_t i = 0; i < r->toneFrames; ++i) {
                double t = i / sampleRate;
                double base = 6.283185307179586 * t * tuning;
                double sample;
                if (sound == 0) {
                    sample = sin(base * 1570) + 0.38 * sin(base * 2790);
                    sample *= exp(-t * 150);
                } else if (sound == 1) {
                    sample = sin(base * 980) * exp(-t * 88);
                } else {
                    sample = (sin(base * 830) + 0.25 * sin(base * 2300)) * exp(-t * 175);
                }
                const float value = (float)(sample * fmin(1, t * 3600));
                r->tones[sound][accent][i] = value;
                peak = fmaxf(peak, fabsf(value));
            }
            if (peak > 0) {
                const float scale = 0.98f / peak;
                for (uint32_t i = 0; i < r->toneFrames; ++i) r->tones[sound][accent][i] *= scale;
            }
        }
    }
    return r;
}

void metronome_destroy(MetronomeRenderer *r) { free(r); }

void metronome_reset(MetronomeRenderer *r) {
    r->bar = r->frame = r->trainerFirstBar = 0;
    r->beat = r->tempo = r->pulse = 0;
    r->ghost = false;
    r->nextBeat = r->beatStart = r->beatDuration = 0;
    r->primary = r->secondary = (Click){0};
    atomic_store(&r->published, 0);
}

bool metronome_load_voice(MetronomeRenderer *r, uint32_t beat, const float *data, uint32_t frames) {
    if (beat >= maxBeats || !data || frames == 0 || atomic_load(&r->voiceCounts[beat])) return false;
    if (frames > voiceFrames) frames = voiceFrames;
    float peak = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        if (isfinite(data[i])) peak = fmaxf(peak, fabsf(data[i]));
    }
    if (peak < 0.012f) return false;
    const float drive = 1.35f;
    const float ceiling = 0.98f / tanhf(drive);
    for (uint32_t i = 0; i < frames; ++i) {
        float value = isfinite(data[i]) ? data[i] / peak : 0;
        r->voices[beat][i] = tanhf(value * drive) * ceiling;
    }
    atomic_store(&r->voiceCounts[beat], frames);
    return true;
}

static void publish(MetronomeRenderer *r, double host, uint32_t beat, uint32_t accent, bool audible) {
    if (host < 0) return;
    uint64_t serial = ++r->serial;
    EventSlot *slot = &r->events[serial % eventCount];
    atomic_store(&slot->sequence, serial * 2 + 1);
    atomic_store(&slot->host, double_bits(host));
    atomic_store(&slot->data, pack(beat, r->tempo, accent, (audible ? 1 : 0) | (r->ghost ? 2 : 0)));
    atomic_store(&slot->sequence, serial * 2);
    atomic_store(&r->published, serial);
}

bool metronome_event_at(MetronomeRenderer *r, double host, MetronomeBeatEvent *event) {
    uint64_t last = atomic_load(&r->published);
    for (uint64_t delta = 0; delta < eventCount && delta < last; ++delta) {
        uint64_t serial = last - delta;
        EventSlot *slot = &r->events[serial % eventCount];
        uint64_t expected = serial * 2;
        if (atomic_load(&slot->sequence) != expected) continue;
        double seconds = bits_double(atomic_load(&slot->host));
        uint64_t data = atomic_load(&slot->data);
        if (atomic_load(&slot->sequence) != expected || seconds > host) continue;
        *event = (MetronomeBeatEvent){
            serial, seconds, unpack(data, 0), unpack(data, 1), unpack(data, 2),
            (unpack(data, 3) & 1) != 0, (unpack(data, 3) & 2) != 0
        };
        return true;
    }
    return false;
}

static uint32_t trained_tempo(MetronomeRenderer *r) {
    MetronomeRenderSettings *s = &r->settings;
    if (!s->trainerBars || !s->trainerStep || s->trainerTarget < s->trainerStart) return s->bpm;
    if (s->trainerStart < 20 || s->trainerTarget > 300) return s->bpm;
    if (r->bar < r->trainerFirstBar) return r->tempo ? r->tempo : s->bpm;
    uint64_t steps = (r->bar - r->trainerFirstBar) / s->trainerBars;
    uint64_t tempo = s->trainerStart + steps * s->trainerStep;
    return tempo < s->trainerTarget ? (uint32_t)tempo : s->trainerTarget;
}

static Click click(MetronomeRenderer *r, uint32_t sound, uint32_t accent, uint32_t beat, bool subdivision) {
    float gain = subdivision ? 0.50f : accent == 0 ? 1.0f : accent == 1 ? 0.88f : 0.75f;
    if (sound == 3 && !subdivision) {
        uint32_t count = (uint32_t)atomic_load(&r->voiceCounts[beat]);
        if (count) return (Click){r->voices[beat], count, 0, gain};
    }
    if (sound > 2) sound = 2;
    return (Click){r->tones[sound][accent], r->toneFrames, 0, gain};
}

static float sample(Click *click) {
    if (click->position >= click->count) return 0;
    return click->samples[click->position++] * click->gain;
}

static double pulse_offset(uint32_t rhythm, uint32_t pulse) {
    static const double offsets[][4] = {
        {1, 1, 1, 1}, {.5, 1, 1, 1}, {1.0/3, 2.0/3, 1, 1},
        {.25, .5, .75, 1}, {.75, 1, 1, 1}, {.25, .75, 1, 1}, {2.0/3, 1, 1, 1}
    };
    return rhythm < 7 && pulse < 4 ? offsets[rhythm][pulse] : 1;
}

void metronome_render(MetronomeRenderer *r, float *left, float *right, uint32_t frames, double host) {
    read_settings(r);
    const MetronomeRenderSettings *s = &r->settings;
    const float leftGain = s->volume * (s->balance > 0 ? 1 - s->balance : 1);
    const float rightGain = s->volume * (s->balance < 0 ? 1 + s->balance : 1);
    for (uint32_t i = 0; i < frames; ++i, ++r->frame) {
        double frame = (double)r->frame;
        if (frame >= r->nextBeat) {
            r->tempo = trained_tempo(r);
            r->beatStart = r->nextBeat;
            r->beatDuration = r->sampleRate * 60.0 / r->tempo;
            r->nextBeat += r->beatDuration;
            r->pulse = 0;
            uint32_t cycle = s->audibleBars + s->silentBars;
            if (r->beat == 0) r->ghost = cycle && (r->bar % cycle) >= s->audibleBars;
            uint32_t accent = (uint32_t)(s->accents >> (r->beat * 2)) & 3;
            bool audible = !r->ghost && accent < 3;
            r->primary = audible ? click(r, s->sound, accent, r->beat, false) : (Click){0};
            r->secondary = (Click){0};
            publish(r, host < 0 ? -1 : host + i / r->sampleRate, r->beat, accent, audible);
            if (++r->beat == s->beats) {
                r->beat = 0;
                ++r->bar;
            }
        } else {
            double offset = pulse_offset(s->rhythm, r->pulse);
            if (offset < 1 && frame >= r->beatStart + offset * r->beatDuration) {
                uint32_t prior = r->beat ? r->beat - 1 : s->beats - 1;
                uint32_t accent = (uint32_t)(s->accents >> (prior * 2)) & 3;
                if (!r->ghost && accent < 3) r->secondary = click(r, s->sound, 2, prior, true);
                ++r->pulse;
            }
        }
        const float primary = sample(&r->primary);
        float secondary = sample(&r->secondary);
        if (primary * secondary > 0) secondary *= 1 - fabsf(primary);
        float value = primary + secondary;
        if (value > 1) value = 1;
        if (value < -1) value = -1;
        left[i] = value * leftGain;
        right[i] = value * rightGain;
    }
}
