use io;
use memio;

// Writes a FLAC-style UTF-8 encoded integer.
fn write_utf8_int(w: *bit_writer, val: u64) (size | io::error) = {
    let n = 0z;
    // FLAC UTF-8 integers are written as whole bytes.
    // If the bit_writer is not aligned, these will span byte boundaries.
    if (val < 0x80) {
        n += write_bits(w, val, 8)?;
    } else if (val < 0x800) {
        n += write_bits(w, 0xC0 | (val >> 6), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    } else if (val < 0x10000) {
        n += write_bits(w, 0xE0 | (val >> 12), 8)?;
        n += write_bits(w, 0x80 | ((val >> 6) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    } else {
        n += write_bits(w, 0xF0 | (val >> 18), 8)?;
        n += write_bits(w, 0x80 | ((val >> 12) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | ((val >> 6) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    };
    return n;
};

export fn write_frame_header(
    w: *bit_writer,
    block_size: u16,
    sample_rate: u32,
    bps: u8,
    channels: u8,
    frame_num: u32,
) (size | io::error) = {
    let total_bits = 0z;
    reset_crc8(w);

    // 1. Sync (14 bits: 11111111 111110) + Reserved (0) + Blocking (0 = Fixed)
    total_bits += write_bits(w, 0x3FFE, 14)?;
    total_bits += write_bits(w, 0, 2)?;

    // 2. Block size code (4 bits)
    // 0b1100 is 4096. You should eventually map 'block_size' to this code.
    total_bits += write_bits(w, 0b1100, 4)?;

    // 3. Sample rate code (4 bits)
    // 0b1001 is 44.1kHz.
    total_bits += write_bits(w, 0b1001, 4)?;

    // 4. Channel Assignment (4 bits)
    const chan_code = if (channels == 2) 0b0001u64 else 0b0000u64;
    total_bits += write_bits(w, chan_code, 4)?;

    // 5. Sample Size (3 bits) + Reserved (1 bit)
    const sz_code = if (bps == 16) 0b100u64 else 0b110u64;
    total_bits += write_bits(w, sz_code, 3)?;
    total_bits += write_bits(w, 0, 1)?;

    // 6. Frame Number
    // According to FLAC spec, for fixed blocking (strategy 0),
    // this field contains the frame number, not the sample number.
    total_bits += write_utf8_int(w, frame_num: u64)?;

    // 7. CRC-8 Calculation
    // CRITICAL: The CRC-8 is calculated over everything from the Sync to
    // the end of the Frame/Sample number. We must ensure the bit_writer
    // has processed these bits into bytes before calculating.

    // Most encoders flush to a byte boundary here if not already aligned.
    // We capture the CRC-8 accumulated by the writer.
    const header_crc = w.crc8;

    // 8. Write the 8-bit CRC-8
    total_bits += write_bits(w, header_crc: u64, 8)?;

    return total_bits;
};
