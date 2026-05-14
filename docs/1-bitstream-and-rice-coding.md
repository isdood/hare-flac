### docs/1-bitstream-and-rice-coding.md

**Objective**: Implement the bit-oriented I/O and Rice/Golomb entropy coding required to compress LPC residuals into the FLAC format.

---

## 1. The Entropy Coding Challenge

LPC analysis gives us small integer residuals, but they are still stored in 32-bit containers. To achieve actual compression, we use **Rice Coding**.

* **Rice Parameter ($s$)**: A value that determines how many bits are used for the "remainder" of the residual.
* **Unary Coding**: The quotient is stored as a series of 1s followed by a 0.
* **Binary Coding**: The remainder is stored as raw bits.

This method is extremely efficient for data that follows a Laplacian distribution (which audio residuals do).

---

## 2. Bit-Oriented I/O

Standard Hare `io` handles data in bytes. FLAC requires writing at the bit level (e.g., a 14-bit coefficient followed by a 3-bit Rice parameter).

* **Requirement**: Implement a `bit_writer` that buffers bits and flushes them to an underlying `io::handle` once a full byte is formed.
* **Functionality**:
* `write_bits(w: *bit_writer, value: u64, count: u8) void`
* `flush(w: *bit_writer) void` (including padding to the next byte boundary).



---

## 3. Implementation Requirements

* **`src/flac/bitstream.ha`**: The low-level bit-packing logic.
* **`src/flac/entropy.ha`**: The Rice coding implementation.
* **Rice Parameter Optimization**: A function to find the optimal $s$ for a given block of residuals to ensure the smallest possible bitstream size.

---

## 4. Verification Milestone

* **Bitstream Test**: Write a known pattern of bits (e.g., `0b1011`, `0b0`, `0b111`) and verify the resulting bytes match the expected binary output.
* **Rice Round-trip**: A residual value $r$ encoded with parameter $s$ and then decoded must equal $r$ exactly.
* **Compression Metric**: Compare the size of the raw `i32` residuals vs. the Rice-coded bitstream.

---
