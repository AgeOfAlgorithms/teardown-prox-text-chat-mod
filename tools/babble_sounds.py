"""Babble-voice clips for Proximity Chat (chat_core.lua):
    babble0-7  syllables (nearby / everyone)
    shout0-7   ALL-CAPS words, harsh
    robot0-3   the Robot voice
    whisper0-7 whispers: breathy, unvoiced (noise through the same vowel formants, no pitch pulse)
    rwhisper0-3 the Robot voice's whisper: a quiet filtered, bit-crushed hiss

    python babble_sounds.py <mod>/snd [--only whisper] [--preview export/whisper_preview.wav]
(numpy + scipy; ffmpeg on PATH or in FFMPEG for the .ogg files; the preview is a plain .wav)
Synthesized (no samples, no licence questions). Copied from the teardown-modding skill's
reference/babble_sounds.py and extended with the whisper clips."""
import os, subprocess, sys, wave
import numpy as np

SR = 44100
FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')


# vowel formants (F1, F2, F3) in Hz
VOWELS = {'a': (800, 1200, 2500), 'e': (500, 1850, 2500), 'i': (320, 2300, 3000), 'o': (500, 900, 2400), 'u': (350, 750, 2300)}


def resonator(x, f, bw):
    """A 2-pole resonant filter (one formant)."""
    from scipy.signal import lfilter
    r = np.exp(-np.pi * bw / SR)
    a = [1, -2 * r * np.cos(2 * np.pi * f / SR), r * r]
    return lfilter([1 - r], a, x)


def babble(vowel='a', f0=210.0, dur=0.095, onset=None, seed=0):
    """One cartoon-voice syllable (Animal Crossing style): a glottal pulse train through the vowel's
    formants, a quick pitch fall, an optional consonant onset ('b' thump or 'd' tick). The game plays it
    at the speaker with a per-player pitch (PlaySound pitch)."""
    rng = np.random.default_rng(seed)
    n = int(SR * dur)
    t = np.arange(n) / SR
    f = f0 * (1.08 - 0.16 * t / dur)
    ph = np.cumsum(f) / SR
    src = (np.diff(np.floor(ph), prepend=0) > 0).astype(float)          # one pulse per period
    src = resonator(src, 120, 400) * 0.3 + src                           # (a softer glottal shape)
    y = sum(resonator(src, F, bw) * g for F, bw, g in zip(VOWELS[vowel], (90, 110, 160), (1.0, 0.6, 0.25)))
    env = np.minimum(1, t / 0.008) * np.minimum(1, (dur - t) / 0.03) ** 1.5
    y = y * env
    if onset == 'b':
        y[:int(SR * 0.012)] += np.sin(2 * np.pi * 110 * t[:int(SR * 0.012)]) * 0.8 * np.exp(-t[:int(SR * 0.012)] * 300)
    elif onset == 'd':
        k = int(SR * 0.006)
        y[:k] += resonator(rng.normal(0, 1, k), 3500, 1500) * 0.5
    y = y / np.abs(y).max()
    return (y * 0.8 * 32767).astype(np.int16)


def shout(vowel='a', f0=260.0, dur=0.1, onset=None, seed=0):
    """An angry syllable (ALL-CAPS words): the babble pushed harder - a steeper pitch fall, rasp (noise
    on the pulses) and soft-clipped, so it sounds strained and loud."""
    rng = np.random.default_rng(100 + seed)
    y = babble(vowel, f0, dur, onset, seed).astype(float) / 32767
    t = np.arange(len(y)) / SR
    y = y * (1 + 0.5 * rng.normal(0, 1, len(y)) * np.exp(-t * 20))     # rasp at the start
    y = np.tanh(y * 4.0)                                               # pushed into distortion
    y = y / np.abs(y).max()
    return (y * 0.9 * 32767).astype(np.int16)


def robot(f=520.0, dur=0.08, seed=0):
    """A robot syllable: a square-wave blip with a pitch step, bit-crushed."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    ff = np.where(t < dur * 0.45, f, f * (1.12 if seed % 2 else 0.9))
    ph = np.cumsum(ff) / SR
    y = np.sign(np.sin(2 * np.pi * ph)) * 0.6 + 0.4 * np.sin(2 * np.pi * 2 * ph)
    y = np.round(y * 6) / 6                                            # bit-crush
    env = np.minimum(1, t / 0.004) * np.minimum(1, (dur - t) / 0.015)
    return (y * env * 0.7 * 32767).astype(np.int16)


def whisper(vowel='a', dur=0.11, onset=None, seed=0):
    """A whispered syllable: no pitch pulse at all - white noise (breath) through the vowel's formants
    with wider bandwidths, a little high 'air', a soft attack and release, quiet. An onset 's' adds a
    short sibilant hiss, 't' a tiny unvoiced tick. PlaySound's pitch still moves the formants a bit,
    so the voices stay apart."""
    rng = np.random.default_rng(200 + seed)
    n = int(SR * dur)
    t = np.arange(n) / SR
    src = rng.normal(0, 1, n)
    y = sum(resonator(src, F, bw) * g for F, bw, g in zip(VOWELS[vowel], (180, 220, 300), (1.0, 0.75, 0.4)))
    y = y + resonator(src, 5200, 2800) * 0.12                          # air
    env = np.minimum(1, t / 0.028) ** 1.5 * np.minimum(1, (dur - t) / 0.045) ** 1.2
    y = y * env
    if onset == 's':
        k = int(SR * 0.03)
        hiss = resonator(rng.normal(0, 1, k), 6500, 2500) * np.minimum(1, np.arange(k) / (SR * 0.01))
        y[:k] += hiss / max(1e-9, np.abs(hiss).max()) * np.abs(y).max() * 0.6
    elif onset == 't':
        k = int(SR * 0.005)
        y[:k] += resonator(rng.normal(0, 1, k), 4000, 2000) * 0.3
    y = y / np.abs(y).max()
    return (y * 0.5 * 32767).astype(np.int16)


def robot_whisper(f=1800.0, dur=0.09, seed=0):
    """The Robot's whisper: band-passed noise, sample-and-hold decimated and bit-crushed (a quiet
    digital hiss), with a soft envelope."""
    rng = np.random.default_rng(300 + seed)
    n = int(SR * dur)
    t = np.arange(n) / SR
    y = resonator(rng.normal(0, 1, n), f, 900)
    hold = 4 + seed % 3                                                # sample-and-hold: crunchy
    y = np.repeat(y[::hold], hold)[:n]
    y = y / np.abs(y).max()
    y = np.round(y * 4) / 4                                            # bit-crush
    env = np.minimum(1, t / 0.015) * np.minimum(1, (dur - t) / 0.03)
    return (y * env * 0.4 * 32767).astype(np.int16)


def write(out, name, y):
    os.makedirs(out, exist_ok=True)
    wav = os.path.join(out, name + '.wav')
    with wave.open(wav, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(y.tobytes())
    subprocess.run([FFMPEG, '-y', '-loglevel', 'error', '-i', wav, '-c:a', 'libvorbis', '-q:a', '5', os.path.join(out, name + '.ogg')], check=True)
    os.remove(wav)


SYL = [('a', 'b'), ('e', None), ('i', 'd'), ('o', 'b'), ('u', None), ('a', 'd'), ('e', 'b'), ('o', None)]
WSYL = [('a', 's'), ('e', None), ('i', 't'), ('o', 's'), ('u', None), ('a', 't'), ('e', 's'), ('o', None)]


def whisper_clips():
    return [whisper(v, 0.1 + 0.01 * (i % 3), on, i) for i, (v, on) in enumerate(WSYL)]


def robot_whisper_clips():
    return [robot_whisper(f, 0.08 + 0.01 * (i % 2), i) for i, f in enumerate([1500, 1800, 2100, 2400])]


def pitched(y, pitch):
    """What PlaySound(..., pitch) does, roughly: resample (faster and higher)."""
    y = y.astype(float)
    n = max(1, int(len(y) / pitch))
    return np.interp(np.arange(n) * pitch, np.arange(len(y)), y)


def preview(path):
    """A listening test: the phrase 'Hello there, how are you?' (9 syllables, as the game spaces them)
    said normally by Plain, then whispered by Plain, Squeaky, Deep and Robot, at the game's relative
    volumes (babble 0.75; whisper 0.45; Robot 35 % for its normal voice)."""
    rng = np.random.default_rng(7)
    babbles = [babble(v, 210, 0.09 + 0.01 * (i % 3), on, i) for i, (v, on) in enumerate(SYL)]
    robots = [robot(f, 0.07 + 0.01 * (i % 2), i) for i, f in enumerate([480, 560, 640, 720])]
    wh, rwh = whisper_clips(), robot_whisper_clips()
    phrase = [3, 5, 0, 1, 6, 2, 4, 7, 2]                               # syllable variants
    pauses = [0, 0.05, 0.16, 0, 0.05, 0, 0.05, 0, 0]                   # spaces / punctuation
    # (label, clips, pitch, s per syllable, volume)
    takes = [('Plain normal', babbles, 1.0, 0.075, 0.75), ('Plain whisper', wh, 1.0, 0.0825, 0.45),
             ('Squeaky whisper', wh, 1 + 0.45 * 0.6, 0.068, 0.45), ('Deep whisper', wh, 1 - 0.36 * 0.6, 0.101, 0.45),
             ('Robot normal', robots, 1.0, 0.07, 0.75 * 0.35), ('Robot whisper', rwh, 1.0, 0.077, 0.45)]
    total = np.zeros(int(SR * 14))
    pos = 0.3
    for label, clips, pitch, step, vol in takes:
        for k, (var, pause) in enumerate(zip(phrase, pauses)):
            y = pitched(clips[var % len(clips)], pitch * (0.94 + 0.12 * rng.random()) * (1 + 0.08 * max(0, k - 5))) / 32767
            i0 = int(pos * SR)
            total[i0:i0 + len(y)] += y * vol
            pos += step + pause
        pos += 0.8
    total = total[:int(pos * SR)]
    total = np.clip(total, -1, 1)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((total * 32767).astype(np.int16).tobytes())
    print('preview:', path, '(%.1f s):' % pos, ', '.join(t[0] for t in takes))


if __name__ == '__main__':
    args = sys.argv[1:]
    only = args[args.index('--only') + 1] if '--only' in args else None
    prev = args[args.index('--preview') + 1] if '--preview' in args else None
    pos = [a for i, a in enumerate(args) if not a.startswith('--') and (i == 0 or not args[i - 1].startswith('--'))]
    out = pos[0] if pos else 'snd'
    n = 0
    if only in (None, 'voice'):
        for i, (v, on) in enumerate(SYL):
            write(out, 'babble%d' % i, babble(v, 210, 0.09 + 0.01 * (i % 3), on, i))
            write(out, 'shout%d' % i, shout(v, 250, 0.1 + 0.01 * (i % 3), on, i))
        for i, f in enumerate([480, 560, 640, 720]):
            write(out, 'robot%d' % i, robot(f, 0.07 + 0.01 * (i % 2), i))
        n += 20
    if only in (None, 'whisper'):
        for i, y in enumerate(whisper_clips()):
            write(out, 'whisper%d' % i, y)
        for i, y in enumerate(robot_whisper_clips()):
            write(out, 'rwhisper%d' % i, y)
        n += 12
    print('wrote %d clips to' % n, out)
    if prev:
        preview(prev)
