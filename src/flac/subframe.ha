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

	// Evaluate Fixed Predictors (Orders 0 to 4)
	let best_fixed_order = 0u8;
	let min_fixed_variance = math::INF;
	let fixed_res_buf: [4096]i32 = [0...];
	let best_fixed_res: [4096]i32 = [0...];
	const max_possible_order = if (n < 4) n: u8 else 4u8;

	for (let order = 0u8; order <= max_possible_order; order += 1) {
		lpc::predict_fixed(samples, order, fixed_res_buf[..n]);

		let current_fixed_sum = 0u64;
		for (let i = order: size; i < n; i += 1) {
			const v = fixed_res_buf[i];
			current_fixed_sum += if (v >= 0) v: u64 else (-(v: i64)): u64;
		};

		// Normalize by actual counted elements to make evaluation fair
		const counted_elements = (n - order: size): f64;
		const current_fixed_variance = if (counted_elements > 0.0) {
			yield (current_fixed_sum: f64) / counted_elements;
		} else {
			yield math::INF;
		};

		if (current_fixed_variance < min_fixed_variance) {
			min_fixed_variance = current_fixed_variance;
			best_fixed_order = order;
			for (let i = 0z; i < n; i += 1) {
				best_fixed_res[i] = fixed_res_buf[i];
			};
		};
	};

	// Compute LPC residuals
	let lpc_res_buf: [4096]i32 = [0...];
	let lpc_res = lpc_res_buf[..n];
	lpc::predict_lpc(samples, q_lpc, shift, lpc_res);

	let lpc_exploded = false;
	let lpc_sum = 0u64;
	for (let i = p; i < n; i += 1) {
		const v = lpc_res[i];
		const abs_v = if (v >= 0) v: u64 else (-(v: i64)): u64;
		lpc_sum += abs_v;
		if (abs_v > 8192) {
			lpc_exploded = true;
		};
	};

	// Normalize LPC sum to compare fairly against fixed predictor variance
	const lpc_counted_elements = (n - p): f64;
	const lpc_variance = if (lpc_counted_elements > 0.0) {
		yield (lpc_sum: f64) / lpc_counted_elements;
	} else {
		yield math::INF;
	};

	// Optimization Selection Barrier (comparing normalized variance)
	if (lpc_exploded || min_fixed_variance < lpc_variance) {
		return write_subframe_fixed(w, samples, best_fixed_res[..n], best_fixed_order, bps);
	};

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

// Writes a FLAC fixed-predictor subframe (Orders 0 - 4)
fn write_subframe_fixed(
	w: *bit_writer,
	samples: []i32,
	residuals: []i32,
	order: u8,
	bps: u8,
) (size | io::error) = {
	let total_bits = 0z;
	const n = len(samples);

	// FLAC Fixed Subframe encoding type bits prefix format: 001000 + order
	const subframe_type = 0b001000u64 | order: u64;
	total_bits += write_bits(w, subframe_type << 1, 8)?;

	// Write unencoded "warm-up" samples (matching predictor order length)
	for (let i = 0z; i < order: size; i += 1) {
		total_bits += write_bits(w, (samples[i]: u64) & ((1u64 << bps) - 1), bps)?;
	};

	// Write the residual sequence following the warmup phase
	total_bits += write_residuals(w, residuals[order..n], order)?;
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

	const partition_order: u8 = 4;
	total_bits += write_bits(w, partition_order: u64, 4)?;

	const num_partitions = (1z << partition_order);

	const total_samples_including_warmup = len(residuals) + predictor_order: size;
	const partition_samples = total_samples_including_warmup / num_partitions;

	for (let p = 0z; p < num_partitions; p += 1) {
		const start_full = p * partition_samples;
		const end_full = if (p == num_partitions - 1) total_samples_including_warmup else (p + 1) * partition_samples;

		let start_idx = if (start_full < predictor_order: size) 0z else start_full - predictor_order: size;
		let end_idx = if (end_full < predictor_order: size) 0z else end_full - predictor_order: size;

		if (start_idx == end_idx) {
			total_bits += write_bits(w, 0, 4)?;
			continue;
		};

		const part_res = residuals[start_idx..end_idx];

		let max_zz = 0u32;
		for (let i = 0z; i < len(part_res); i += 1) {
			const zz = zig_zag(part_res[i]);
			if (zz > max_zz) max_zz = zz;
		};

		let rice_k = optimize_rice(part_res);

		for (max_zz >> rice_k: u32 > 30 && rice_k < 14) {
			rice_k += 1;
		};

		total_bits += write_bits(w, rice_k: u64, 4)?;

		for (let i = 0z; i < len(part_res); i += 1) {
			total_bits += write_rice(w, part_res[i], rice_k)?;
		};
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
	assert(buf[0] == 0x40 || (buf[0] >= 0x10 && buf[0] <= 0x1a));
};
