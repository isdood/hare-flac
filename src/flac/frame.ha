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
    const chan_code = if (channels == 2) 0b0001u8 else 0b0000u8;
    return write_frame_header_ext(w, block_size, sample_rate, bps, chan_code, frame_num);
};

// Extended frame header function that explicitly accepts channel assignment codes
// for joint stereo configurations and handles variable block streaming.
export fn write_frame_header_ext(
    w: *bit_writer,
    block_size: u16,
    sample_rate: u32,
    bps: u8,
    channel_assignment: u8,
    frame_num: u32,
) (size | io::error) = {
    let total_bits = 0z;
    reset_crc8(w);

    // 1. Sync (14 bits) + Reserved (1 bit) + Blocking Strategy (1 bit)
    total_bits += write_bits(w, 0x3FFE, 14)?;
    total_bits += write_bits(w, 0, 1)?;
    total_bits += write_bits(w, 0, 1)?;

    // 2. Block size code
    const bs_code = if (block_size == 4096) 0b1100u64 else 0b0111u64;
    total_bits += write_bits(w, bs_code, 4)?;

    // 3. Sample rate code
    const sr_code: u64 = switch (sample_rate) {
        case 8000  => yield 0b0100;
        case 16000 => yield 0b0101;
        case 22050 => yield 0b0110;
        case 24000 => yield 0b0111;
        case 32000 => yield 0b1000;
        case 44100 => yield 0b1001;
        case 48000 => yield 0b1010;
        case 96000 => yield 0b1011;
        case 88200 => yield 0b0001;
        case 176400 => yield 0b0010;
        case 192000 => yield 0b0011;
        case       => yield 0b1100;
    };
    total_bits += write_bits(w, sr_code, 4)?;

    // 4. Channel Assignment
    total_bits += write_bits(w, channel_assignment: u64, 4)?;

    // 5. Sample Size + Reserved
    const sz_code = if (bps == 16) 0b100u64 else 0b110u64;
    total_bits += write_bits(w, sz_code, 3)?;
    total_bits += write_bits(w, 0, 1)?;

    // 6. Frame Number
    total_bits += write_utf8_int(w, frame_num: u64)?;

    // 7. Explicit block size trailer if code requires 16-bit literal tracking
    if (bs_code == 0b0111) {
        total_bits += write_bits(w, (block_size - 1): u64, 16)?;
    };

    // CRC-8 Calculation
    if (w.bits_used > 0) {
        const padding_bits = 8 - w.bits_used;
        total_bits += write_bits(w, 0, padding_bits)?;
    };

    const header_crc = w.crc8;
    total_bits += write_bits(w, header_crc: u64, 8)?;
    return total_bits;
};
