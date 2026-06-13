use errors;
use io;
use wav;

// Writes the mandatory "fLaC" marker and the STREAMINFO block.
export fn write_stream_header(w: *bit_writer, dec: *wav::decoder) (size | io::error) = {
    let total_bits = 0z;

    // 1. "fLaC" Magic Number (32 bits)
    // Encodes the ASCII string "fLaC".
    total_bits += write_bits(w, 0x664C6143, 32)?;

    // 2. Metadata Block Header
    // Last-block flag (1 bit) | Block type (7 bits, 0 = STREAMINFO) | Length (24 bits)
    total_bits += write_bits(w, 0, 1)?; // Not last — seektable follows
    total_bits += write_bits(w, 0, 7)?; // Type 0 is STREAMINFO
    total_bits += write_bits(w, 34, 24)?; // STREAMINFO payload is always 34 bytes

    // 3. STREAMINFO Payload
    // Min/Max Block Size (16 bits each)
    total_bits += write_bits(w, 4096, 16)?;
    total_bits += write_bits(w, 4096, 16)?;

    // Min/Max Frame Size (24 bits each) - 0 indicates unknown
    total_bits += write_bits(w, 0, 24)?;
    total_bits += write_bits(w, 0, 24)?;

    // Sample rate (20 bits)
    total_bits += write_bits(w, dec.meta.rate: u64, 20)?;

    // Channels (3 bits, value is channels-1)
    total_bits += write_bits(w, (dec.meta.channels - 1): u64, 3)?;

    // Bits per sample (5 bits, value is bps-1)
    total_bits += write_bits(w, (dec.meta.bit_depth - 1): u64, 5)?;

    // 4. Total samples (36 bits)
    const bytes_per_sample = (dec.meta.bit_depth / 8): u32;
    const total_samples = dec.data_size / (dec.meta.channels: u32 * bytes_per_sample);
    total_bits += write_bits(w, total_samples: u64, 36)?;

    // 5. MD5 signature (128 bits) - Placeholder zeros
    total_bits += write_bits(w, 0, 64)?;
    total_bits += write_bits(w, 0, 64)?;

    return total_bits;
};

// Writes a zeroed seektable metadata block as a placeholder.
// Each seekpoint is 18 bytes: sample_number(8) + offset(8) + frame_samples(2).
// This must be called immediately after write_stream_header.
// Returns the byte offset of the seektable payload start in the output,
// so the caller can seek back and overwrite it after encoding.
export fn write_seektable_placeholder(
	w:        *bit_writer,
	fd:       io::file,
	n_entries: u32,
) (u64 | io::error) = {
	// Flush any buffered bits first so our io::seek position is accurate.
	flush(w)?;

	// Metadata block header: last-block(1) | type=3(7) | length(24)
	const payload_bytes = n_entries: u64 * 18;
	write_bits(w, 1, 1)?;                    // last metadata block
	write_bits(w, 3, 7)?;                    // type 3 = SEEKTABLE
	write_bits(w, payload_bytes, 24)?;
	flush(w)?;

	// Record payload start position.
	const payload_offset = io::seek(fd, 0, io::whence::CUR)!: u64;

	// Write zeroed seekpoints.
	for (let i = 0u32; i < n_entries; i += 1) {
		write_bits(w, 0, 64)?; // sample_number placeholder
		write_bits(w, 0, 64)?; // byte_offset placeholder
		write_bits(w, 0, 16)?; // frame_samples placeholder
		flush(w)?;
	};

	return payload_offset;
};

export type seekpoint = struct {
	sample_number: u64,
	byte_offset:   u64,
	frame_samples: u16,
};

// Seeks back to the seektable payload and overwrites it with real data.
export fn write_seektable(
	fd:            io::file,
	payload_offset: u64,
	entries:        []seekpoint,
) (void | io::error) = {
	io::seek(fd, payload_offset: i64, io::whence::SET)?;

	let buf: [18]u8 = [0...];
	for (let i = 0z; i < len(entries); i += 1) {
		const e = entries[i];
		// Big-endian per FLAC spec.
		buf[0] = ((e.sample_number >> 56) & 0xFF): u8;
		buf[1] = ((e.sample_number >> 48) & 0xFF): u8;
		buf[2] = ((e.sample_number >> 40) & 0xFF): u8;
		buf[3] = ((e.sample_number >> 32) & 0xFF): u8;
		buf[4] = ((e.sample_number >> 24) & 0xFF): u8;
		buf[5] = ((e.sample_number >> 16) & 0xFF): u8;
		buf[6] = ((e.sample_number >>  8) & 0xFF): u8;
		buf[7] = ( e.sample_number        & 0xFF): u8;
		buf[8]  = ((e.byte_offset >> 56) & 0xFF): u8;
		buf[9]  = ((e.byte_offset >> 48) & 0xFF): u8;
		buf[10] = ((e.byte_offset >> 40) & 0xFF): u8;
		buf[11] = ((e.byte_offset >> 32) & 0xFF): u8;
		buf[12] = ((e.byte_offset >> 24) & 0xFF): u8;
		buf[13] = ((e.byte_offset >> 16) & 0xFF): u8;
		buf[14] = ((e.byte_offset >>  8) & 0xFF): u8;
		buf[15] = ( e.byte_offset        & 0xFF): u8;
		buf[16] = ((e.frame_samples >> 8) & 0xFF): u8;
		buf[17] = ( e.frame_samples       & 0xFF): u8;
		io::writeall(fd, buf)?;
	};

	// Seek back to end of file so subsequent writes continue correctly.
	io::seek(fd, 0, io::whence::END)?;
};

// Parsed contents of a FLAC STREAMINFO block.
export type streaminfo = struct {
	min_block_size: u16,
	max_block_size: u16,
	min_frame_size: u32,
	max_frame_size: u32,
	sample_rate:    u32,
	channels:       u8,   // actual channel count (1-based)
	bps:            u8,   // actual bits per sample (1-based)
	total_samples:  u64,
	// Seektable entries, if present. Empty slice if no SEEKTABLE block found.
	// Caller must free this slice.
	seektable: []seekpoint,
	// Byte offset of the first audio frame in the file.
	audio_start: u64,
};

// Reads a SEEKTABLE block payload into a newly allocated []seekpoint.
fn read_seektable_payload(
	r: *bit_reader,
	length: u64,
) ([]seekpoint | io::error | io::EOF) = {
	const n_entries = length / 18;
	let entries: []seekpoint = alloc(
		[seekpoint { sample_number = 0, byte_offset = 0, frame_samples = 0 }...],
		n_entries: size) as []seekpoint;
	for (let i = 0z; i < n_entries: size; i += 1) {
		const sn = match (read_bits(r, 32)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const sn_lo = match (read_bits(r, 32)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const bo = match (read_bits(r, 32)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const bo_lo = match (read_bits(r, 32)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const fs = match (read_bits(r, 16)) {
			case let v: u64 => yield v: u16;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		entries[i] = seekpoint {
			sample_number = (sn << 32) | sn_lo,
			byte_offset   = (bo << 32) | bo_lo,
			frame_samples = fs,
		};
	};
	return entries;
};

// Reads and verifies the "fLaC" stream marker, then parses metadata blocks
// until the STREAMINFO block is found. Returns the parsed streaminfo.
// Returns io::error or io::EOF on a malformed or truncated stream.
export fn read_streaminfo(r: *bit_reader) (streaminfo | io::error | io::EOF) = {
	// Verify "fLaC" magic (32 bits).
	const magic = match (read_bits(r, 32)) {
		case let v: u64 => yield v;
		case let e: io::error => return e;
		case io::EOF => return io::EOF;
	};
	if (magic != 0x664C6143) {
		return errors::invalid;
	};

	// Walk metadata blocks until STREAMINFO (type 0) is found.
	// Track byte position: 4 bytes for "fLaC" magic already consumed.
	let audio_pos: u64 = 4;
	let pre_seektable: []seekpoint = [];
	for (true) {
		// Metadata block header: last-block (1) | type (7) | length (24)
		const header = match (read_bits(r, 32)) {
			case let v: u64 => yield v;
			case let e: io::error => return e;
			case io::EOF => return io::EOF;
		};
		const is_last   = (header >> 31) & 1;
		const block_type = (header >> 24) & 0x7F;
		const length    = header & 0xFFFFFF;
		audio_pos += 4 + length; // 4-byte block header + payload

		if (block_type == 0) {
			// STREAMINFO — parse it.
			const min_block_size = match (read_bits(r, 16)) {
				case let v: u64 => yield v: u16;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const max_block_size = match (read_bits(r, 16)) {
				case let v: u64 => yield v: u16;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const min_frame_size = match (read_bits(r, 24)) {
				case let v: u64 => yield v: u32;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const max_frame_size = match (read_bits(r, 24)) {
				case let v: u64 => yield v: u32;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const sample_rate = match (read_bits(r, 20)) {
				case let v: u64 => yield v: u32;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const channels_raw = match (read_bits(r, 3)) {
				case let v: u64 => yield v: u8;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const bps_raw = match (read_bits(r, 5)) {
				case let v: u64 => yield v: u8;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			const total_samples = match (read_bits(r, 36)) {
				case let v: u64 => yield v;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
			// MD5 signature: 128 bits — read and discard.
			for (let i = 0; i < 4; i += 1) {
				match (read_bits(r, 32)) {
					case u64 => void;
					case let e: io::error => return e;
					case io::EOF => return io::EOF;
				};
			};
			// Walk remaining metadata blocks, capturing SEEKTABLE if present.
			let last = is_last;
			let seektable: []seekpoint = [];
			for (last == 0) {
				const h = match (read_bits(r, 32)) {
					case let v: u64 => yield v;
					case let e: io::error => return e;
					case io::EOF => return io::EOF;
				};
				last = (h >> 31) & 1;
				const blk_type = (h >> 24) & 0x7F;
				const blk_len  = h & 0xFFFFFF;
				audio_pos += 4 + blk_len;
				if (blk_type == 3) {
					seektable = match (read_seektable_payload(r, blk_len)) {
						case let s: []seekpoint => yield s;
						case let e: io::error => return e;
						case io::EOF => return io::EOF;
					};
				} else {
					for (let i = 0u64; i < blk_len; i += 1) {
						match (read_bits(r, 8)) {
							case u64 => void;
							case let e: io::error => return e;
							case io::EOF => return io::EOF;
						};
					};
				};
			};
			return streaminfo {
				min_block_size = min_block_size,
				max_block_size = max_block_size,
				min_frame_size = min_frame_size,
				max_frame_size = max_frame_size,
				sample_rate    = sample_rate,
				channels       = channels_raw + 1,
				bps            = bps_raw + 1,
				total_samples  = total_samples,
				seektable      = if (len(seektable) > 0) seektable
					else pre_seektable,
				audio_start    = audio_pos,
			};
		} else if (block_type == 3) {
			// SEEKTABLE before STREAMINFO — unusual but valid, parse and keep.
			pre_seektable = match (read_seektable_payload(r, length)) {
				case let s: []seekpoint => yield s;
				case let e: io::error => return e;
				case io::EOF => return io::EOF;
			};
		} else {
			// Skip this block's payload by reading bytes.
			for (let i = 0u64; i < length; i += 1) {
				match (read_bits(r, 8)) {
					case u64 => void;
					case let e: io::error => return e;
					case io::EOF => return io::EOF;
				};
			};
		};

		if (is_last == 1 && block_type != 0) {
			// Last block and still no STREAMINFO — malformed.
			return errors::invalid;
		};
	};
};
