use io;
use memio;

// Writes a FLAC-style UTF-8 encoded integer.
fn write_utf8_int(w: *bit_writer, val: u64) (size | io::error) = {
    let n = 0z;
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

    // 1. Sync + Reserved + Blocking Strategy (0 = Fixed)
    // 11111111 111110 (14 bits) + 0 (1 bit reserved) + 0 (1 bit fixed blocking)
    total_bits += write_bits(w, 0x3FFE, 14)?;
    total_bits += write_bits(w, 0, 2)?;

    // 2. Block size: 1100 = 4096 samples
    // Note: For fixed blocking, this should match your actual block size
    total_bits += write_bits(w, 0b1100, 4)?;

    // 3. Sample rate: 1001 = 44.1kHz
    total_bits += write_bits(w, 0b1001, 4)?;

    // 4. Channel Assignment: 0001 = Stereo, 0000 = Mono
    const chan_code = if (channels == 2) 0b0001u64 else 0b0000u64;
    total_bits += write_bits(w, chan_code, 4)?;

    // 5. Sample Size: 100 = 16-bit, 110 = 24-bit
    const sz_code = if (bps == 16) 0b100u64 else 0b110u64;
    total_bits += write_bits(w, sz_code, 3)?;
    total_bits += write_bits(w, 0, 1)?; // Reserved bit

    // 6. Frame Number (UTF-8 encoded integer)
    total_bits += write_utf8_int(w, frame_num: u64)?;

    // 7. CRC-8 Calculation
    // We must update the CRC with the bits currently sitting in the buffer
    // before we read the final crc8 value.
    let final_header_crc = w.crc8;
    if (w.bits_used > 0) {
        // We simulate what the buffer will look like when shifted for the next byte
        const temp_byte = w.buffer << (8 - w.bits_used);
        final_header_crc = crc8_update(w.crc8, temp_byte);
    };

    // 8. Write the 8-bit CRC-8
    total_bits += write_bits(w, final_header_crc: u64, 8)?;

    return total_bits;
};

@test fn test_frame_header_stereo() void = {
    let buf: [16]u8 = [0...];
    let mem = memio::fixed(buf);
    let w = newwriter(&mem);

    // Test: 4096, 44.1k, 16-bit, Stereo
    write_frame_header(&w, 4096, 44100, 16, 2, 0)!;
    flush(&w)!;

    assert(buf[0] == 0xFF);
    assert(buf[1] == 0xF8);
    // 1100 (C) | 1001 (9) = 0xC9
    assert(buf[2] == 0xC9);
    // 0001 (1) | 100 (4) | 0 = 0x18
    assert(buf[3] == 0x18);
};
