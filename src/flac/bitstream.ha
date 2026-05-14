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

// A standard flush for subframes or entropy coding.
// Aligns to the next byte boundary using MSB-padding.
// Does NOT update CRCs (padding bits are excluded from FLAC CRCs).
export fn flush(w: *bit_writer) (size | io::error) = {
    if (w.bits_used > 0) {
        const final_byte = w.buffer << (8 - w.bits_used);
        const b: [1]u8 = [final_byte];
        const n = io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
        return n;
    };
    return 0z;
};

// Specialized flush for the Frame Header.
// FLAC requires the Frame Header CRC-8 to cover the ENTIRE header.
// If the header ends on a partial byte, that byte MUST be in the CRC.
export fn flush_header(w: *bit_writer) (size | io::error) = {
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);

        // FIX: The padded final byte of the header MUST be in CRC-8
        w.crc8 = crc8_update(w.crc8, w.buffer);

        const b: [1]u8 = [w.buffer];
        const n = io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
        return n;
    };
    return 0z;
};

// Finalizes the entire frame.
// Similar to flush_header, the final byte must be included in the CRC-16.
export fn finalize_frame(w: *bit_writer) u16 = {
    const final_crc = w.crc16;
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);

        // FIX: The final byte of the frame MUST be included in CRC-16
        w.crc16 = crc16_update(w.crc16, w.buffer);

        const b: [1]u8 = [w.buffer];
        io::write(w.handle, b)!;
        w.buffer = 0;
        w.bits_used = 0;
        return w.crc16;
    };
    return final_crc;
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

    // FIX: Remove 'flac::' because we are already inside the flac package
    flush(&w)!;

    assert(buf[0] == 0xb1);
    assert(buf[1] == 0x80);
};
