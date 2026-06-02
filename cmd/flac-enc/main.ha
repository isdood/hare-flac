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
    let mid: [MAX_BLOCK]i32 = [0...];
    let side: [MAX_BLOCK]i32 = [0...];

    let ch0_samples: [MAX_BLOCK]i32 = [0...];
    let ch1_samples: [MAX_BLOCK]i32 = [0...];
    let frame_count = 0u32;

    fmt::printfln("Encoding audio...")!;
    const start_time = time::now(time::clock::MONOTONIC);
    for (true) {
        const read_slice = raw_samples[..MAX_BLOCK * channels];
        const n_read = match (wav::read_samples(&stream, read_slice)) {
            case let s: size => yield s;
            case => break;
        };

        if (n_read == 0) {
            break;
        };

        let block_size = (n_read / channels): u16;

        flac::reset_crc16(&writer);
        let bps = dec.meta.bit_depth: u8;
        for (let i = 0z; i < block_size: size; i += 1) {
            left[i] = raw_samples[i * channels];
            if (channels > 1) {
                right[i] = raw_samples[i * channels + 1];
            };
        };

        let channel_assignment = 0u8;
        if (channels == 2 && bps <= 24) {
            let left_score = 0u64;
            let right_score = 0u64;
            let mid_score = 0u64;
            let side_score = 0u64;
            for (let i = 0z; i < block_size: size; i += 1) {
                mid[i] = (left[i] + right[i]) >> 1;
                side[i] = left[i] - right[i];

                left_score += (if (left[i] < 0) -left[i] else left[i]): u64;
                right_score += (if (right[i] < 0) -right[i] else right[i]): u64;
                mid_score += (if (mid[i] < 0) -mid[i] else mid[i]): u64;
                side_score += (if (side[i] < 0) -side[i] else side[i]): u64;
            };

            const score_lr = left_score + right_score;
            const score_ms = mid_score + side_score;

            if (score_ms < score_lr) {
                channel_assignment = 10u8;
            } else {
                channel_assignment = 1u8;
            };
        } else if (channels == 1) {
            channel_assignment = 0u8;
        };

        let bps_ch0 = bps;
        let bps_ch1 = bps;

        if (channel_assignment == 10u8) {
            ch0_samples[..block_size] = mid[..block_size];
            ch1_samples[..block_size] = side[..block_size];
            bps_ch1 += 1;
        } else {
            ch0_samples[..block_size] = left[..block_size];
            ch1_samples[..block_size] = right[..block_size];
        };

        flac::write_frame_header_ext(
            &writer,
            block_size,
            dec.meta.rate,
            bps,
            channel_assignment,
            frame_count
        )!;

        const ch0_bits = encode_channel(&writer, ch0_samples[..block_size], bps_ch0)!;
        const ch1_bits = if (channels > 1) {
            yield encode_channel(&writer, ch1_samples[..block_size], bps_ch1)!;
        } else {
            yield 0z;
        };

        const frame_crc = flac::finalize_frame(&writer);
        flac::write_bits(&writer, frame_crc: u64, 16)!;

        frame_count += 1;
    };

    flac::finalize_frame(&writer);

    const end_time = time::now(time::clock::MONOTONIC);
    const total_sec = time::diff(start_time, end_time) / time::SECOND;

    fmt::printfln("Encoded {} frames in {} s to {}", frame_count, total_sec, output_path)!;
};

fn encode_channel(w: *flac::bit_writer, samples: []i32, bps: u8) (size | io::error) = {
    let windowed: [4096]f64 = [0.0f64...];
    let R: [13]f64 = [0.0...];
    let full_lpc_coefs: [12]f64 = [0.0...];
    let residual: [4096]i32 = [0...];

    let clean_samples: [4096]i32 = [0...];
    const shift_bits = 32i32 - bps: i32;
    for (let i = 0z; i < len(samples); i += 1) {
        clean_samples[i] = (samples[i] << shift_bits) >> shift_bits;
    };

    let best_score = math::INF;
    let best_shift = 0u8;
    let best_q_lpc: [12]i32 = [0...];
    let is_fixed = true;
    let selected_method_order: size = 0z;

    const total_samples = len(samples): f64;

    // Evaluate Fixed Predictors (Orders 0 to 4)
    const max_fixed = if (len(samples) < 4) len(samples) else 4z;
    for (let order = 0z; order <= max_fixed; order += 1) {
        lpc::predict_fixed(clean_samples[..len(samples)], order: u8, residual[..len(samples)]);

        let abs_sum = 0.0f64;
        for (let i = order; i < len(samples); i += 1) {
            abs_sum += math::absf64(residual[i]: f64);
        };
        if (abs_sum < 1.0) abs_sum = 1.0;

        const remaining_samples = total_samples - (order: f64);
        const mae = abs_sum / remaining_samples;

        const entropy_score = remaining_samples * math::log2f64(mae);
        const warmup_penalty = (order: f64) * (bps: f64);
        const total_score = entropy_score + warmup_penalty;

        if (total_score < best_score) {
            best_score = total_score;
            selected_method_order = order;
            is_fixed = true;
        };
    };

    // Evaluate Custom LPC Predictors (Orders 1 to 12)
    lpc::window_hann(clean_samples[..len(samples)], windowed[..len(samples)]);
    lpc::autocorrelation(windowed[..len(samples)], R[..]);
    lpc::levinson_durbin(R[..], full_lpc_coefs[..]);

    const precision = 12u8;
    for (let order = 1z; order <= 12z; order += 1) {
        let test_q_lpc: [12]i32 = [0...];
        const current_coefs = full_lpc_coefs[..order];
        const current_q_target = test_q_lpc[..order];

        const shift = lpc::quantize(current_coefs, current_q_target, precision);
        lpc::predict_lpc(clean_samples[..len(samples)], current_q_target, shift, residual[..len(samples)]);

        let abs_sum = 0.0f64;
        for (let i = order; i < len(samples); i += 1) {
            abs_sum += math::absf64(residual[i]: f64);
        };
        if (abs_sum < 1.0) abs_sum = 1.0;

        const remaining_samples = total_samples - (order: f64);
        const mae = abs_sum / remaining_samples;

        const entropy_score = remaining_samples * math::log2f64(mae);
        const warmup_penalty = (order: f64) * (bps: f64);
        const coefficient_bits = (order: f64) * (precision: f64);
        const container_floor = 14.0f64;

        const total_score = entropy_score + warmup_penalty + coefficient_bits + container_floor;

        if (total_score < best_score) {
            best_score = total_score;
            selected_method_order = order;
            best_shift = shift;
            best_q_lpc[..order] = test_q_lpc[..order];
            is_fixed = false;
        };
    };

    if (is_fixed) {
        const bits = flac::write_subframe_lpc(w, clean_samples[..len(samples)], [], 0, bps)?;
        return bits;
    };

    const bits = flac::write_subframe_lpc(
        w,
        clean_samples[..len(samples)],
        best_q_lpc[..selected_method_order],
        best_shift,
        bps,
    )?;
    return bits;
};
