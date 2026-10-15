"""Device babble clips for Proximity Babble Chat (devices.lua): the babble0-7 syllables band-passed, as a typed line
babbles from a walkie-talkie, a megaphone or a PA.

    radio0-7  a walkie: 300-3000 Hz, driven into soft clipping, a little hiss (a radio device)
    horn0-7   a horn: 400-5000 Hz, a metallic resonance, harder drive (a loudspeaker or a PA)

    FFMPEG=<ffmpeg.exe> python tools/device_clips.py "mods/proximity chat/snd"
(numpy + scipy; ffmpeg decodes the .ogg clips and encodes the new ones). Made from the mod's own synthesized clips
(tools/babble_sounds.py), so no samples and no licence questions."""
import os, subprocess, sys
import numpy as np
from scipy.signal import butter, sosfilt, lfilter

SR = 44100
FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')


def read_ogg(path):
    raw = subprocess.run([FFMPEG, '-v', 'error', '-i', path, '-f', 's16le', '-ac', '1', '-ar', str(SR), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(float) / 32767


def write_ogg(path, y):
    pcm = (np.clip(y, -1, 1) * 32767).astype(np.int16).tobytes()
    subprocess.run([FFMPEG, '-v', 'error', '-y', '-f', 's16le', '-ac', '1', '-ar', str(SR), '-i', '-', '-c:a', 'libvorbis',
                    '-q:a', '4', path], input=pcm, check=True)


def band(y, lo, hi, order=4):
    return sosfilt(butter(order, [lo, hi], btype='band', fs=SR, output='sos'), y)


def resonator(x, f, bw):
    r = np.exp(-np.pi * bw / SR)
    return lfilter([1 - r], [1, -2 * r * np.cos(2 * np.pi * f / SR), r * r], x)


def norm(y, rms):
    """the same loudness (RMS) as the source clip, peaks kept under 0.95"""
    cur = np.sqrt(np.mean(y ** 2)) + 1e-9
    y = y * rms / cur
    peak = np.abs(y).max()
    return y * (0.95 / peak) if peak > 0.95 else y


def radio(x, seed):
    rng = np.random.default_rng(seed)
    y = band(x, 300, 3000)
    y = np.tanh(3.0 * y / (np.abs(y).max() + 1e-9))               # (driven: soft clipping)
    y = band(y, 300, 3000, 2)
    y = y + band(rng.normal(0, 0.03, len(y)), 1000, 6000, 2)       # (hiss)
    return y


def horn(x, seed):
    y = band(x, 400, 5000)
    y = y + 0.5 * resonator(y, 1700, 180) + 0.3 * resonator(y, 2900, 250)   # (the horn's ring)
    y = np.tanh(4.0 * y / (np.abs(y).max() + 1e-9))
    return band(y, 400, 5000, 2)


def main(snd):
    for i in range(8):
        x = read_ogg(os.path.join(snd, f'babble{i}.ogg'))
        rms = np.sqrt(np.mean(x ** 2))
        write_ogg(os.path.join(snd, f'radio{i}.ogg'), norm(radio(x, i), rms))
        write_ogg(os.path.join(snd, f'horn{i}.ogg'), norm(horn(x, i), rms))
    print('wrote radio0-7, horn0-7 to', snd)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'mods/proximity chat/snd')
