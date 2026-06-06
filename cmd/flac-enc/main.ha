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
use errors;

def MAX_BLOCK: size = 4096;

// Child fd slots for memfd IPC.
def WORKER_IN_FD:  int = 3;
def WORKER_OUT_FD: int = 4;

export fn main() void = {
	const args = os::args;

	// Worker mode:
	//   flac-enc --worker <start_frame> <channels> <bps> <sample_rate>
	//   fd 3 = input PCM memfd, fd 4 = output FLAC memfd
	if (len(args) >= 2 && args[1] == "--worker") {
		if (len(args) < 6) {
			fmt::fatal("Usage: flac-enc --worker <start_frame> <channels> <bps> <sample_rate>");
		};
		run_worker(args);
		return;
	};

	// Orchestrator mode:
	//   flac-enc <input.wav> <output.flac>
	if (len(args) < 3) {
		fmt::fatal("Usage: flac-enc <input.wav> <output.flac>");
	};
	const input_path  = args[1];
	const output_path = args[2];

	const n_workers = match (os::cpucount()) {
		case let n: size => yield n;
		case => yield 1z;
	};

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

	// Read all samples into a flat buffer upfront.
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

	const total_frames = (n_read + MAX_BLOCK * channels - 1) / (MAX_BLOCK * channels);

	// Shared string args passed to every worker.
	let channels_str = strings::dup(strconv::u32tos(channels: u32)) as str;
	defer free(channels_str);
	let bps_str      = strings::dup(strconv::u32tos(bps: u32)) as str;
	defer free(bps_str);
	let rate_str     = strings::dup(strconv::u32tos(dec.meta.rate)) as str;
	defer free(rate_str);

	const self_path = os::args[0];

	// Compute per-worker frame boundaries.
	// Distribute frames as evenly as possible; first `remainder` workers
	// each get one extra frame.
	let start_frames: []u32 = alloc([0u32...], n_workers) as []u32;
	defer free(start_frames);
	let frame_counts: []u32 = alloc([0u32...], n_workers) as []u32;
	defer free(frame_counts);

	const base_frames = total_frames / n_workers;
	const remainder   = total_frames % n_workers;

	for (let i = 0z; i < n_workers; i += 1) {
		const extra = if (i < remainder) 1z else 0z;
		frame_counts[i] = (base_frames + extra): u32;
		start_frames[i] = if (i == 0) 0u32
			else start_frames[i - 1] + frame_counts[i - 1];
	};

	// Create memfds for each worker and write PCM input chunks.
	// Retain the output memfds for stitching after workers finish.
	let in_fds:  []io::file = alloc([0: io::file...], n_workers) as []io::file;
	defer free(in_fds);
	let out_fds: []io::file = alloc([0: io::file...], n_workers) as []io::file;
	defer free(out_fds);

	for (let i = 0z; i < n_workers; i += 1) {
		const sample_start      = start_frames[i]: size * MAX_BLOCK * channels;
		const sample_end_frames = (start_frames[i] + frame_counts[i]): size;
		const sample_end        = if (sample_end_frames * MAX_BLOCK * channels > n_read)
			n_read
		else
			sample_end_frames * MAX_BLOCK * channels;

		const in_fd = match (os::memfd("flac-chunk")) {
			case let f: io::file => yield f;
			case let e: errors::error =>
				fmt::fatalf("memfd failed: {}", errors::strerror(e));
		};
		const out_fd = match (os::memfd("flac-out")) {
			case let f: io::file => yield f;
			case let e: errors::error =>
				fmt::fatalf("memfd failed: {}", errors::strerror(e));
		};

		// Write PCM chunk into input memfd, then seek back for the child.
		write_raw_samples_fd(in_fd, all_samples[sample_start..sample_end]);
		io::seek(in_fd, 0, io::whence::SET)!;

		in_fds[i]  = in_fd;
		out_fds[i] = out_fd;
	};

	fmt::printfln("Encoding audio...")!;
	const start_time = time::now(time::clock::MONOTONIC);

	// Spawn all workers, wiring memfds into child fd slots 3 and 4.
	let procs: []exec::process = [];
	defer free(procs);
	for (let i = 0z; i < n_workers; i += 1) {
		let sf_str = strings::dup(strconv::u32tos(start_frames[i])) as str;
		defer free(sf_str);

		let cmd = exec::cmd(self_path,
			"--worker",
			sf_str,
			channels_str, bps_str, rate_str)!;
		exec::addfile(&cmd, WORKER_IN_FD,  in_fds[i])!;
		exec::addfile(&cmd, WORKER_OUT_FD, out_fds[i])!;

		const proc = exec::start(&cmd)!;
		append(procs, proc)!;
	};

	// Close input memfds in the parent — workers have their own copies.
	for (let i = 0z; i < n_workers; i += 1) {
		io::close(in_fds[i])!;
	};

	// Wait for all workers.
	for (let i = 0z; i < n_workers; i += 1) {
		const status = exec::wait(&procs[i])!;
		match (exec::check(&status)) {
			case void => void;
			case let s: !exec::exit_status =>
				fmt::fatalf("Worker {} failed: {}", i, exec::exitstr(s));
		};
	};

	const elapsed_ns = time::diff(start_time, time::now(time::clock::MONOTONIC));
	const elapsed_s  = elapsed_ns / time::SECOND;
	const elapsed_ms = (elapsed_ns % time::SECOND) / time::MILLISECOND;

	// Stitch: STREAMINFO followed by each chunk in order.
	// Seek each output memfd back to start before copying.
	const out_file = match (os::create(output_path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error creating output: {}", fs::strerror(e));
	};
	defer io::close(out_file)!;

	let writer = flac::newwriter(out_file);
	flac::write_stream_header(&writer, &dec)!;
	flac::flush(&writer)!;

	for (let i = 0z; i < n_workers; i += 1) {
		io::seek(out_fds[i], 0, io::whence::SET)!;
		io::copy(out_file, out_fds[i])!;
		io::close(out_fds[i])!;
	};

	fmt::printfln("Encoded {} frames in {}.{}{}s", total_frames, elapsed_s,
		if (elapsed_ms < 10) "00" else if (elapsed_ms < 100) "0" else "",
		elapsed_ms)!;
};

// run_worker reads PCM from fd 3 via mmap, encodes to FLAC frames, writes
// to fd 4, and exits.
// Args: --worker <start_frame> <channels> <bps> <sample_rate>
//          [1]       [2]          [3]      [4]      [5]
fn run_worker(args: []str) void = {
	const start_frame = strconv::stou32(args[2]) as u32;
	const channels    = (strconv::stou32(args[3]) as u32): size;
	const bps         = (strconv::stou32(args[4]) as u32): u8;
	const sample_rate = strconv::stou32(args[5]) as u32;

	// fd 3 and 4 are wired up by the orchestrator via exec::addfile.
	const in_file  = io::fdopen(WORKER_IN_FD);
	const out_file = io::fdopen(WORKER_OUT_FD);

	// mmap the input memfd — page-aligned pointer makes the i32
	// reinterpret safe, and avoids any allocation or copy.
	const file_size = io::seek(in_file, 0, io::whence::END)!: size;
	io::seek(in_file, 0, io::whence::SET)!;

	const ptr = match (io::mmap(null, file_size,
			io::prot::READ,
			io::mflag::PRIVATE,
			in_file, 0)) {
		case let p: *opaque => yield p;
		case let e: errors::error =>
			fmt::fatalf("Worker: mmap failed: {}", errors::strerror(e));
	};
	defer io::munmap(ptr, file_size)!;

	const n_samples = file_size / 4;
	const samples   = (ptr: *[*]i32)[..n_samples];

	let writer = flac::newwriter(out_file);
	encode_chunk(&writer, samples, channels, bps, sample_rate, start_frame);
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
		const remaining     = len(all_samples) - pos;
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

// write_raw_samples_fd writes a []i32 to an io::file as bulk little-endian bytes.
fn write_raw_samples_fd(fd: io::file, samples: []i32) void = {
	const bytes = samples: *[*]u8;
	io::writeall(fd, bytes[..len(samples) * 4])!;
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

	let best_score             = math::INF;
	let best_shift             = 0u8;
	let best_q_lpc:     [12]i32 = [0...];
	let is_fixed               = true;
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
