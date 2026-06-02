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

	// Empty coefficient map signals explicit routing to Fixed Predictors
	if (p == 0) {
		let best_fixed_order = 0u8;
		let min_fixed_sum = math::INF;
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
			if (current_fixed_sum: f64 < min_fixed_sum) {
				min_fixed_sum = current_fixed_sum: f64;
				best_fixed_order = order;
				for (let i = 0z; i < n; i += 1) {
					best_fixed_res[i] = fixed_res_buf[i];
				};
			};
		};
		return write_subframe_fixed(w, samples, best_fixed_res[..n], best_fixed_order, bps);
	};

	// Compute LPC residuals using the explicitly chosen parameters
	let lpc_res_buf: [4096]i32 = [0...];
	let lpc_res = lpc_res_buf[..n];
	lpc::predict_lpc(samples, q_lpc, shift, lpc_res);

	let total_bits = 0z;
	const order = p: u8;
	const subframe_type = 0b00100000u64 | (order - 1): u64;
	total_bits += write_bits(w, subframe_type << 1, 8)?;

	for (let i = 0z; i < p; i += 1) {
		const val_u64 = samples[i]: i64: u64;
		total_bits += write_bits(w, val_u64, bps)?;
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

fn write_subframe_fixed(
	w: *bit_writer,
	samples: []i32,
	residuals: []i32,
	order: u8,
	bps: u8,
) (size | io::error) = {
	let total_bits = 0z;
	const n = len(samples);

	const subframe_type = 0b001000u64 | order: u64;
	total_bits += write_bits(w, subframe_type << 1, 8)?;

	for (let i = 0z; i < order: size; i += 1) {
		const val_u64 = samples[i]: i64: u64;
		total_bits += write_bits(w, val_u64, bps)?;
	};

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
		const val_u64 = samples[i]: i64: u64;
		total_bits += write_bits(w, val_u64, bps)?;
	};
	return total_bits;
};

fn best_partition_order(residuals: []i32, predictor_order: u8) u8 = {
    const n = len(residuals);
    const block_size = n + predictor_order: size;
    let best_order: u8 = 0;
    let best_bits: u64 = ~0u64;

    for (let order = 0u8; order <= 4u8; order += 1) {
        const num_partitions = 1u32 << order: u32;
        if (block_size: u32 % num_partitions != 0) continue;
        const part_size = block_size: u32 / num_partitions;
        if (part_size <= predictor_order: u32) continue;

        let use_rice2 = false;
        let pos = 0z;
        for (let p = 0u32; p < num_partitions; p += 1) {
            const count: size = if (p == 0)
                (part_size - predictor_order: u32): size
            else
                part_size: size;
            const partition = residuals[pos..pos + count];

            let rice_k = optimize_rice(partition);
            let max_zz = 0u32;
            for (let i = 0z; i < len(partition); i += 1) {
                const zz = zig_zag(partition[i]);
                if (zz > max_zz) max_zz = zz;
            };
            for (max_zz >> rice_k: u32 > 30 && rice_k < 30) {
                rice_k += 1;
            };
            if (rice_k > 14) {
                use_rice2 = true;
            };
            pos += count;
        };

        let estimated_bits: u64 = 0;
        const k_bits: u64 = if (use_rice2) 5 else 4;
        pos = 0z;
        for (let p = 0u32; p < num_partitions; p += 1) {
            const count: size = if (p == 0)
                (part_size - predictor_order: u32): size
            else
                part_size: size;
            const partition = residuals[pos..pos + count];

            let rice_k = optimize_rice(partition);
            let max_zz = 0u32;
            for (let i = 0z; i < len(partition); i += 1) {
                const zz = zig_zag(partition[i]);
                if (zz > max_zz) max_zz = zz;
            };
            for (max_zz >> rice_k: u32 > 30 && rice_k < 30) {
                rice_k += 1;
            };

            estimated_bits += k_bits;
            for (let i = 0z; i < len(partition); i += 1) {
                const zz = zig_zag(partition[i]);
                estimated_bits += (zz >> rice_k: u32): u64 + 1 + rice_k: u64;
            };
            pos += count;
        };
        if (estimated_bits < best_bits) {
            best_bits = estimated_bits;
            best_order = order;
        };
    };

    return best_order;
};

fn write_residuals(
    w: *bit_writer,
    residuals: []i32,
    predictor_order: u8,
) (size | io::error) = {
    let total_bits = 0z;
    const partition_order: u8 = best_partition_order(residuals, predictor_order);
    const block_size = len(residuals) + predictor_order: size;
    const num_partitions = 1u32 << partition_order: u32;
    const part_size = block_size: u32 / num_partitions;

    let use_rice2 = false;
    let pos = 0z;
    for (let p = 0u32; p < num_partitions; p += 1) {
        const count: size = if (p == 0)
            (part_size - predictor_order: u32): size
        else
            part_size: size;
        const end = pos + count;

        let rice_k = optimize_rice(residuals[pos..end]);
        let max_zz = 0u32;
        for (let i = pos; i < end; i += 1) {
            const zz = zig_zag(residuals[i]);
            if (zz > max_zz) max_zz = zz;
        };
        for (max_zz >> rice_k: u32 > 30 && rice_k < 30) {
            rice_k += 1;
        };
        if (rice_k > 14) {
            use_rice2 = true;
        };
        pos += count;
    };

    if (use_rice2) {
        total_bits += write_bits(w, 1, 2)?;
    } else {
        total_bits += write_bits(w, 0, 2)?;
    };
    total_bits += write_bits(w, partition_order: u64, 4)?;

    pos = 0z;
    for (let p = 0u32; p < num_partitions; p += 1) {
        const count: size = if (p == 0)
            (part_size - predictor_order: u32): size
        else
            part_size: size;
        const end = pos + count;

        let rice_k = optimize_rice(residuals[pos..end]);
        let max_zz = 0u32;
        for (let i = pos; i < end; i += 1) {
            const zz = zig_zag(residuals[i]);
            if (zz > max_zz) max_zz = zz;
        };
        for (max_zz >> rice_k: u32 > 30 && rice_k < 30) {
            rice_k += 1;
        };

        if (use_rice2) {
            total_bits += write_bits(w, rice_k: u64, 5)?;
        } else {
            total_bits += write_bits(w, rice_k: u64, 4)?;
        };

        for (let i = pos; i < end; i += 1) {
            total_bits += write_rice(w, residuals[i], rice_k)?;
        };
        pos += count;
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
