use fmt;
use os;
use os::exec;
use io;
use fs;
use wav;
use lpc;
use flac;
use time;
use math;
use strings;
use strconv;

def MAX_BLOCK: size = 4096;

def CHUNK0_IN:  str = "/tmp/flac-chunk-0.raw";
def CHUNK1_IN:  str = "/tmp/flac-chunk-1.raw";
def CHUNK0_OUT: str = "/tmp/flac-out-0.raw";
def CHUNK1_OUT: str = "/tmp/flac-out-1.raw";

export fn main() void = {
	const args = os::args;

	if (len(args) >= 2 && args[1] == "--worker") {
		if (len(args) < 7) {
			fmt::fatal("Usage: flac-enc --worker <start_frame> <frame_count> <channels> <bps> <sample_rate> <input> <output>");
		};
		run_worker(args);
		return;
	};

	if (len(args) < 3) {
		fmt::fatal("Usage: flac-enc <input.wav> <output.flac>");
	};

	const input_path  = args[1];
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
			fmt::fatalf("WAV error: {}", wav::strerror(e));
	};

	const channels         = dec.meta.channels: size;
	const bps              = dec.meta.bit_depth: u8;
	const bytes_per_sample = (dec.meta.bit_depth / 8): u32;
	const total_samples    = dec.data_size / (dec.meta.channels: u32 * bytes_per_sample);

	let all_samples: []i32 = alloc([0i32...], total_samples: size * channels) as []i32;
	defer free(all_samples);

	let stream = wav::newstream(file, &dec);
	let n_read = 0z;
	for (true) {
		const batch = match (wav::read_samples(&stream, all_samples[n_read..])) {
			case let s: size => yield s;
			case => break;
		};
		if (batch == 0) break;
		n_read += batch;
	};

	const total_frames  = (n_read + MAX_BLOCK * channels - 1) / (MAX_BLOCK * channels);
	const split_frame   = total_frames / 2;
	const split_sample  = split_frame * MAX_BLOCK * channels;
	const actual_split  = if (split_sample > n_read) n_read else split_sample;

	fmt::printfln("Encoding audio...")!;

	write_raw_samples(CHUNK0_IN, all_samples[..actual_split]);
	write_raw_samples(CHUNK1_IN, all_samples[actual_split..n_read]);

	const self_path = os::args[0];

	let start_frame_0 = strings::dup(strconv::u32tos(0u32)) as str;
	defer free(start_frame_0);
	let frame_count_0 = strings::dup(strconv::u32tos(split_frame: u32)) as str;
	defer free(frame_count_0);
	let start_frame_1 = strings::dup(strconv::u32tos(split_frame: u32)) as str;
	defer free(start_frame_1);
	let frame_count_1 = strings::dup(strconv::u32tos((total_frames - split_frame): u32)) as str;
	defer free(frame_count_1);
	let channels_str  = strings::dup(strconv::u32tos(channels: u32)) as str;
	defer free(channels_str);
	let bps_str       = strings::dup(strconv::u32tos(bps: u32)) as str;
	defer free(bps_str);
	let rate_str      = strings::dup(strconv::u32tos(dec.meta.rate)) as str;
	defer free(rate_str);

	const start_time = time::now(time::clock::MONOTONIC);

	const cmd0 = exec::cmd(self_path,
		"--worker",
		start_frame_0, frame_count_0,
		channels_str, bps_str, rate_str,
		CHUNK0_IN, CHUNK0_OUT)!;
	let proc0 = exec::start(&cmd0)!;

	const cmd1 = exec::cmd(self_path,
		"--worker",
		start_frame_1, frame_count_1,
		channels_str, bps_str, rate_str,
		CHUNK1_IN, CHUNK1_OUT)!;
	let proc1 = exec::start(&cmd1)!;

	const status0 = exec::wait(&proc0)!;
	const status1 = exec::wait(&proc1)!;

	match (exec::check(&status0)) {
		case void => void;
		case let s: !exec::exit_status =>
			fmt::fatalf("Worker 0 failed: {}", exec::exitstr(s));
	};
	match (exec::check(&status1)) {
		case void => void;
		case let s: !exec::exit_status =>
			fmt::fatalf("Worker 1 failed: {}", exec::exitstr(s));
	};

	const end_time = time::now(time::clock::MONOTONIC);
	const elapsed  = time::diff(start_time, end_time) / time::SECOND;

	const out_file = match (os::create(output_path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error creating output: {}", fs::strerror(e));
	};
	defer io::close(out_file)!;

	let writer = flac::newwriter(out_file);
	flac::write_stream_header(&writer, &dec)!;
	flac::flush(&writer)!;

	append_file(out_file, CHUNK0_OUT);
	append_file(out_file, CHUNK1_OUT);

	os::remove(CHUNK0_IN)!;
	os::remove(CHUNK1_IN)!;
	os::remove(CHUNK0_OUT)!;
	os::remove(CHUNK1_OUT)!;

	fmt::printfln("Encoded {} frames in {}s", total_frames, elapsed)!;
};

// run_worker is invoked as a subprocess to encode one chunk of samples.
// Args: --worker <start_frame> <frame_count> <channels> <bps> <sample_rate> <input> <output>
fn run_worker(args: []str) void = {
	const start_frame = strconv::stou32(args[2]) as u32;
	const frame_count = strconv::stou32(args[3]) as u32;
	const channels    = (strconv::stou32(args[4]) as u32): size;
	const bps         = (strconv::stou32(args[5]) as u32): u8;
	const sample_rate = strconv::stou32(args[6]) as u32;
	const input_path  = args[7];
	const output_path = args[8];

	const in_file = match (os::open(input_path)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Worker: error opening input {}: {}", input_path, fs::strerror(e));
	};
	defer io::close(in_file)!;

	const raw_bytes = io::drain(in_file)!;
	defer free(raw_bytes);

	const n_samples = len(raw_bytes) / 4;
	let samples: []i32 = alloc([0i32...], n_samples) as []i32;
	defer free(samples);
	for (let i = 0z; i < n_samples; i += 1) {
		const b = raw_bytes[i * 4..(i + 1) * 4];
		samples[i] = (b[0]: i32)
			| ((b[1]: i32) << 8)
			| ((b[2]: i32) << 16)
			| ((b[3]: i32) << 24);
	};

	const out_file = match (os::create(output_path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Worker: error creating output {}: {}", output_path, fs::strerror(e));
	};
	defer io::close(out_file)!;

	let writer = flac::newwriter(out_file);
	encode_chunk(&writer, samples, channels, bps, sample_rate, start_frame);
	let _ = frame_count;
};

// encode_chunk encodes samples into raw FLAC frames (no STREAMINFO header).
// start_frame is the absolute frame number for correct frame headers.
fn encode_chunk(
	writer: *flac::bit_writer,
	all_samples: []i32,
	channels: size,
	bps: u8,
	sample_rate: u32,
	start_frame: u32,
) void = {
	let left:        [MAX_BLOCK]i32 = [0...];
	let right:       [MAX_BLOCK]i32 = [0...];
	let mid:         [MAX_BLOCK]i32 = [0...];
	let side:        [MAX_BLOCK]i32 = [0...];
	let ch0_samples: [MAX_BLOCK]i32 = [0...];
	let ch1_samples: [MAX_BLOCK]i32 = [0...];

	let frame_count = start_frame;
	let pos = 0z;

	for (pos < len(all_samples)) {
		const remaining    = len(all_samples) - pos;
		const block_samples = if (remaining > MAX_BLOCK * channels)
			MAX_BLOCK * channels
		else
			remaining;
		const block_size = (block_samples / channels): u16;

		for (let i = 0z; i < block_size: size; i += 1) {
			left[i] = all_samples[pos + i * channels];
			if (channels > 1) {
				right[i] = all_samples[pos + i * channels + 1];
			};
		};

		let channel_assignment = 0u8;
		if (channels == 2 && bps <= 24) {
			let left_score  = 0u64;
			let right_score = 0u64;
			let mid_score   = 0u64;
			let side_score  = 0u64;
			for (let i = 0z; i < block_size: size; i += 1) {
				mid[i]  = (left[i] + right[i]) >> 1;
				side[i] = left[i] - right[i];
				left_score  += (if (left[i]  < 0) -left[i]  else left[i]):  u64;
				right_score += (if (right[i] < 0) -right[i] else right[i]): u64;
				mid_score   += (if (mid[i]   < 0) -mid[i]   else mid[i]):   u64;
				side_score  += (if (side[i]  < 0) -side[i]  else side[i]):  u64;
			};
			if (mid_score + side_score < left_score + right_score) {
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

		flac::reset_crc16(writer);
		flac::write_frame_header_ext(
			writer,
			block_size,
			sample_rate,
			bps,
			channel_assignment,
			frame_count,
		)!;

		encode_channel(writer, ch0_samples[..block_size], bps_ch0)!;
		if (channels > 1) {
			encode_channel(writer, ch1_samples[..block_size], bps_ch1)!;
		};

		const frame_crc = flac::finalize_frame(writer);
		flac::write_bits(writer, frame_crc: u64, 16)!;

		frame_count += 1;
		pos += block_samples;
	};

	flac::finalize_frame(writer);
};

// write_raw_samples writes a []i32 to a file as little-endian bytes.
fn write_raw_samples(path: str, samples: []i32) void = {
	const f = match (os::create(path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error creating {}: {}", path, fs::strerror(e));
	};
	defer io::close(f)!;

	const bytes = samples: *[*]u8;
	io::writeall(f, bytes[..len(samples) * 4])!;
};

// append_file copies all bytes from src into dst.
fn append_file(dst: io::file, src_path: str) void = {
	const src = match (os::open(src_path)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error opening {} for stitch: {}", src_path, fs::strerror(e));
	};
	defer io::close(src)!;
	io::copy(dst, src)!;
};

fn encode_channel(w: *flac::bit_writer, samples: []i32, bps: u8) (size | io::error) = {
	let windowed:       [4096]f64 = [0.0f64...];
	let R:              [13]f64   = [0.0...];
	let full_lpc_coefs: [12]f64   = [0.0...];
	let residual:       [4096]i32 = [0...];
	let clean_samples:  [4096]i32 = [0...];

	const shift_bits = 32i32 - bps: i32;
	for (let i = 0z; i < len(samples); i += 1) {
		clean_samples[i] = (samples[i] << shift_bits) >> shift_bits;
	};

	let best_score           = math::INF;
	let best_shift           = 0u8;
	let best_q_lpc:   [12]i32 = [0...];
	let is_fixed             = true;
	let selected_method_order: size = 0z;

	const total_samples = len(samples): f64;

	// Evaluate fixed predictors (orders 0–4).
	const max_fixed = if (len(samples) < 4) len(samples) else 4z;
	for (let order = 0z; order <= max_fixed; order += 1) {
		lpc::predict_fixed(clean_samples[..len(samples)], order: u8, residual[..len(samples)]);

		let abs_sum = 0.0f64;
		for (let i = order; i < len(samples); i += 1) {
			abs_sum += math::absf64(residual[i]: f64);
		};
		if (abs_sum < 1.0) abs_sum = 1.0;

		const remaining_samples = total_samples - (order: f64);
		const mae               = abs_sum / remaining_samples;
		const entropy_score     = remaining_samples * math::log2f64(mae);
		const warmup_penalty    = (order: f64) * (bps: f64);
		const total_score       = entropy_score + warmup_penalty;

		if (total_score < best_score) {
			best_score            = total_score;
			selected_method_order = order;
			is_fixed              = true;
		};
	};

	// Evaluate LPC predictors (orders 1–12).
	lpc::window_hann(clean_samples[..len(samples)], windowed[..len(samples)]);
	lpc::autocorrelation(windowed[..len(samples)], R[..]);
	lpc::levinson_durbin(R[..], full_lpc_coefs[..]);

	const precision = 12u8;
	for (let order = 1z; order <= 12z; order += 1) {
		let test_q_lpc:     [12]i32 = [0...];
		const current_coefs    = full_lpc_coefs[..order];
		const current_q_target = test_q_lpc[..order];

		const shift = lpc::quantize(current_coefs, current_q_target, precision);
		lpc::predict_lpc(clean_samples[..len(samples)], current_q_target, shift, residual[..len(samples)]);

		let abs_sum = 0.0f64;
		for (let i = order; i < len(samples); i += 1) {
			abs_sum += math::absf64(residual[i]: f64);
		};
		if (abs_sum < 1.0) abs_sum = 1.0;

		const remaining_samples = total_samples - (order: f64);
		const mae               = abs_sum / remaining_samples;
		const entropy_score     = remaining_samples * math::log2f64(mae);
		const warmup_penalty    = (order: f64) * (bps: f64);
		const coefficient_bits  = (order: f64) * (precision: f64);
		const container_floor   = 14.0f64;
		const total_score       = entropy_score + warmup_penalty + coefficient_bits + container_floor;

		// Constant subframe: all samples identical.
		let is_constant = true;
		for (let i = 1z; i < len(samples); i += 1) {
			if (clean_samples[i] != clean_samples[0]) {
				is_constant = false;
				break;
			};
		};
		if (is_constant) {
			return flac::write_subframe_constant(w, clean_samples[0], bps)?;
		};

		if (total_score < best_score) {
			best_score            = total_score;
			selected_method_order = order;
			best_shift            = shift;
			best_q_lpc[..order]   = test_q_lpc[..order];
			is_fixed              = false;
		};
	};

	if (is_fixed) {
		return flac::write_subframe_lpc(w, clean_samples[..len(samples)], [], 0, bps)?;
	};

	return flac::write_subframe_lpc(
		w,
		clean_samples[..len(samples)],
		best_q_lpc[..selected_method_order],
		best_shift,
		bps,
	)?;
};
