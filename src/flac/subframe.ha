use io;
use lpc;
use memio;
use math;
use fmt;

export fn write_subframe_lpc(
	w: *bit_writer,
	samples: []i32,
	q_lpc: []i32,
	shift: u8,
	bps: u8,
) (size | io::error) = {
	const n = len(samples);
	const p = len(q_lpc);
	if (p == 0) {
		return write_subframe_verbatim(w, samples, bps);
	};

	// Compute LPC residuals
	let lpc_res_buf: [4096]i32 = [0...];
	let lpc_res = lpc_res_buf[..n];
	lpc::predict_lpc(samples, q_lpc, shift, lpc_res);

	// Track if LPC has completely exploded at any single sample (transient)
	let lpc_exploded = false;
	let lpc_sum = 0u64;
	for (let i = p; i < n; i += 1) {
		const v = lpc_res[i];
		const abs_v = if (v >= 0) v: u64 else (-(v: i64)): u64;
		lpc_sum += abs_v;

		// CRITICAL CIRCUIT BREAKER: If a single residual sample is massive
		// (e.g., greater than 8192), the LPC filter has failed to model
		// this drum transient. We flag it to abandon LPC immediately.
		if (abs_v > 8192) {
			lpc_exploded = true;
		};
	};

	// Compute FIXED order 1 residuals for comparison
	let fixed_res_buf: [4096]i32 = [0...];
	fixed_res_buf[0] = samples[0];
	for (let i = 1z; i < n; i += 1) {
		fixed_res_buf[i] = samples[i] - samples[i - 1];
	};

	let fixed_sum = 0u64;
	for (let i = 1z; i < n; i += 1) {
		const v = fixed_res_buf[i];
		fixed_sum += if (v >= 0) v: u64 else (-(v: i64)): u64;
	};

	// FORCE FIXED ORDER 1 if LPC exploded on a snare/hi-hat transient,
	// or if Fixed math is globally more efficient.
	if (lpc_exploded || fixed_sum < lpc_sum) {
		// Subframe header: FIXED order 1 = type 0b001001, header = 0 | 001001 | 0 = 0x12
		let total_bits = 0z;
		total_bits += write_bits(w, 0x12, 8)?;
		// One warm-up sample
		total_bits += write_bits(w, (samples[0]: u64) & ((1u64 << bps) - 1), bps)?;

		// Compute and write residuals
		let res_buf: [4096]i32 = [0...];
		for (let i = 1z; i < n; i += 1) {
			res_buf[i] = samples[i] - samples[i - 1];
		};

		total_bits += write_residuals(w, res_buf[1..n], 1)?;
		return total_bits;
	};

	// Otherwise proceed with standard LPC safely
	let total_bits = 0z;
	const order = p: u8;

	const subframe_type = 0b00100000u64 | (order - 1): u64;
	total_bits += write_bits(w, subframe_type << 1, 8)?;

	for (let i = 0z; i < p; i += 1) {
		total_bits += write_bits(w, (samples[i]: u64) & ((1u64 << bps) - 1), bps)?;
	};

	const coeff_precision: u8 = 15;
	total_bits += write_bits(w, (coeff_precision - 1): u64, 4)?;
	total_bits += write_bits(w, shift: u64, 5)?;
	for (let i = 0z; i < p; i += 1) {
		total_bits += write_bits(w, (q_lpc[i]: u64) & ((1u64 << coeff_precision) - 1), coeff_precision)?;
	};

	total_bits += write_residuals(w, lpc_res[p..], order)?;
	return total_bits;
};

fn write_subframe_verbatim(
	w: *bit_writer,
	samples: []i32,
	bps: u8,
) (size | io::error) = {
	let total_bits = 0z;
	total_bits += write_bits(w, 0x04, 8)?;
	for (let i = 0z; i < len(samples); i += 1) {
		total_bits += write_bits(w, (samples[i]: u64) & ((1u64 << bps) - 1), bps)?;
	};
	return total_bits;
};

fn write_residuals(
	w: *bit_writer,
	residuals: []i32,
	predictor_order: u8,
) (size | io::error) = {
	let total_bits = 0z;

	total_bits += write_bits(w, 0, 2)?;

	const partition_order: u8 = 0;
	total_bits += write_bits(w, partition_order: u64, 4)?;

	let max_zz = 0u32;
	for (let i = 0z; i < len(residuals); i += 1) {
		const zz = zig_zag(residuals[i]);
		if (zz > max_zz) max_zz = zz;
	};

	let rice_k = optimize_rice(residuals);

	// Ensure max quotient stays within FLAC's hard limit of 30
	for (max_zz >> rice_k: u32 > 30 && rice_k < 14) {
		rice_k += 1;
	};

	total_bits += write_bits(w, rice_k: u64, 4)?;

	for (let i = 0z; i < len(residuals); i += 1) {
		total_bits += write_rice(w, residuals[i], rice_k)?;
	};

	return total_bits;
};

@test fn test_subframe_lpc() void = {
	let buf: [64]u8 = [0...];
	let mem = memio::fixed(buf);
	let w = newwriter(&mem);

	let samples: []i32 = [100, 105, 110];
	let q_lpc: []i32 = [1024];
	let shift: u8 = 10;
	let bps: u8 = 16;

	const bits = write_subframe_lpc(&w, samples, q_lpc, shift, bps)!;
	flush(&w)!;

	assert(bits > 0);
	assert(buf[0] == 0x40 || buf[0] == 0x12);
};
