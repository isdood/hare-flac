use io;
use memio;

// A bit-oriented writer that wraps a standard io::handle.
export type bit_writer = struct {
    handle: io::handle,
    buffer: u8,
    bits_used: u8,
    crc8: u8,   // Track CRC-8 for headers
    crc16: u16,  // Track CRC-16 for frames
};

// Initializes a new bit_writer.
export fn newwriter(h: io::handle) bit_writer = {
    return bit_writer {
        handle = h,
        buffer = 0,
        bits_used = 0,
        crc8 = 0,
        crc16 = 0,
    };
};

export fn write_bits(w: *bit_writer, value: u64, count: u8) (size | io::error) = {
    let total_written = 0z;
    for (let i = 0u8; i < count; i += 1) {
        const bit_idx = count - i - 1;
        const bit = ((value >> bit_idx) & 1): u8;

        w.buffer = (w.buffer << 1) | bit;
        w.bits_used += 1;

        if (w.bits_used == 8) {
            // Update CRCs ONLY with completed bytes
            w.crc8 = crc8_update(w.crc8, w.buffer);
            w.crc16 = crc16_update(w.crc16, w.buffer);

            const b: [1]u8 = [w.buffer];
            total_written += io::write(w.handle, b)?;
            w.buffer = 0;
            w.bits_used = 0;
        };
    };
    return total_written;
};

export fn finalize_frame(w: *bit_writer) u16 = {
    const final_crc = w.crc16;
    if (w.bits_used > 0) {
        // Shift bits to align to the MSB of the byte
        w.buffer <<= (8 - w.bits_used);

        // CRITICAL: Do NOT update w.crc16 or w.crc8 here.
        // Padding bits are NOT part of the CRC calculation in FLAC.

        const b = [w.buffer];
        io::write(w.handle, b)!;
        w.buffer = 0;
        w.bits_used = 0;
    };
    return final_crc;
};

export fn flush(w: *bit_writer) (size | io::error) = {
    if (w.bits_used > 0) {
        // Shift remaining bits to the MSB as required by FLAC padding
        const final_byte = w.buffer << (8 - w.bits_used);

        // DO NOT update w.crc8 or w.crc16 here.
        // Padding bits are not part of the FLAC CRC calculation.

        const b: [1]u8 = [final_byte];
        const n = io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
        return n;
    };
    return 0z;
};

export fn reset_crc8(w: *bit_writer) void = { w.crc8 = 0; };
export fn reset_crc16(w: *bit_writer) void = { w.crc16 = 0; };

@test fn test_bit_writer() void = {
    let buf: [2]u8 = [0...];
    let mem = memio::fixed(buf);
    let w = newwriter(&mem);

    write_bits(&w, 0b1011, 4)!;
    write_bits(&w, 0b0001, 4)!;

    write_bits(&w, 0b1, 1)!;
    flush(&w)!;

    assert(buf[0] == 0xb1);
    assert(buf[1] == 0x80);
};
