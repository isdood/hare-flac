### docs/2-metadata-and-compliance.md

**Objective**: Transform the raw bitstream into a compliant FLAC file by implementing mandatory metadata headers and checksum verification.

---

## 1. Global Metadata (STREAMINFO)

A valid FLAC file must begin with a specific identification sequence and a metadata block that describes the audio properties to the decoder.

* **The "fLaC" Magic Number**: A 32-bit marker (`0x664C6143`) to identify the file format.
* **STREAMINFO Block**: The primary metadata header containing:
* Sample rate, channel count, and bit depth.
* Total samples and MD5 signature of the uncompressed audio.
* Minimum and maximum block/frame sizes.



---

## 2. Integrity & Checksums

Decoders use Cyclic Redundancy Checks (CRCs) to verify that the bitstream has not been corrupted. Without these, most players will reject the frames.

* **CRC-8**: Applied to the Frame Header ($x^8 + x^2 + x^1 + 1$).
* **CRC-16**: Applied to the entire encoded frame ($x^{16} + x^{15} + x^2 + 1$).
* **Implementation**: We must calculate these values "on-the-fly" as bits are pushed through the `bit_writer`.

---

## 3. Implementation Requirements

| Module | Core Responsibility |
| --- | --- |
| `metadata.ha` | Writing the `fLaC` marker and `STREAMINFO` blocks. |
| `crc.ha` | Logic for bit-wise CRC calculation for both 8-bit and 16-bit polynomials. |

---

## 4. Verification Milestone

* **FFprobe Validation**: The generated `.flac` file should be successfully parsed by `ffprobe` or `metaflac` without errors.
* **Sync & Playback**: The file must be playable in standard media players (e.g., `vlc`, `ffplay`), confirming the headers and CRCs are valid.

---
