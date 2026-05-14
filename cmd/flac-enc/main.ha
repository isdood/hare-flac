use fmt;
use os;
use io;
use fs;
use wav;
use lpc;
use flac;

export fn main() void = {
    const args = os::args;
    if (len(args) < 3) {
        fmt::fatal("Usage: flac-enc <input.wav> <output.flac>");
    };
    const input_path = args[1];
    const output_path = args[2];

    const file = match (os::open(input_path)) {
        case let f: io::file => yield f;
        case let e: fs::error =>
            fmt::fatalf("Error opening input: {}", fs::strerror(e));
    };
    defer io::close(file)!;

    const dec = match (wav::parse(file)) {
        case let d: wav::decoder => yield d;
        case let e: wav::error =>
            fmt::fatalf("WAV Error: {}", wav::strerror(e));
    };

    let stream = wav::newstream(file, &dec);

    const out_file = match (os::create(output_path, 0o644)) {
        case let f: io::file => yield f;
        case let e: fs::error =>
            fmt::fatalf("Error creating output: {}", fs::strerror(e));
    };
    defer io::close(out_file)!;

    let writer = flac::newwriter(out_file);
    flac::write_stream_header(&writer, &dec)!;

    let raw_samples: [8192]i32 = [0...];
    let left: [4096]i32 = [0...];
    let right: [4096]i32 = [0...];
    let frame_count = 0u32;

    for (true) {
        const n = match (wav::read_samples(&stream, raw_samples)) {
        case let s: size =>
            if (s == 0) break else yield s;
        case let e: wav::error => break;
        };

        flac::reset_crc16(&writer);
        const block_size = (n / dec.meta.channels: size): u16;
        const bps = dec.meta.bit_depth: u8;

        for (let i = 0z; i < block_size: size; i += 1) {
            left[i] = raw_samples[i * 2];
            right[i] = raw_samples[i * 2 + 1];
        };

        flac::write_frame_header(
            &writer,
            block_size,
            dec.meta.rate,
            bps,
            dec.meta.channels: u8,
            frame_count
        )!;

        const left_bits = encode_channel(&writer, left[..block_size], bps)!;
        const right_bits = encode_channel(&writer, right[..block_size], bps)!;

        if (frame_count < 3) {
            fmt::printfln("Frame {}: left={} bits, right={} bits, total={} bits",
                          frame_count, left_bits, right_bits, left_bits + right_bits)!;
        };

        const frame_crc = flac::finalize_frame(&writer);
        flac::write_bits(&writer, frame_crc: u64, 16)!;

        frame_count += 1;
    };

    fmt::printfln("Encoded {} frames to {}", frame_count, output_path)!;
};

fn encode_channel(w: *flac::bit_writer, samples: []i32, bps: u8) (size | io::error) = {
    const order = 8z;
    let windowed: [4096]f64 = [0.0f64...];
    let R: [9]f64 = [0.0f64...];
    let lpc_f: [8]f64 = [0.0f64...];
    let q_lpc: [8]i32 = [0...];

    lpc::window_hann(samples, windowed[..len(samples)]);
    lpc::autocorrelation(windowed[..len(samples)], R);
    lpc::levinson_durbin(R, lpc_f);
    const shift = lpc::quantize(lpc_f, q_lpc, 12);

    return flac::write_subframe_lpc(w, samples, q_lpc, shift, bps)?;
};
