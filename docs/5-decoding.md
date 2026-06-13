### docs/5-decoding.md

**Objective**: Implement a FLAC decoder to covert FLAC to WAV

## Overview

Separate from flac-enc to keep concerns isolated, though will likely consider building into a single 
dual-purpose binary when the encoding pipeline is sufficiently performant & reliable.

## Status

Functionally decoding FLAC to WAV. Process count will scale with song duration (ie. a shorter song 
will result in fewer workers than a long song) up to core saturation - ie. a CPU with 16 cores &
hyper-threading will at most spawn 32 workers. Fairly fast on a 9950X with 32 workers, with ~7 mins
of FLAC decoding in 0.18s.
