### docs/3-md5-verification.md

**Objective**: Verify lossless audio compression by confirming the decoded PCM audio payload MD5 hash matches the original source.

## Overview

- This will both serve as an explanation for how I verified the lossless nature of hare-flac as well as explain how others can verify themselves.
- Hare has no MD5 implementation in the stdlib, so I relied on ffmpeg (rather than an automated/Hare native implementation).
- This was done on NixOS with the 'flac' and 'ffmpeg' packages. Depending on your distro these package names may differ.

## Process

Start with a sample WAV file. We'll call it 'example.wav'. Use flac-enc (compiled as per the README) to encode 'example.wav' to FLAC:

```bash
./flac-enc example.wav output.flac
```

We'll now use the reference 'flac' decoder to decode 'output.flac' *back* into a WAV file ('reference.wav'):

```bash
flac -d output.flac -o reference.wav
```

Get the MD5 hash of the raw audio data from the *original* WAV ('example.wav'):

```bash
ffmpeg -v error -i example.wav -f md5 -
```

Now, do the same to 'reference.wav':

```bash
ffmpeg -v error -i reference.wav -f md5 -
```

The last two commands should produce identical MD5 hashes. This shows hare-flac can encode FLAC & be decoded back to WAV in a 100% lossless manner. No data is lost in the round trip.
