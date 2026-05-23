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

// Writes up to 64 bits from a value.
export fn write_bits(w: *bit_writer, value: u64, count: u8) (size | io::error) = {
    let total_written = 0z;
    for (let i = 0u8; i < count; i += 1) {
        const bit_idx = count - i - 1;
        const bit = ((value >> bit_idx) & 1): u8;

        w.buffer = (w.buffer << 1) | bit;
        w.bits_used += 1;
        if (w.bits_used == 8) {
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

// Writes 'count' zero bits efficiently. Optimized for unary Rice coding.
export fn write_zeros(w: *bit_writer, count: u32) (size | io::error) = {
    if (count == 0) return 0z;
    let total_written = 0z;
    let remaining_bits = count;

    // Phase 1: Clear out any unaligned pending bits in the buffer
    if (w.bits_used > 0) {
        const bits_to_fill = 8 - w.bits_used;
        if (remaining_bits < bits_to_fill: u32) {
            // Not enough zeros to finish the byte; just shift them in
            w.buffer <<= remaining_bits: u8;
            w.bits_used += remaining_bits: u8;
            return 0z;
        };

        w.buffer <<= bits_to_fill;
        w.crc8 = crc8_update(w.crc8, w.buffer);
        w.crc16 = crc16_update(w.crc16, w.buffer);

        const b: [1]u8 = [w.buffer];
        total_written += io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
        remaining_bits -= bits_to_fill: u32;
    };

    // Phase 2: Write bulk zero bytes directly to the handle
    const zero_bytes = remaining_bits / 8;
    if (zero_bytes > 0) {
        let zeros_buf: [512]u8 = [0...];
        let bytes_left = zero_bytes: size;

        for (bytes_left > 0) {
            const chunk = if (bytes_left < len(zeros_buf)) bytes_left else len(zeros_buf);

            for (let i = 0z; i < chunk; i += 1) {
                w.crc8 = crc8_update(w.crc8, 0);
                w.crc16 = crc16_update(w.crc16, 0);
            };

            total_written += io::write(w.handle, zeros_buf[..chunk])?;
            bytes_left -= chunk;
        };
        remaining_bits %= 8;
    };

    // Phase 3: Queue up any leftover bits (0 to 7)
    if (remaining_bits > 0) {
        w.buffer = 0;
        w.bits_used = remaining_bits: u8;
    };

    return total_written;
};

// Writes raw byte blocks directly, automatically managing unaligned pending bits.
export fn write_bytes(w: *bit_writer, bytes: []u8) (size | io::error) = {
    if (len(bytes) == 0) return 0z;

    // If there are unaligned bits in the buffer, they MUST be cleared first
    // to maintain sequence integrity before writing raw blocks.
    if (w.bits_used > 0) {
        const final_byte = w.buffer << (8 - w.bits_used);
        w.crc8 = crc8_update(w.crc8, final_byte);
        w.crc16 = crc16_update(w.crc16, final_byte);
        const b: [1]u8 = [final_byte];
        io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
    };

    for (let i = 0z; i < len(bytes); i += 1) {
        w.crc8 = crc8_update(w.crc8, bytes[i]);
        w.crc16 = crc16_update(w.crc16, bytes[i]);
    };

    return io::write(w.handle, bytes);
};

// Aligns to the next byte boundary using MSB-padding. Excluded from FLAC CRCs.
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

// Specialized flush for the Frame Header. Final byte MUST be in CRC-8.
export fn flush_header(w: *bit_writer) (size | io::error) = {
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);
        w.crc8 = crc8_update(w.crc8, w.buffer);
        const b: [1]u8 = [w.buffer];
        const n = io::write(w.handle, b)?;
        w.buffer = 0;
        w.bits_used = 0;
        return n;
    };
    return 0z;
};

// Finalizes the entire frame. Final byte MUST be included in CRC-16.
export fn finalize_frame(w: *bit_writer) u16 = {
    const final_crc = w.crc16;
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);
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

export fn bits_pending(w: *bit_writer) u8 = {
    return w.bits_used;
};

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
