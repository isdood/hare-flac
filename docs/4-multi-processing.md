### docs/4-multi-processing.md

**Objective**: Experiment with chunking audio to enable use of more cores while encoding.

## Overview

Audio is chunked into sections and distributed to workers for encoding. Chunk count is dynamic based
on a machines core count. Drastically improves encoding speeds on multi-core machines. 

## Status

Worker count is dynamically set based on a machines core count. A ~7 minute track before would
have taken on average ~10s to encode as a single process, while with 32 workers the same track 
encodes in less than a second. I've not encountered any buggy or problem files as of yet, all have 
encoded and played back without issue.

## Notes

I'm testing this on a machine with 16 cores (32 threads), DDR5 RAM & NVME storage.
Performance characteristics and design choices were decided with these in mind.
