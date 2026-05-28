use fmt;
use os;
use io;
use fs;
use wav;
use lpc;
use flac;
use time;
use math;

def MAX_BLOCK: size = 4096;

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

    const channels = dec.meta.channels: size;
    let raw_samples: [MAX_BLOCK * 2]i32 = [0...];
    let left: [MAX_BLOCK]i32 = [0...];
    let right: [MAX_BLOCK]i32 = [0...];
    let frame_count = 0u32;

    fmt::printfln("Encoding audio...")!;
    const start_time = time::now(time::clock::MONOTONIC);

    for (true) {
        const buffer_slice = raw_samples[..MAX_BLOCK * channels];
        const n = match (wav::read_samples(&stream, buffer_slice)) {
            case let s: size =>
                if (s == 0) break else yield s;
            case let e: wav::error => break;
        };

        flac::reset_crc16(&writer);

        const block_size = (n / channels): u16;
        const bps = dec.meta.bit_depth: u8;

        for (let i = 0z; i < block_size: size; i += 1) {
            left[i] = raw_samples[i * channels];
            if (channels > 1) {
                right[i] = raw_samples[i * channels + 1];
            };
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
        const right_bits = if (channels > 1) {
            yield encode_channel(&writer, right[..block_size], bps)!;
        } else {
            yield 0z;
        };

        const frame_crc = flac::finalize_frame(&writer);
        flac::write_bits(&writer, frame_crc: u64, 16)!;

        frame_count += 1;
    };

    // Flush the remaining bits of the last frame out to disk
    flac::finalize_frame(&writer);

    const end_time = time::now(time::clock::MONOTONIC);
    const total_sec = time::diff(start_time, end_time) / time::SECOND;

    fmt::printfln("Encoded {} frames in {} s to {}", frame_count, total_sec, output_path)!;
};

fn encode_channel(w: *flac::bit_writer, samples: []i32, bps: u8) (size | io::error) = {
	const max_order = 8z;
	let windowed: [4096]f64 = [0.0f64...];
	let R: [9]f64 = [0.0f64...];
	let lpc_f: [8]f64 = [0.0f64...];
	let q_lpc: [8]i32 = [0...];

	lpc::window_hann(samples, windowed[..len(samples)]);
	lpc::autocorrelation(windowed[..len(samples)], R);
	if (R[0] < 1e-9) {
		return flac::write_subframe_lpc(w, samples, [], 0, bps);
	};

	lpc::levinson_durbin(R, lpc_f);

	let actual_order = max_order;
	for (actual_order > 1 && math::absf64(lpc_f[actual_order - 1]) < 0.01) {
		actual_order -= 1;
	};

	const shift = lpc::quantize(lpc_f[..actual_order], q_lpc[..actual_order], 12);
	return flac::write_subframe_lpc(w, samples, q_lpc[..actual_order], shift, bps);
};
