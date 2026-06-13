# hare-flac

- A native Hare implementation of the FLAC (Free Lossless Audio Codec) specification.
- Works with 16bit & 24bit audio. Supports various sample rates.
- Verified lossless encoding/decoding via an MD5 check. 

## Features

* **LPC Analysis**: Levinson-Durbin recursion for optimal coefficient generation.
* **Fixed Predictors**: Support for FLAC fixed predictor orders 0-4.
* **High Precision**: Internal analysis performed in `f64` before being quantized to fixed-point integers for storage.

## Project Structure

This project utilizes a modular approach, leveraging standalone libraries:

* **`hare-wav`**: Handles WAV container parsing and sample streaming.
* **`hare-lpc`**: The core mathematical engine for signal prediction.

## Getting Started

### Prerequisites

* **Hare Compiler**: Version 0.26.0 or later.
* **Environment**: Ensure your `HAREPATH` includes the `src` and `vendor` directories.
* **Symlink Dependencies**: Execute the following to properly symlink required dependencies to the vendor/ dir:

```bash
ln -s ~/path/to/hare-wav/src/wav vendor/wav
ln -s ~/path/to/hare-lpc/src/lpc vendor/lpc

```

### Running Tests

Execute the test suite to verify autocorrelation, predictor logic, and Levinson-Durbin stability. 
The repo is still under construction, therefore the test suite should be expected to change 
drastically & doesn't currently cover enough:

```bash
hare test

```

### Building flac-enc & flac-dec

To build the flac encoder & decoder:

```bash
make
```
And to use the resulting binaries:

```bash
./flac-enc example.wav output.flac
```

or:

```bash
./flac-dec example.flac output.wav
```

## Implementation Details

The codec follows the standard FLAC analysis flow:

1. **Windowing**: Applying a Hann window to reduce spectral leakage.
2. **Autocorrelation**: Calculating signal correlation across lags $R(0) \dots R(p)$.
3. **Recursion**: Solving Yule-Walker equations via Levinson-Durbin.
4. **Quantization**: Converting optimal coefficients to 12-15 bit integers.
5. **Residual Calculation**: Generating the difference signal via integer-domain prediction.

## Notes

- This project is to learn about audio encoding, decoding, the FLAC specification as a whole & the Hare language.

The recent changes surrounding multi-processing are experimental, though I haven't encountered
any issues yet. Compression ratios are comparable to libFLAC & ffmpeg (within ~2% on average, 
though some tracks compress to an equal size). Depending on core count, encoding speeds are comparable, 
notably at 32 workers a 7 minute track encodes in less than a second (9950X CPU).

FLAC decoding is the least tested bit of code as things stand. Decoding has been made into a separate
binary for now to keep concerns isolated. The multi-process design is currently functional & rather
quick on a 16 core CPU, though needs further testing to ensure no breaking cases.
