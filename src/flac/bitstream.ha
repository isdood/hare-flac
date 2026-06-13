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
    bytes_written: u64,
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
        bytes_written = 0,
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
    w.bytes_written += 1;
    if (w.outbuf_len == OUTBUF_SIZE) {
        flush_outbuf(w)?;
    };
};

export fn write_bits(w: *bit_writer, value: u64, count: u8) (size | io::error) = {
    if (count == 0) return 0z;

    let bytes_written = 0z;
    let remaining_count = count;

    // Mask the incoming value to ensure no dirty upper bits exist
    let clean_value = if (count == 64) value else value & ((1u64 << count) - 1);

    // If the incoming count is large, or pooling it with bits_used exceeds
    // safe capacity of a u64 register staging window, process
    // in digestible chunks.
    for (remaining_count > 0) {
        const space_in_buffer = 8 - w.bits_used;

        if (remaining_count >= space_in_buffer) {
            // If there's enough bits coming in to completely fill the current partial byte
            const shift = remaining_count - space_in_buffer;
            const bits_to_take = ((clean_value >> shift) & ((1u64 << space_in_buffer) - 1)): u8;

            w.buffer = (w.buffer << space_in_buffer) | bits_to_take;
            emit_byte(w, w.buffer)?;
            bytes_written += 1;

            remaining_count -= space_in_buffer;
            w.bits_used = 0;
            w.buffer = 0;
        } else {
            // The remaining bits don't even fill up the current partial byte
            w.buffer = (w.buffer << remaining_count) | (clean_value: u8 & ((1u8 << remaining_count) - 1));
            w.bits_used += remaining_count;
            remaining_count = 0;
        };
    };

    return bytes_written;
};

// Writes 'count' zero bits efficiently. Optimized for unary Rice coding.
export fn write_zeros(w: *bit_writer, count: u32) (size | io::error) = {
    if (count == 0) return 0z;
    let total_written = 0z;
    let remaining_bits = count;

    // Fill out the partial byte if one is in progress.
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

    // Emit whole zero bytes directly.
    const zero_bytes = remaining_bits / 8;
    if (zero_bytes > 0) {
        for (let i = 0u32; i < zero_bytes; i += 1) {
            emit_byte(w, 0)?;
            total_written += 1;
        };
        remaining_bits %= 8;
    };

    // Queue any leftover bits (0–7) into the partial buffer.
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
export fn writer_pos(w: *bit_writer) u64 = w.bytes_written;
export fn reader_bits_avail(r: *bit_reader) u8 = r.bits_avail;

export fn bits_pending(w: *bit_writer) u8 = {
    return w.bits_used;
};

// ---------------------------------------------------------------------------
// bit_reader
// ---------------------------------------------------------------------------

def INBUF_SIZE: size = 65536;

export type bit_reader = struct {
    handle:    io::handle,
    // Staging word: bits are held MSB-first in the high `bits_avail` bits.
    bits:      u64,
    bits_avail: u8,
    // Byte-level read buffer.
    inbuf:     [INBUF_SIZE]u8,
    inbuf_pos: size,
    inbuf_len: size,
    crc8:  u8,
    crc16: u16,
};

export fn newreader(h: io::handle) bit_reader = {
    return bit_reader {
        handle    = h,
        bits      = 0,
        bits_avail = 0,
        inbuf     = [0...],
        inbuf_pos = 0,
        inbuf_len = 0,
        crc8      = 0,
        crc16     = 0,
    };
};

export fn reset_reader_crc8(r: *bit_reader)  void = { r.crc8  = 0; };
export fn reset_reader_crc16(r: *bit_reader) void = { r.crc16 = 0; };
export fn reader_crc8(r:  *bit_reader) u8  = r.crc8;
export fn reader_crc16(r: *bit_reader) u16 = r.crc16;

// Consumes one byte from the input buffer (refilling if necessary),
// updates both CRCs, and loads the byte into the staging word.
fn refill_byte(r: *bit_reader) (void | io::error | io::EOF) = {
    if (r.inbuf_pos >= r.inbuf_len) {
        const n = match (io::read(r.handle, r.inbuf[..])) {
            case let n: size => yield n;
            case io::EOF    => return io::EOF;
        };
        r.inbuf_pos = 0;
        r.inbuf_len = n;
    };
    const b = r.inbuf[r.inbuf_pos];
    r.inbuf_pos += 1;
    r.crc8  = crc8_update(r.crc8, b);
    r.crc16 = crc16_update(r.crc16, b);
    // Pack byte into the high end of the staging word.
    r.bits |= (b: u64) << (56 - r.bits_avail);
    r.bits_avail += 8;
};

// Reads exactly `count` bits (1–57) from the stream, MSB-first.
// Returns the value right-aligned in a u64.
export fn read_bits(r: *bit_reader, count: u8) (u64 | io::error | io::EOF) = {
    assert(count > 0 && count <= 57, "read_bits: count must be 1–57");
    for (r.bits_avail < count) {
        refill_byte(r)?;
    };
    const val = r.bits >> (64 - count);
    r.bits <<= count;
    r.bits_avail -= count;
    return val;
};

// Counts leading zero bits in the top `avail` bits of a u64 staging word.
// Returns `avail` if no 1-bit is found (all zeros in the occupied region).
fn leading_zeros64(bits: u64, avail: u8) u8 = {
    let n = 0u8;
    let mask = 1u64 << 63;
    for (n < avail) {
        if (bits & mask != 0) break;
        n += 1;
        mask >>= 1;
    };
    return n;
};

// Reads a unary-coded non-negative integer: counts zero bits until the
// terminating 1. Returns the zero count (i.e. the Rice quotient).
export fn read_unary(r: *bit_reader) (u32 | io::error | io::EOF) = {
    let q = 0u32;
    for (true) {
        for (r.bits_avail == 0) {
            refill_byte(r)?;
        };
        const leading = leading_zeros64(r.bits, r.bits_avail);
        if (leading < r.bits_avail) {
            // The terminating 1 is within the current staging word.
            q += leading: u32;
            // Consume the zeros and the terminating 1.
            r.bits <<= leading + 1;
            r.bits_avail -= leading + 1;
            return q;
        };
        // All available bits are zeros; consume them and keep counting.
        q += r.bits_avail: u32;
        r.bits = 0;
        r.bits_avail = 0;
    };
};

// Reads exactly `count` bits without updating CRC accumulators.
// Used for reading checksum fields that must not be folded into the running CRC.
export fn read_bits_nocrc(r: *bit_reader, count: u8) (u64 | io::error | io::EOF) = {
	assert(count > 0 && count <= 57, "read_bits_nocrc: count must be 1-57");
	for (r.bits_avail < count) {
		const crc8_save  = r.crc8;
		const crc16_save = r.crc16;
		match (refill_byte(r)) {
			case void => void;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		r.crc8  = crc8_save;
		r.crc16 = crc16_save;
	};
	const val = r.bits >> (64 - count);
	r.bits <<= count;
	r.bits_avail -= count;
	return val;
};

// Discards bits until the reader is aligned to the next byte boundary.
// Used after reading subframe data before the frame CRC-16.
export fn align_reader(r: *bit_reader) void = {
    const leftover = r.bits_avail % 8;
    if (leftover != 0) {
        r.bits <<= leftover;
        r.bits_avail -= leftover: u8;
    };
};

@test fn test_bit_reader_basic() void = {
    // Write some known bits with bit_writer, then read them back.
    let buf: [8]u8 = [0...];
    let wmem = memio::fixed(buf);
    let w = newwriter(&wmem);
    write_bits(&w, 0b1011, 4)!;  // 4 bits
    write_bits(&w, 0b01,   2)!;  // 2 bits
    write_bits(&w, 0b1,    1)!;  // 1 bit  → byte: 1011_011x
    write_bits(&w, 0b0,    1)!;  // 1 bit  → byte: 1011_0110 = 0xB6
    flush(&w)!;

    let rmem = memio::fixed(buf);
    let r = newreader(&rmem);
    assert(read_bits(&r, 4)! == 0b1011);
    assert(read_bits(&r, 2)! == 0b01);
    assert(read_bits(&r, 1)! == 0b1);
    assert(read_bits(&r, 1)! == 0b0);
};

@test fn test_bit_reader_unary() void = {
    // Encode a few Rice values and verify read_unary recovers the quotients.
    // q=0: terminator immediately → bit '1'
    // q=3: three zeros then '1'   → bits '0001'
    let buf: [4]u8 = [0...];
    let wmem = memio::fixed(buf);
    let w = newwriter(&wmem);
    write_bits(&w, 1u64, 1)!;        // q=0: '1'
    write_zeros(&w, 3)!;             // q=3: '000'
    write_bits(&w, 1u64, 1)!;        //       '1'
    flush(&w)!;

    let rmem = memio::fixed(buf);
    let r = newreader(&rmem);
    assert(read_unary(&r)! == 0);
    assert(read_unary(&r)! == 3);
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
