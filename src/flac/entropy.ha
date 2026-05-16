use lpc;
use io;
use math;
use memio;

// Maps a signed integer to an unsigned integer (ZigZag encoding).
fn zig_zag(n: i32) u32 = {
    return ((n << 1) ^ (n >> 31)): u32;
};

// Calculates the optimal Rice parameter 's' for a block of residuals.
export fn optimize_rice(res: []i32) u8 = {
    if (len(res) == 0) return 0;
    let sum = 0u64;
    for (let i = 0z; i < len(res); i += 1) {
        sum += zig_zag(res[i]): u64;
    };
    const avg = sum: f64 / len(res): f64;
    if (avg <= 0.0) return 0;

    let s = (math::log2f64(avg * 0.6931) + 0.5): i32;

    // SAFETY VALVE: If the average residual is huge,
    // we MUST use a larger s to keep the quotient 'q' small.
    if (avg > 1024.0 && s < 10) s = 10;

    if (s < 0) s = 0;
    if (s > 14) s = 14;
    return s: u8;
};

export fn write_rice(w: *bit_writer, val: i32, s: u8) (size | io::error) = {
    const u = zig_zag(val);
    const q = u >> s;
    const r = u & ((1u32 << s) - 1);

    // FLAC hard limit: max 30 unary zeros (q <= 30)
    // Callers must ensure this via rice_k selection or verbatim fallback.
    // Panic here rather than silently corrupt output.
    assert(q <= 30, "Rice quotient overflow — caller must use higher rice_k or verbatim");

    let bits = 0z;
    for (let i = 0u32; i < q; i += 1) {
        bits += write_bits(w, 0, 1)?;
    };
    bits += write_bits(w, 1, 1)?;
    if (s > 0) {
        bits += write_bits(w, r: u64, s)?;
    };
    return bits;
};

@test fn test_rice_encoding() void = {
    let buf: [16]u8 = [0...];
    let mem = memio::fixed(buf);
    let w = newwriter(&mem);

    // Zigzag(-1) = 1. Quotient (1 >> 2) = 0. Remainder (1 & 3) = 1.
    // Unary (q=0): '1' (just the terminator)
    // Binary (s=2): '01'
    // Total bits: 101xxxxx... (0b10100000 = 0xA0)
    write_rice(&w, -1, 2)!;
    flush(&w)!;

    // Check for 0b101xxxxx
    assert(buf[0] & 0xe0 == 0xa0);
};
