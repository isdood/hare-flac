### docs/4-multi-processing.md

**Objective**: Experiment with chunking audio to enable use of more cores while encoding.

## Overview

The current changes are experimental in nature & therefore fairly primitive. Currently, main.ha
now by default chunks audio into N parts which are encoded by N workers & stitched together.
Further work will include support for automatic profiling of CPU core count to set N dynamically.

## Status

Scaled up to dynamic worker count. Encoding speed gains are incredible. A ~7 minute track before would
have taken on average ~10s to encode, while with 32 workers the same track encodes in less than a second.
I've currently been testing with hardcoded worker counts, though will shift it towards a dynamic system
based on system core-count.

## Notes

It's worth noting I'm testing this on a machine with 16 cores (32 threads), DDR5 RAM & NVME storage.
Performance characteristics and design choices were decided with these in mind.
