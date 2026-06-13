use errors;
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

export fn write_subframe_constant(
    w: *bit_writer,
    value: i32,
    bps: u8,
) (size | io::error) = {
    let total_bits = 0z;
    // Subframe type 0b000000, wasted bits flag 0 = 0x00
    total_bits += write_bits(w, 0x00, 8)?;
    const val_u64 = value: i64: u64;
    total_bits += write_bits(w, val_u64, bps)?;
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

// ---------------------------------------------------------------------------
// Subframe decoding
// ---------------------------------------------------------------------------

// Reads and decodes a single FLAC subframe into `out`, which must be
// pre-allocated to `block_size` samples. `bps` is the effective bits per
// sample for this subframe (may be bps+1 for the side channel in mid/side).
export fn read_subframe(
	r: *bit_reader,
	out: []i32,
	bps: u8,
) (void | io::error | io::EOF) = {
	const n = len(out);

	// Subframe header byte: reserved(1) | type(6) | wasted_bits_flag(1)
	const hdr = match (read_bits(r, 8)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	// Wasted bits flag: if set, a unary-coded wasted bit count follows.
	// flac-enc never sets this, but handled to work with generic encoders.
	let wasted: u8 = 0;
	if (hdr & 1 == 1) {
		const w = match (read_unary(r)) {
			case let v: u32 => yield (v + 1): u8;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		wasted = w;
	};
	const effective_bps = bps - wasted;

	const subframe_type = ((hdr >> 1) & 0x3F): u8;

	if (subframe_type == 0b000000) {
		// Constant subframe: one sample replicated across the block.
		return read_subframe_constant(r, out, effective_bps, wasted);
	} else if (subframe_type == 0b000010) {
		// Verbatim subframe.
		return read_subframe_verbatim(r, out, effective_bps, wasted);
	} else if (subframe_type & 0b111000 == 0b001000) {
		// Fixed predictor subframe: low 3 bits are order.
		const order = (subframe_type & 0b111): u8;
		return read_subframe_fixed(r, out, effective_bps, order, wasted);
	} else if (subframe_type & 0b100000 == 0b100000) {
		// LPC subframe: low 5 bits are order-1.
		const order = ((subframe_type & 0b011111) + 1): u8;
		return read_subframe_lpc(r, out, effective_bps, order, wasted);
	} else {
		return errors::invalid;
	};
};

fn read_subframe_constant(
	r: *bit_reader,
	out: []i32,
	bps: u8,
	wasted: u8,
) (void | io::error | io::EOF) = {
	const raw = match (read_bits(r, bps)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const value = (sign_extend(raw, bps): u32 << wasted: u32): i32;
	for (let i = 0z; i < len(out); i += 1) {
		out[i] = value;
	};
};

fn read_subframe_verbatim(
	r: *bit_reader,
	out: []i32,
	bps: u8,
	wasted: u8,
) (void | io::error | io::EOF) = {
	for (let i = 0z; i < len(out); i += 1) {
		const raw = match (read_bits(r, bps)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		out[i] = (sign_extend(raw, bps): u32 << wasted: u32): i32;
	};
};

fn read_subframe_fixed(
	r: *bit_reader,
	out: []i32,
	bps: u8,
	order: u8,
	wasted: u8,
) (void | io::error | io::EOF) = {
	const n = len(out);

	// Warmup samples.
	for (let i = 0z; i < order: size; i += 1) {
		const raw = match (read_bits(r, bps)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		out[i] = (sign_extend(raw, bps): u32 << wasted: u32): i32;
	};

	// Residuals into out[order..], then reconstruct in-place.
	read_residuals(r, out[order..], order)?;
	lpc::restore_fixed(out, order, out);

	// Apply wasted bits shift if needed.
	if (wasted > 0) {
		for (let i = order: size; i < n; i += 1) {
			out[i] = (out[i]: u32 << wasted: u32): i32;
		};
	};
};

fn read_subframe_lpc(
	r: *bit_reader,
	out: []i32,
	bps: u8,
	order: u8,
	wasted: u8,
) (void | io::error | io::EOF) = {
	const n = len(out);

	// Warmup samples.
	for (let i = 0z; i < order: size; i += 1) {
		const raw = match (read_bits(r, bps)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		out[i] = (sign_extend(raw, bps): u32 << wasted: u32): i32;
	};

	// Coefficient precision (4 bits, stored as precision-1).
	const prec_raw = match (read_bits(r, 4)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const precision = (prec_raw + 1): u8;

	// Quantization shift (5 bits, signed).
	const shift_raw = match (read_bits(r, 5)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const shift = shift_raw: u8;

	// Quantized coefficients.
	let q_lpc: [12]i32 = [0...];
	for (let i = 0z; i < order: size; i += 1) {
		const raw = match (read_bits(r, precision)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		q_lpc[i] = sign_extend(raw, precision);
	};

	// Residuals into out[order..].
	read_residuals(r, out[order..], order)?;

	// Reconstruct via LPC synthesis.
	lpc::restore_lpc(out, q_lpc[..order], shift, out);

	// Apply wasted bits shift if needed.
	if (wasted > 0) {
		for (let i = order: size; i < n; i += 1) {
			out[i] = (out[i]: u32 << wasted: u32): i32;
		};
	};
};

fn read_residuals(
	r: *bit_reader,
	out: []i32,
	predictor_order: u8,
) (void | io::error | io::EOF) = {
	const method = match (read_bits(r, 2)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const param_bits: u8 = if (method == 0) 4 else 5;

	// Partition order: 4 bits.
	const partition_order = match (read_bits(r, 4)) {
		case let v: u64 => yield v: u8;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};

	const block_size = len(out) + predictor_order: size;
	const num_partitions = 1u32 << (partition_order: u32);
	const part_size = block_size: u32 / num_partitions;

	let pos = 0z;
	for (let p = 0u32; p < num_partitions; p += 1) {
		const count: size = if (p == 0)
			(part_size - predictor_order: u32): size
		else
			part_size: size;

		// Rice parameter for this partition.
		const rice_k = match (read_bits(r, param_bits)) {
			case let v: u64 => yield v: u8;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};

		for (let i = 0z; i < count; i += 1) {
			const val = match (read_rice(r, rice_k)) {
				case let v: i32 => yield v;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			out[pos] = val;
			pos += 1;
		};
	};
};

// Sign-extends a value read as `bits`-wide unsigned into a signed i32.
fn sign_extend(val: u64, bits: u8) i32 = {
	if (bits == 0) return 0;
	const sign_bit = 1u64 << ((bits - 1): u64);
	if (val & sign_bit != 0) {
		// Negative: fill upper bits with 1s.
		const mask = ~((sign_bit << 1) - 1);
		return (val | mask): i64: i32;
	} else {
		return val: i32;
	};
};
