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

    let s = (math::log2f64(avg / 1.3863) + 0.5): i32;

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

    // Write unary code (q zeros + terminator 1) as a single bit pattern.
    // The unary code is q zeros followed by a 1, which in MSB-first order
    // is exactly the bit pattern of value 1 in (q+1) bits.
    // This replaces q separate write_bits calls with a single call.
    if (q > 0) {
        bits += write_bits(w, 1u64, (q + 1): u8)?;
    } else {
        bits += write_bits(w, 1, 1)?;
    };

    if (s > 0) {
        bits += write_bits(w, r: u64, s)?;
    };
    return bits;
};

// Maps an unsigned zigzag integer back to a signed integer.
fn un_zig_zag(u: u32) i32 = {
    return ((u >> 1): i32) ^ -((u & 1): i32);
};

// Reads a Rice-coded signed integer with parameter `s` from the bit reader.
export fn read_rice(r: *bit_reader, s: u8) (i32 | io::error | io::EOF) = {
    const q: u32 = match (read_unary(r)) {
        case let v: u32 => yield v;
        case let e: io::error => return e;
        case io::EOF => return io::EOF;
    };
    const rem: u32 = if (s > 0) {
        yield (read_bits(r, s)?): u32;
    } else 0u32;
    const u: u32 = (q << (s: u32)) | rem;
    return un_zig_zag(u);
};

@test fn test_rice_roundtrip() void = {
    // Roundtrip a handful of signed values through write_rice / read_rice.
    const vals: [_]i32 = [0, 1, -1, 7, -7, 100, -100];
    const params: [_]u8 = [0, 2, 4];

    for (let pi = 0z; pi < len(params); pi += 1) {
        const s = params[pi];
        let buf: [64]u8 = [0...];
        let wmem = memio::fixed(buf);
        let w = newwriter(&wmem);

        for (let i = 0z; i < len(vals); i += 1) {
            write_rice(&w, vals[i], s)!;
        };
        flush(&w)!;

        let rmem = memio::fixed(buf);
        let r = newreader(&rmem);
        for (let i = 0z; i < len(vals); i += 1) {
            const got: i32 = match (read_rice(&r, s)) {
                case let v: i32 => yield v;
                case => abort("unexpected error or EOF in test");
            };
            assert(got == vals[i]);
        };
    };
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
