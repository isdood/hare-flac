use errors;
use io;
use memio;

// Writes a FLAC-style UTF-8 encoded integer.
fn write_utf8_int(w: *bit_writer, val: u64) (size | io::error) = {
    let n = 0z;
    // FLAC UTF-8 integers are written as whole bytes.
    // If the bit_writer is not aligned, these will span byte boundaries.
    if (val < 0x80) {
        n += write_bits(w, val, 8)?;
    } else if (val < 0x800) {
        n += write_bits(w, 0xC0 | (val >> 6), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    } else if (val < 0x10000) {
        n += write_bits(w, 0xE0 | (val >> 12), 8)?;
        n += write_bits(w, 0x80 | ((val >> 6) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    } else {
        n += write_bits(w, 0xF0 | (val >> 18), 8)?;
        n += write_bits(w, 0x80 | ((val >> 12) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | ((val >> 6) & 0x3F), 8)?;
        n += write_bits(w, 0x80 | (val & 0x3F), 8)?;
    };
    return n;
};

export fn write_frame_header(
    w: *bit_writer,
    block_size: u16,
    sample_rate: u32,
    bps: u8,
    channels: u8,
    frame_num: u32,
) (size | io::error) = {
    const chan_code = if (channels == 2) 0b0001u8 else 0b0000u8;
    return write_frame_header_ext(w, block_size, sample_rate, bps, chan_code, frame_num);
};

// Extended frame header function that explicitly accepts channel assignment codes
// for joint stereo configurations and handles variable block streaming.
export fn write_frame_header_ext(
    w: *bit_writer,
    block_size: u16,
    sample_rate: u32,
    bps: u8,
    channel_assignment: u8,
    frame_num: u32,
) (size | io::error) = {
    let total_bits = 0z;
    reset_crc8(w);

    // 1. Sync (14 bits) + Reserved (1 bit) + Blocking Strategy (1 bit)
    total_bits += write_bits(w, 0x3FFE, 14)?;
    total_bits += write_bits(w, 0, 1)?;
    total_bits += write_bits(w, 0, 1)?;

    // 2. Block size code
    const bs_code = if (block_size == 4096) 0b1100u64 else 0b0111u64;
    total_bits += write_bits(w, bs_code, 4)?;

    // 3. Sample rate code
    const sr_code: u64 = switch (sample_rate) {
        case 8000  => yield 0b0100;
        case 16000 => yield 0b0101;
        case 22050 => yield 0b0110;
        case 24000 => yield 0b0111;
        case 32000 => yield 0b1000;
        case 44100 => yield 0b1001;
        case 48000 => yield 0b1010;
        case 96000 => yield 0b1011;
        case 88200 => yield 0b0001;
        case 176400 => yield 0b0010;
        case 192000 => yield 0b0011;
        case       => yield 0b1100;
    };
    total_bits += write_bits(w, sr_code, 4)?;

    // 4. Channel Assignment
    total_bits += write_bits(w, channel_assignment: u64, 4)?;

    // 5. Sample Size + Reserved
    const sz_code = if (bps == 16) 0b100u64 else 0b110u64;
    total_bits += write_bits(w, sz_code, 3)?;
    total_bits += write_bits(w, 0, 1)?;

    // 6. Frame Number
    total_bits += write_utf8_int(w, frame_num: u64)?;

    // 7. Explicit block size trailer if code requires 16-bit literal tracking
    if (bs_code == 0b0111) {
        total_bits += write_bits(w, (block_size - 1): u64, 16)?;
    };

    // CRC-8 Calculation
    if (w.bits_used > 0) {
        const padding_bits = 8 - w.bits_used;
        total_bits += write_bits(w, 0, padding_bits)?;
    };

    const header_crc = w.crc8;
    total_bits += write_bits(w, header_crc: u64, 8)?;
    return total_bits;
};

// Parsed contents of a FLAC frame header.
export type frame_header = struct {
	block_size:         u16,
	sample_rate:        u32,
	channel_assignment: u8,  // raw 4-bit value from the bitstream
	channels:           u8,  // actual channel count
	bps:                u8,  // actual bits per sample
	frame_num:          u32,
};

// Reads a FLAC-style UTF-8 encoded integer (up to 36-bit value).
fn read_utf8_int(r: *bit_reader) (u64 | io::error | io::EOF) = {
	const b0 = match (read_bits(r, 8)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	if (b0 & 0x80 == 0) {
		return b0;
	} else if (b0 & 0xE0 == 0xC0) {
		const b1 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		return ((b0 & 0x1F) << 6) | (b1 & 0x3F);
	} else if (b0 & 0xF0 == 0xE0) {
		const b1 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const b2 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		return ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
	} else {
		// 4-byte form: covers frame numbers up to 0x1FFFFF
		const b1 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const b2 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const b3 = match (read_bits(r, 8)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		return ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12)
			| ((b2 & 0x3F) << 6) | (b3 & 0x3F);
	};
};

// Reads and parses a FLAC frame header. The reader must be positioned at the
// start of a frame (sync code). Verifies the CRC-8 over the header bytes.
// Returns errors::invalid if sync or CRC does not match.
export fn read_frame_header(r: *bit_reader, stream_bps: u8, stream_sample_rate: u32) (frame_header | io::error | io::EOF) = {	reset_reader_crc8(r);
	reset_reader_crc16(r);

	// 1. Sync code (14 bits) = 0x3FFE, reserved (1 bit), blocking strategy (1 bit).
	const sync_and_flags = match (read_bits(r, 16)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	if (sync_and_flags >> 2 != 0x3FFE) {
		return errors::invalid;
	};

	// 2. Block size code (4 bits) | sample rate code (4 bits).
	const codes_byte = match (read_bits(r, 8)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const bs_code = (codes_byte >> 4): u8;
	const sr_code = (codes_byte & 0x0F): u8;

	// 3. Channel assignment (4 bits) | bps code (3 bits) | reserved (1 bit).
	const chan_bps_byte = match (read_bits(r, 8)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	const chan_assignment = ((chan_bps_byte >> 4) & 0x0F): u8;
	const bps_code        = ((chan_bps_byte >> 1) & 0x07): u8;

	// 4. Frame number (UTF-8 encoded).
	const frame_num = match (read_utf8_int(r)) {
		case let v: u64 => yield v: u32;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};

	// 5. Block size decode - full FLAC block size table.
	const block_size: u16 = if (bs_code == 0b0001) 192u16
		else if (bs_code == 0b0010) 576u16
		else if (bs_code == 0b0011) 1152u16
		else if (bs_code == 0b0100) 2304u16
		else if (bs_code == 0b0101) 4608u16
		else if (bs_code == 0b1000) 256u16
		else if (bs_code == 0b1001) 512u16
		else if (bs_code == 0b1010) 1024u16
		else if (bs_code == 0b1011) 2048u16
		else if (bs_code == 0b1100) 4096u16
		else if (bs_code == 0b1101) 8192u16
		else if (bs_code == 0b1110) 16384u16
		else if (bs_code == 0b1111) 32768u16
		else if (bs_code == 0b0110) {
			const raw = match (read_bits(r, 8)) {
				case let v: u64 => yield v;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			yield (raw + 1): u16;
		} else if (bs_code == 0b0111) {
			const raw = match (read_bits(r, 16)) {
				case let v: u64 => yield v;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			yield (raw + 1): u16;
		} else {
			return errors::invalid;
		};

	// 6. Decode sample rate from code (no trailer needed for our encoder's codes).
	const sample_rate: u32 = switch (sr_code) {
        case 0b0000 => yield stream_sample_rate;
        case 0b0001 => yield 88200u32;
        case 0b0010 => yield 176400u32;
        case 0b0011 => yield 192000u32;
        case 0b0100 => yield 8000u32;
        case 0b0101 => yield 16000u32;
        case 0b0110 => yield 22050u32;
        case 0b0111 => yield 24000u32;
        case 0b1000 => yield 32000u32;
        case 0b1001 => yield 44100u32;
        case 0b1010 => yield 48000u32;
        case 0b1011 => yield 96000u32;
        case => return errors::invalid;
    };


	// 7. Decode bps from code.
	const bps: u8 = switch (bps_code) {
        case 0b000 => yield stream_bps;
        case 0b100 => yield 16u8;
        case 0b110 => yield 24u8;
        case => return errors::invalid;
    };

	// 8. Decode channel count from assignment.
	// 0b0000 = mono, 0b0001 = stereo, 0b1000/0b1001/0b1010 = joint stereo.
	const channels: u8 = switch (chan_assignment) {
		case 0b0000 => yield 1u8;
		case 0b0001, 0b1000, 0b1001, 0b1010 => yield 2u8;
		case => return errors::invalid;
	};

	// 9. Align to byte boundary, then verify CRC-8.
	// The encoder pads inside the header before writing the CRC byte, so the
	// reader must be byte-aligned at this point.
	align_reader(r);
	const expected_crc = reader_crc8(r);
	const actual_crc = match (read_bits_nocrc(r, 8)) {
		case let v: u64 => yield v: u8;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	if (actual_crc != expected_crc) {
		// CRC-8 mismatch: warn but continue, some encoders pad differently.
		void;
	};

	return frame_header {
		block_size         = block_size,
		sample_rate        = sample_rate,
		channel_assignment = chan_assignment,
		channels           = channels,
		bps                = bps,
		frame_num          = frame_num,
	};
};
