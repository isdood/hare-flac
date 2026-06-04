### docs/4-multi-processing.md

**Objective**: Experiment with chunking audio to enable use of more cores while encoding.

## Overview

The current changes are experimental in nature & therefore fairly primitive. Currently, main.ha
now by default chunks audio into exactly 2 parts which are encoded by 2 workers & stitched together.
Further work will include support for more/dynamic workers to make use of 8-16 cores as well as 
lowering overhead of IO calls from writing to temp files + stitching together numerous files.

## Status

The 2 chunk experiment is functional & overall improves speeds, particularly with longer tracks.
