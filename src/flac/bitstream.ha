use io;
use memio;

// Output buffer size for the bit_writer. Bytes are accumulated here and
// flushed to the underlying handle in bulk, eliminating per-byte syscalls.
def OUTBUF_SIZE: size = 65536;

// A bit-oriented writer that wraps a standard io::handle.
export type bit_writer = struct {
    handle: io::handle,
    // Partial-byte accumulator. Bits are packed MSB-first into the low bits
    // of this field. Only the low `bits_used` bits are valid.
    buffer: u8,
    bits_used: u8,
    crc8: u8,
    crc16: u16,
    // Output buffer: complete bytes accumulate here before being flushed
    // to `handle` in a single bulk write.
    outbuf: [OUTBUF_SIZE]u8,
    outbuf_len: size,
};

// Initializes a new bit_writer.
export fn newwriter(h: io::handle) bit_writer = {
    return bit_writer {
        handle = h,
        buffer = 0,
        bits_used = 0,
        crc8 = 0,
        crc16 = 0,
        outbuf = [0...],
        outbuf_len = 0,
    };
};

// Drains the output buffer to the underlying handle.
fn flush_outbuf(w: *bit_writer) (void | io::error) = {
    if (w.outbuf_len == 0) return;
    io::write(w.handle, w.outbuf[..w.outbuf_len])?;
    w.outbuf_len = 0;
};

// Appends a complete byte to the output buffer, flushing to the handle
// first if the buffer is full. Updates CRC state.
fn emit_byte(w: *bit_writer, b: u8) (void | io::error) = {
    w.crc8 = crc8_update(w.crc8, b);
    w.crc16 = crc16_update(w.crc16, b);
    w.outbuf[w.outbuf_len] = b;
    w.outbuf_len += 1;
    if (w.outbuf_len == OUTBUF_SIZE) {
        flush_outbuf(w)?;
    };
};

// Writes up to 64 bits from a value, MSB first.
//
// Strategy: rather than looping bit-by-bit, use a 16-bit staging word.
// The existing partial byte sits in the high bits of `word`, and the new
// `count` bits are shifted in below it. Then, drain complete bytes from
// the top of `word` one at a time, leaving any partial remainder for the
// next call.
export fn write_bits(w: *bit_writer, value: u64, count: u8) (size | io::error) = {
    if (count == 0) return 0z;

    // Build a 16-bit staging word:
    //   [ existing bits_used partial bits | incoming count bits | padding ]
    // Shift `value` up so the new bits are MSB-aligned within the
    // remaining space, then merge with the partial byte already in `buffer`.
    let total_bits = w.bits_used + count;

    // Pack everything into a u64 working register.
    // Place `buffer` at the top, then the new bits immediately below.
    let word: u64 = (w.buffer: u64 << (count: u64))
                  | (value & ((1u64 << count) - 1));

    // `total_bits` is the number of valid bits in `word` starting from bit
    // (total_bits - 1) down to bit 0. Drain complete bytes from the MSB end.
    let bytes_written = 0z;
    for (total_bits >= 8) {
        total_bits -= 8;
        const byte = ((word >> total_bits) & 0xFF): u8;
        emit_byte(w, byte)?;
        bytes_written += 1;
    };

    // Store any remaining partial bits back into buffer.
    // `total_bits` is now 0..7.
    w.bits_used = total_bits;
    w.buffer = if (total_bits > 0) (word & ((1u64 << total_bits) - 1)): u8 else 0u8;

    return bytes_written;
};

// Writes 'count' zero bits efficiently. Optimized for unary Rice coding.
export fn write_zeros(w: *bit_writer, count: u32) (size | io::error) = {
    if (count == 0) return 0z;
    let total_written = 0z;
    let remaining_bits = count;

    // Phase 1: Fill out the partial byte if one is in progress.
    if (w.bits_used > 0) {
        const bits_to_fill = (8 - w.bits_used): u32;
        if (remaining_bits < bits_to_fill) {
            w.buffer <<= remaining_bits: u8;
            w.bits_used += remaining_bits: u8;
            return 0z;
        };
        w.buffer <<= bits_to_fill: u8;
        emit_byte(w, w.buffer)?;
        total_written += 1;
        w.buffer = 0;
        w.bits_used = 0;
        remaining_bits -= bits_to_fill;
    };

    // Phase 2: Emit whole zero bytes directly.
    const zero_bytes = remaining_bits / 8;
    if (zero_bytes > 0) {
        for (let i = 0u32; i < zero_bytes; i += 1) {
            emit_byte(w, 0)?;
            total_written += 1;
        };
        remaining_bits %= 8;
    };

    // Phase 3: Queue any leftover bits (0–7) into the partial buffer.
    if (remaining_bits > 0) {
        w.buffer = 0;
        w.bits_used = remaining_bits: u8;
    };

    return total_written;
};

// Writes raw byte blocks directly, managing unaligned pending bits.
export fn write_bytes(w: *bit_writer, bytes: []u8) (size | io::error) = {
    if (len(bytes) == 0) return 0z;

    // Flush any unaligned partial byte first to maintain bit ordering.
    if (w.bits_used > 0) {
        const final_byte = w.buffer << (8 - w.bits_used);
        emit_byte(w, final_byte)?;
        w.buffer = 0;
        w.bits_used = 0;
    };

    for (let i = 0z; i < len(bytes); i += 1) {
        emit_byte(w, bytes[i])?;
    };

    // Flush the outbuf so callers see their data land.
    flush_outbuf(w)?;
    return len(bytes);
};

// Aligns to the next byte boundary using MSB-padding. Excluded from FLAC CRCs.
// Flushes the output buffer to the underlying handle.
export fn flush(w: *bit_writer) (size | io::error) = {
    let n = 0z;
    if (w.bits_used > 0) {
        const final_byte = w.buffer << (8 - w.bits_used);
        // Note: flush() pads without updating CRCs (per FLAC spec the
        // padding bits after residuals are not included in any checksum).
        w.outbuf[w.outbuf_len] = final_byte;
        w.outbuf_len += 1;
        n += 1;
        w.buffer = 0;
        w.bits_used = 0;
    };
    flush_outbuf(w)?;
    return n;
};

// Specialized flush for the Frame Header. Final byte MUST be in CRC-8.
// Flushes the output buffer to the underlying handle.
export fn flush_header(w: *bit_writer) (size | io::error) = {
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);
        emit_byte(w, w.buffer)?;
        w.buffer = 0;
        w.bits_used = 0;
    };
    flush_outbuf(w)?;
    return 0z;
};

// Finalizes the entire frame. Feeds the last partial byte into CRC-16,
// writes it, flushes the output buffer, and returns the final CRC-16.
export fn finalize_frame(w: *bit_writer) u16 = {
    if (w.bits_used > 0) {
        w.buffer <<= (8 - w.bits_used);
        // emit_byte updates both CRCs; the final CRC-16 is what's returned.
        emit_byte(w, w.buffer)!;
        w.buffer = 0;
        w.bits_used = 0;
    };
    flush_outbuf(w)!;
    return w.crc16;
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
