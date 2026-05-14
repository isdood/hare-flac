use io;
use wav;

// Writes the mandatory "fLaC" marker and the STREAMINFO block.
export fn write_stream_header(w: *bit_writer, dec: *wav::decoder) (size | io::error) = {
    let total_bits = 0z;

    // 1. "fLaC" Magic Number (32 bits)
    // Encodes the ASCII string "fLaC".
    total_bits += write_bits(w, 0x664C6143, 32)?;

    // 2. Metadata Block Header
    // Last-block flag (1 bit) | Block type (7 bits, 0 = STREAMINFO) | Length (24 bits)
    total_bits += write_bits(w, 1, 1)?; // Last metadata block flag
    total_bits += write_bits(w, 0, 7)?; // Type 0 is STREAMINFO
    total_bits += write_bits(w, 34, 24)?; // STREAMINFO payload is always 34 bytes

    // 3. STREAMINFO Payload
    // Min/Max Block Size (16 bits each)
    total_bits += write_bits(w, 4096, 16)?;
    total_bits += write_bits(w, 4096, 16)?;

    // Min/Max Frame Size (24 bits each) - 0 indicates unknown
    total_bits += write_bits(w, 0, 24)?;
    total_bits += write_bits(w, 0, 24)?;

    // Sample rate (20 bits)
    total_bits += write_bits(w, dec.meta.rate: u64, 20)?;

    // Channels (3 bits, value is channels-1)
    total_bits += write_bits(w, (dec.meta.channels - 1): u64, 3)?;

    // Bits per sample (5 bits, value is bps-1)
    total_bits += write_bits(w, (dec.meta.bit_depth - 1): u64, 5)?;

    // 4. Total samples (36 bits)
    // FIX: Calculate total samples from WAV data size to prevent DTS mismatch warnings.
    const bytes_per_sample = (dec.meta.bit_depth / 8): u32;
    const total_samples = dec.data_size / (dec.meta.channels: u32 * bytes_per_sample);
    total_bits += write_bits(w, total_samples: u64, 36)?;

    // 5. MD5 signature (128 bits) - Placeholder zeros
    total_bits += write_bits(w, 0, 64)?;
    total_bits += write_bits(w, 0, 64)?;

    return total_bits;
};
