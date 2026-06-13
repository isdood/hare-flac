use fmt;
use os;
use os::exec;
use io;
use fs;
use endian;
use errors;
use flac;
use strings;
use strconv;
use wav;
use time;

def MAX_BLOCK: size = 65535;

// Child fd slots for memfd IPC.
def WORKER_IN_FD:  int = 3;
def WORKER_OUT_FD: int = 4;

export fn main() void = {
	const args = os::args;

	// Worker mode: flac-dec --worker <byte_offset> <n_samples> <ch> <bps> <rate> <path>
	if (len(args) >= 2 && args[1] == "--worker") {
		if (len(args) < 9) {
			fmt::fatal("Usage: flac-dec --worker <offset> <n_samples> <start_sample> <ch> <bps> <rate> <path>");
		};
		run_worker(args);
		return;
	};

	if (len(args) < 3) {
		fmt::fatal("Usage: flac-dec <input.flac> <output.wav>");
	};
	const input_path  = args[1];
	const output_path = args[2];

	const in_file = match (os::open(input_path)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error opening input: {}", fs::strerror(e));
	};
	defer io::close(in_file)!;

	let reader = flac::newreader(in_file);

	const info = match (flac::read_streaminfo(&reader)) {
    case let s: flac::streaminfo => yield s;
    case let e: io::error =>
        fmt::fatalf("Error reading STREAMINFO: {}", io::strerror(e));
    case io::EOF =>
        fmt::fatal("Unexpected EOF reading STREAMINFO");
    };


	const channels       = info.channels: size;
	const bps            = info.bps;
	const sample_rate    = info.sample_rate;
	const total_samples  = info.total_samples;
	const seektable      = info.seektable;
	defer free(seektable);

	fmt::printfln("Decoding: {} Hz, {} ch, {} bps, {} samples",
		sample_rate, channels, bps, total_samples)!;


	// Parallel path: use seektable to dispatch workers.
	if (len(seektable) > 1) {
	    decode_parallel(in_file, input_path, output_path, seektable,
				channels, bps, sample_rate, total_samples, info.audio_start);
		return;
	};

	// Single-process fallback.
	let capacity = if (total_samples > 0)
		total_samples: size * channels
	else
		65536z;
	let all_samples: []i32 = alloc([0i32...], capacity) as []i32;
	let n_samples = 0z;
	let frame_count = 0z;

	const start_time = time::now(time::clock::MONOTONIC);

	let ch0: []i32 = alloc([0i32...], MAX_BLOCK) as []i32;
	let ch1: []i32 = alloc([0i32...], MAX_BLOCK) as []i32;
	defer free(ch0);
	defer free(ch1);

	for (n_samples < total_samples: size * channels) {
		const hdr = match (flac::read_frame_header(&reader, bps, sample_rate)) {
			case let h: flac::frame_header => yield h;
			case io::EOF => break;
			case let e: io::error =>
				fmt::fatalf("Error reading frame header: {}",
					io::strerror(e));
		};

		const block_size = hdr.block_size: size;
		const bps_ch0: u8 = if (hdr.channel_assignment == 9) bps + 1
			else bps;
		const bps_ch1: u8 = if (hdr.channel_assignment == 8
			|| hdr.channel_assignment == 10) bps + 1
			else bps;

		match (flac::read_subframe(&reader, ch0[..block_size], bps_ch0)) {
			case void => void;
			case let e: io::error =>
				fmt::fatalf("Error decoding subframe 0: {}",
					io::strerror(e));
			case io::EOF =>
				fmt::fatal("Unexpected EOF in subframe 0");
		};

		if (channels > 1) {
			match (flac::read_subframe(&reader, ch1[..block_size], bps_ch1)) {
				case void => void;
				case let e: io::error =>
					fmt::fatalf("Error decoding subframe 1: {}",
						io::strerror(e));
				case io::EOF =>
					fmt::fatal("Unexpected EOF in subframe 1");
			};
		};

		flac::align_reader(&reader);
		match (flac::read_bits_nocrc(&reader, 16)) {
			case u64 => void;
			case let e: io::error =>
				fmt::fatalf("Error reading frame CRC: {}",
					io::strerror(e));
			case io::EOF =>
				fmt::fatal("Unexpected EOF reading frame CRC");
		};

		if (hdr.channel_assignment == 10) {
			for (let i = 0z; i < block_size; i += 1) {
				const mid  = ch0[i];
				const side = ch1[i];
				const m = (mid << 1) | (side & 1);
				ch0[i] = (m + side) >> 1;
				ch1[i] = (m - side) >> 1;
			};
		} else if (hdr.channel_assignment == 8) {
			for (let i = 0z; i < block_size; i += 1) {
				ch1[i] = ch0[i] - ch1[i];
			};
		} else if (hdr.channel_assignment == 9) {
			for (let i = 0z; i < block_size; i += 1) {
				ch0[i] = ch1[i] + ch0[i];
			};
		};

		const needed = n_samples + block_size * channels;
		if (needed > len(all_samples)) {
			const new_cap = if (needed * 2 > len(all_samples) * 2)
				needed * 2
			else
				len(all_samples) * 2;
			let new_buf: []i32 = alloc([0i32...], new_cap) as []i32;
			new_buf[..n_samples] = all_samples[..n_samples];
			free(all_samples);
			all_samples = new_buf;
		};

		frame_count += 1;

		for (let i = 0z; i < block_size; i += 1) {
			all_samples[n_samples + i * channels] = ch0[i];
			if (channels > 1) {
				all_samples[n_samples + i * channels + 1] = ch1[i];
			};
		};
		n_samples += block_size * channels;
	};

	const elapsed_ns = time::diff(start_time, time::now(time::clock::MONOTONIC));
	const elapsed_s  = elapsed_ns / time::SECOND;
	const elapsed_ms = (elapsed_ns % time::SECOND) / time::MILLISECOND;

	const out_file = match (os::create(output_path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error creating output: {}", fs::strerror(e));
	};
	defer io::close(out_file)!;

	write_wav(out_file, all_samples[..n_samples], channels: u16, sample_rate, bps);
	free(all_samples);

	fmt::printfln("Decoded {} frames in {}.{}{}s",
		frame_count, elapsed_s,
		if (elapsed_ms < 10) "00" else if (elapsed_ms < 100) "0" else "",
		elapsed_ms)!;
};

fn write_wav_header(
	fd: io::file,
	n_samples: u32,
	channels: u16,
	sample_rate: u32,
	bps: u8,
) void = {
	const bytes_per_sample = (bps / 8): u32;
	const data_size   = n_samples * bytes_per_sample;
	const byte_rate   = sample_rate * channels: u32 * bytes_per_sample;
	const block_align = channels * bytes_per_sample: u16;

	let buf4: [4]u8 = [0...];
	let buf2: [2]u8 = [0...];

	io::writeall(fd, ['R', 'I', 'F', 'F'])!;
	endian::leputu32(buf4, 36 + data_size);
	io::writeall(fd, buf4)!;
	io::writeall(fd, ['W', 'A', 'V', 'E'])!;
	io::writeall(fd, ['f', 'm', 't', ' '])!;
	endian::leputu32(buf4, 16);
	io::writeall(fd, buf4)!;
	endian::leputu16(buf2, 1);
	io::writeall(fd, buf2)!;
	endian::leputu16(buf2, channels);
	io::writeall(fd, buf2)!;
	endian::leputu32(buf4, sample_rate);
	io::writeall(fd, buf4)!;
	endian::leputu32(buf4, byte_rate);
	io::writeall(fd, buf4)!;
	endian::leputu16(buf2, block_align);
	io::writeall(fd, buf2)!;
	endian::leputu16(buf2, bps: u16);
	io::writeall(fd, buf2)!;
	io::writeall(fd, ['d', 'a', 't', 'a'])!;
	endian::leputu32(buf4, data_size);
	io::writeall(fd, buf4)!;
};

fn write_wav(
	fd: io::file,
	samples: []i32,
	channels: u16,
	sample_rate: u32,
	bps: u8,
) void = {
	const bytes_per_sample = (bps / 8): u32;
	const n_samples        = len(samples): u32;
	const data_size        = n_samples * bytes_per_sample;
	const byte_rate        = sample_rate * channels: u32 * bytes_per_sample;
	const block_align      = channels * bytes_per_sample: u16;

	let buf4: [4]u8 = [0...];
	let buf2: [2]u8 = [0...];

	io::writeall(fd, ['R', 'I', 'F', 'F'])!;
	endian::leputu32(buf4, 36 + data_size);
	io::writeall(fd, buf4)!;
	io::writeall(fd, ['W', 'A', 'V', 'E'])!;
	io::writeall(fd, ['f', 'm', 't', ' '])!;
	endian::leputu32(buf4, 16);
	io::writeall(fd, buf4)!;
	endian::leputu16(buf2, 1);
	io::writeall(fd, buf2)!;
	endian::leputu16(buf2, channels);
	io::writeall(fd, buf2)!;
	endian::leputu32(buf4, sample_rate);
	io::writeall(fd, buf4)!;
	endian::leputu32(buf4, byte_rate);
	io::writeall(fd, buf4)!;
	endian::leputu16(buf2, block_align);
	io::writeall(fd, buf2)!;
	endian::leputu16(buf2, bps: u16);
	io::writeall(fd, buf2)!;
	io::writeall(fd, ['d', 'a', 't', 'a'])!;
	endian::leputu32(buf4, data_size);
	io::writeall(fd, buf4)!;

	def WBUF_SIZE: size = 65536;
	let wbuf: [WBUF_SIZE]u8 = [0...];
	let wpos = 0z;

	for (let i = 0z; i < len(samples); i += 1) {
		const s = samples[i];
		if (bps == 16) {
			if (wpos + 2 > WBUF_SIZE) {
				io::writeall(fd, wbuf[..wpos])!;
				wpos = 0;
			};
			wbuf[wpos]     = (s & 0xFF): u8;
			wbuf[wpos + 1] = ((s >> 8) & 0xFF): u8;
			wpos += 2;
		} else {
			if (wpos + 3 > WBUF_SIZE) {
				io::writeall(fd, wbuf[..wpos])!;
				wpos = 0;
			};
			wbuf[wpos]     = (s & 0xFF): u8;
			wbuf[wpos + 1] = ((s >> 8) & 0xFF): u8;
			wbuf[wpos + 2] = ((s >> 16) & 0xFF): u8;
			wpos += 3;
		};
	};
	if (wpos > 0) io::writeall(fd, wbuf[..wpos])!;
};

// ---------------------------------------------------------------------------
// Parallel decoder
// ---------------------------------------------------------------------------

fn decode_parallel(
	in_file:       io::file,
	input_path:    str,
	output_path:   str,
	seektable:     []flac::seekpoint,
	channels:      size,
	bps:           u8,
	sample_rate:   u32,
	total_samples: u64,
	audio_start:   u64,
) void = {
	const n_seek = len(seektable);
	const n_workers = match (os::cpucount()) {
		case let n: size => yield n;
		case => yield 1z;
	};
	const n_w = if (n_workers > n_seek) n_seek else n_workers;

	const self_path = os::args[0];

	let ch_str   = strings::dup(strconv::u64tos(channels: u64)) as str;
	defer free(ch_str);
	let bps_str  = strings::dup(strconv::u64tos(bps: u64)) as str;
	defer free(bps_str);
	let rate_str = strings::dup(strconv::u64tos(sample_rate: u64)) as str;
	defer free(rate_str);

	let seek_starts: []size = alloc([0z...], n_w) as []size;
	defer free(seek_starts);
	let seek_counts: []size = alloc([0z...], n_w) as []size;
	defer free(seek_counts);

	const base = n_seek / n_w;
	const rem  = n_seek % n_w;
	for (let i = 0z; i < n_w; i += 1) {
		seek_counts[i] = base + (if (i < rem) 1z else 0z);
		seek_starts[i] = if (i == 0) 0z
			else seek_starts[i - 1] + seek_counts[i - 1];
	};

	let out_fds: []io::file = alloc([0: io::file...], n_w) as []io::file;
	defer free(out_fds);

	let procs: []exec::process = [];
	defer free(procs);

	const start_time = time::now(time::clock::MONOTONIC);

	for (let i = 0z; i < n_w; i += 1) {
		const sp_first   = seek_starts[i];
		// If seektable[0].byte_offset >= audio_start the encoder stored
		// absolute file offsets; use directly. Otherwise offsets are
		// relative to the first audio frame; add audio_start.
		const byte_off = if (seektable[0].byte_offset >= audio_start)
			seektable[sp_first].byte_offset
		else
			audio_start + seektable[sp_first].byte_offset;
		const next_sp    = sp_first + seek_counts[i];
		const end_sample = if (next_sp < n_seek)
			seektable[next_sp].sample_number
		else
			total_samples;
		// n_samples is per-channel samples this worker must produce.
		const n_samples  = end_sample - seektable[sp_first].sample_number;

		const out_fd = match (os::memfd("flac-dec-out")) {
			case let f: io::file => yield f;
			case let e: errors::error =>
				fmt::fatalf("memfd failed: {}", errors::strerror(e));
		};
		out_fds[i] = out_fd;

		const start_sample = seektable[sp_first].sample_number;
		let off_str = strings::dup(strconv::u64tos(byte_off)) as str;
		defer free(off_str);
		let ns_str  = strings::dup(strconv::u64tos(n_samples)) as str;
		defer free(ns_str);
		let ss_str  = strings::dup(strconv::u64tos(start_sample)) as str;
		defer free(ss_str);

		let cmd = exec::cmd(self_path,
			"--worker",
			off_str, ns_str, ss_str,
			ch_str, bps_str, rate_str,
			input_path)!;
		exec::addfile(&cmd, WORKER_OUT_FD, out_fd)!;

		const proc = exec::start(&cmd)!;
		append(procs, proc)!;
	};

	for (let i = 0z; i < n_w; i += 1) {
		const status = exec::wait(&procs[i])!;
		match (exec::check(&status)) {
			case void => void;
			case let s: !exec::exit_status => {
				for (let j = i + 1; j < n_w; j += 1) {
					exec::kill(procs[j])!;
					exec::wait(&procs[j])!;
				};
				fmt::fatalf("Worker {} failed: {}", i, exec::exitstr(s));
			};
		};
	};

	const elapsed_ns = time::diff(start_time, time::now(time::clock::MONOTONIC));
	const elapsed_s  = elapsed_ns / time::SECOND;
	const elapsed_ms = (elapsed_ns % time::SECOND) / time::MILLISECOND;

	const out_file = match (os::create(output_path, 0o644)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Error creating output: {}", fs::strerror(e));
	};
	defer io::close(out_file)!;

	write_wav_header(out_file, total_samples: u32 * channels: u32,
		channels: u16, sample_rate, bps);

	def WBUF_SIZE: size = 65536;
	let wbuf: [WBUF_SIZE]u8 = [0...];
	let wpos = 0z;


	for (let i = 0z; i < n_w; i += 1) {
		io::seek(out_fds[i], 0, io::whence::SET)!;
		const worker_out = match (io::drain(out_fds[i])) {
			case let b: []u8 => yield b;
			case let e: io::error =>
				fmt::fatalf("Worker {}: drain failed: {}", i, io::strerror(e));
		};


		defer free(worker_out);
		let j = 0z;
		for (j + 4 <= len(worker_out)) {
			const s: i32 = (worker_out[j]: i32)
				| ((worker_out[j+1]: i32) << 8)
				| ((worker_out[j+2]: i32) << 16)
				| ((worker_out[j+3]: i32) << 24);
			if (bps == 16) {
				if (wpos + 2 > WBUF_SIZE) {
					io::writeall(out_file, wbuf[..wpos])!;
					wpos = 0;
				};
				wbuf[wpos]     = (s & 0xFF): u8;
				wbuf[wpos + 1] = ((s >> 8) & 0xFF): u8;
				wpos += 2;
			} else {
				if (wpos + 3 > WBUF_SIZE) {
					io::writeall(out_file, wbuf[..wpos])!;
					wpos = 0;
				};
				wbuf[wpos]     = (s & 0xFF): u8;
				wbuf[wpos + 1] = ((s >> 8) & 0xFF): u8;
				wbuf[wpos + 2] = ((s >> 16) & 0xFF): u8;
				wpos += 3;
			};
			j += 4;
		};
		io::close(out_fds[i])!;
	};
	if (wpos > 0) io::writeall(out_file, wbuf[..wpos])!;

	const total_frames = total_samples / seektable[0].frame_samples: u64;
	fmt::printfln("Decoded in {}.{}{}s ({} workers)",
		elapsed_s,
		if (elapsed_ms < 10) "00" else if (elapsed_ms < 100) "0" else "",
		elapsed_ms, n_w)!;
};

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

fn run_worker(args: []str) void = {
	const byte_offset  = strconv::stou64(args[2]) as u64;
	const n_samples    = strconv::stou64(args[3]) as u64;
	const start_sample = strconv::stou64(args[4]) as u64;
	const channels     = (strconv::stou64(args[5]) as u64): size;
	const bps          = (strconv::stou64(args[6]) as u64): u8;
	const sample_rate  = (strconv::stou64(args[7]) as u64): u32;
	// args[8] = input path
	const input_path   = args[8];

	const in_file = match (os::open(input_path)) {
		case let f: io::file => yield f;
		case let e: fs::error =>
			fmt::fatalf("Worker: cannot open {}: {}", input_path, fs::strerror(e));
	};
	defer io::close(in_file)!;
	const out_file = io::fdopen(WORKER_OUT_FD);

	io::seek(in_file, byte_offset: i64, io::whence::SET)!;

	let reader = flac::newreader(in_file);

	let ch0: []i32 = alloc([0i32...], MAX_BLOCK) as []i32;
	let ch1: []i32 = alloc([0i32...], MAX_BLOCK) as []i32;
	defer free(ch0);
	defer free(ch1);

	def WBUF: size = 65536;
	let wbuf: [WBUF]u8 = [0...];
	let wpos = 0z;

	// frame_pos tracks the absolute sample number of the current frame's start.
		// Derived from the frame number encoded in each frame header.
		let frame_pos = 0u64;
		let first_frame = true;
		let samples_written = 0u64;
		for (true) {
			// Stop once we've written enough samples.
			if (samples_written >= n_samples) break;
			const hdr = match (flac::read_frame_header(&reader, bps, sample_rate)) {
				case let h: flac::frame_header => yield h;
				case io::EOF => break;
				case let e: io::error =>
					fmt::fatalf("Worker: frame header error at sample {}/{}: {}",
						samples_written, n_samples, io::strerror(e));
			};
			if (first_frame) {
				frame_pos = hdr.frame_num: u64 * hdr.block_size: u64;
				first_frame = false;
			};

		const block_size = hdr.block_size: size;
		const bps_ch0: u8 = if (hdr.channel_assignment == 9) bps + 1
			else bps;
		const bps_ch1: u8 = if (hdr.channel_assignment == 8
			|| hdr.channel_assignment == 10) bps + 1
			else bps;

		match (flac::read_subframe(&reader, ch0[..block_size], bps_ch0)) {
			case void => void;
			case let e: io::error =>
				fmt::fatalf("Worker: subframe 0 error: {}", io::strerror(e));
			case io::EOF =>
				fmt::fatal("Worker: unexpected EOF in subframe 0");
		};
		if (channels > 1) {
			match (flac::read_subframe(&reader, ch1[..block_size], bps_ch1)) {
				case void => void;
				case let e: io::error =>
					fmt::fatalf("Worker: subframe 1 error: {}",
						io::strerror(e));
				case io::EOF =>
					fmt::fatal("Worker: unexpected EOF in subframe 1");
			};
		};

		flac::align_reader(&reader);
		match (flac::read_bits_nocrc(&reader, 16)) {
			case u64 => void;
			case io::error => void;
			case io::EOF => break;
		};

		if (hdr.channel_assignment == 10) {
			for (let i = 0z; i < block_size; i += 1) {
				const mid  = ch0[i];
				const side = ch1[i];
				const m = (mid << 1) | (side & 1);
				ch0[i] = (m + side) >> 1;
				ch1[i] = (m - side) >> 1;
			};
		} else if (hdr.channel_assignment == 8) {
			for (let i = 0z; i < block_size; i += 1) {
				ch1[i] = ch0[i] - ch1[i];
			};
		} else if (hdr.channel_assignment == 9) {
			for (let i = 0z; i < block_size; i += 1) {
				ch0[i] = ch1[i] + ch0[i];
			};
		};

		// Write only samples within [start_sample, start_sample + n_samples).
		for (let i = 0z; i < block_size; i += 1) {
			const abs_sample = frame_pos + i: u64;
			if (abs_sample < start_sample) continue;
			if (samples_written >= n_samples) break;

			const s0 = ch0[i];
			if (wpos + 4 > WBUF) {
				io::writeall(out_file, wbuf[..wpos])!;
				wpos = 0;
			};
			wbuf[wpos]     = (s0 & 0xFF): u8;
			wbuf[wpos + 1] = ((s0 >> 8)  & 0xFF): u8;
			wbuf[wpos + 2] = ((s0 >> 16) & 0xFF): u8;
			wbuf[wpos + 3] = ((s0 >> 24) & 0xFF): u8;
			wpos += 4;

			if (channels > 1) {
				const s1 = ch1[i];
				if (wpos + 4 > WBUF) {
					io::writeall(out_file, wbuf[..wpos])!;
					wpos = 0;
				};
				wbuf[wpos]     = (s1 & 0xFF): u8;
				wbuf[wpos + 1] = ((s1 >> 8)  & 0xFF): u8;
				wbuf[wpos + 2] = ((s1 >> 16) & 0xFF): u8;
				wbuf[wpos + 3] = ((s1 >> 24) & 0xFF): u8;
				wpos += 4;
			};
			samples_written += 1;
		};

		frame_pos += hdr.block_size: u64;
	};

	if (wpos > 0) io::writeall(out_file, wbuf[..wpos])!;
};
