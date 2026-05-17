# hare-flac

A native Hare implementation of the FLAC (Free Lossless Audio Codec) specification. This project focuses on reconstruction using Linear Predictive Coding (LPC). The project is currently in a useable state for 16bit .wav to .flac conversions.

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

Execute the test suite to verify autocorrelation, predictor logic, and Levinson-Durbin stability. The repo is still under construction, therefore the test suite should be expected to change drastically & may not currently cover enough:

```bash
hare test

```

### Building flac-enc

To build the flac encoder (converts a .wav to .flac):

```bash
make

```
And to use the resulting binary:

```bash
./flac-enc example.wav output.flac
```

## Implementation Details

The codec follows the standard FLAC analysis flow:

1. **Windowing**: Applying a Hann window to reduce spectral leakage.
2. **Autocorrelation**: Calculating signal correlation across lags $R(0) \dots R(p)$.
3. **Recursion**: Solving Yule-Walker equations via Levinson-Durbin.
4. **Quantization**: Converting optimal coefficients to 12-15 bit integers.
5. **Residual Calculation**: Generating the difference signal via integer-domain prediction.

