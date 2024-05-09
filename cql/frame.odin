package cql

import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import mathbits "core:math/bits"
import "core:net"
import "core:runtime"

Error :: union #shared_nil {
	runtime.Allocator_Error,
	Envelope_Parse_Error,
	Envelope_Body_Build_Error,
}

UncompressedFrame :: struct {
}

CompressedFrame :: struct {
}

Opcode :: enum {
	ERROR          = 0x00,
	STARTUP        = 0x01,
	READY          = 0x02,
	AUTHENTICATE   = 0x03,
	OPTIONS        = 0x05,
	SUPPORTED      = 0x06,
	QUERY          = 0x07,
	RESULT         = 0x08,
	PREPARE        = 0x09,
	EXECUTE        = 0x0A,
	REGISTER       = 0x0B,
	EVENT          = 0x0C,
	BATCH          = 0x0D,
	AUTH_CHALLENGE = 0x0E,
	AUTH_RESPONSE  = 0x0F,
	AUTH_SUCCESS   = 0x10,
}


ProtocolVersion :: enum {
	V4 = 4,
	V5 = 5,
}

EnvelopeHeader :: struct {
	version: ProtocolVersion,
	flags: u8,
	stream: u16,
	opcode: Opcode,
	length: u32,
}

is_request :: proc(header: ^EnvelopeHeader) -> bool {
	return u8(header.version) & 0x80 == 0
}

is_response :: proc(header: ^EnvelopeHeader) -> bool {
	return u8(header.version) & 0x80 == 0x80
}

EnvelopeBody :: distinct []byte

Envelope :: struct {
	header: EnvelopeHeader,
	body: EnvelopeBody,
}

Envelope_Parse_Error :: enum {
	None = 0,
	Envelope_Too_Short,
	Invalid_Envelope_Body_Length,
}

@(private)
parse_envelope :: proc(data: []byte) -> (Envelope, Error) {
	FRAME_HEADER_SIZE :: 9

	if len(data) <  FRAME_HEADER_SIZE {
		return {}, .Envelope_Too_Short
	}

	hdr: EnvelopeHeader = {}
	hdr.version = ProtocolVersion(data[0])
	hdr.flags = data[1]
	hdr.stream  = endian.get_u16(data[2:4], .Big) or_else 0xAAAA
	hdr.opcode = Opcode(data[4])
	hdr.length = endian.get_u32(data[5:9], .Big) or_else 0xAAAA_AAAA

	remaining := data[9:]

	length := int(hdr.length)
	if length != len(remaining) {
		return {}, .Invalid_Envelope_Body_Length,
	}

	res := Envelope{
		header = hdr,
		body = EnvelopeBody(remaining),
	}

	return res, nil
}

Envelope_Body_Builder :: struct {
}

Envelope_Body_Build_Error :: enum {
	None = 0,
	String_Too_Long,
	Bytes_Too_Long,
}

envelope_body_append_int :: proc(buf: ^[dynamic]u8, n: i32) -> (err: Error) {
	tmp_buf: [4]byte = {}
	endian.put_i32(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

envelope_body_append_long :: proc(buf: ^[dynamic]u8, n: i64) -> (err: Error) {
	tmp_buf: [8]byte = {}
	endian.put_i64(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

envelope_body_append_byte :: proc(buf: ^[dynamic]u8, b: u8) -> (err: Error) {
	append(buf, b) or_return
	return nil
}

envelope_body_append_short :: proc(buf: ^[dynamic]u8, n: u16) -> (err: Error) {
	tmp_buf: [2]byte = {}
	endian.put_u16(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

envelope_body_append_string :: proc(buf: ^[dynamic]u8, str: string) -> (err: Error) {
	if len(str) >= mathbits.U16_MAX {
		return .String_Too_Long
	}

	envelope_body_append_short(buf, u16(len(str))) or_return
	append(buf, str) or_return

	return nil
}

envelope_body_append_long_string :: proc(buf: ^[dynamic]u8, str: string) -> (err: Error) {
	if len(str) >= mathbits.I32_MAX {
		return .String_Too_Long
	}

	envelope_body_append_int(buf, i32(len(str))) or_return
	append(buf, str) or_return

	return nil
}

UUID :: distinct [16]byte

envelope_body_append_uuid :: proc(buf: ^[dynamic]u8, uuid: ^UUID) -> (err: Error) {
	append(buf, ..uuid[:]) or_return
	return nil
}

envelope_body_append_string_list :: proc(buf: ^[dynamic]u8, strings: []string) -> (err: Error) {
	envelope_body_append_short(buf, u16(len(strings))) or_return
	for string in strings {
		envelope_body_append_string(buf, string) or_return
	}
	return nil
}

//
// Bytes stuff
//

envelope_body_append_bytes :: proc(buf: ^[dynamic]u8, bytes: []byte) -> (err: Error) {
	if len(bytes) >= mathbits.I32_MAX {
		return .Bytes_Too_Long
	}

	envelope_body_append_int(buf, i32(len(bytes))) or_return
	append(buf, ..bytes) or_return
	return nil
}

envelope_body_append_null_bytes :: proc(buf: ^[dynamic]u8) -> (err: Error) {
	envelope_body_append_int(buf, i32(-1)) or_return
	return nil
}

envelope_body_append_short_bytes :: proc(buf: ^[dynamic]u8, bytes: []byte) -> (err: Error) {
	if len(bytes) >= mathbits.U16_MAX {
		return .Bytes_Too_Long
	}

	envelope_body_append_short(buf, u16(len(bytes))) or_return
	append(buf, ..bytes) or_return
	return nil
}

//
// Values
//

envelope_body_append_value :: proc(buf: ^[dynamic]u8, value: []byte) -> (err: Error) {
	envelope_body_append_bytes(buf, value) or_return
	return nil
}

envelope_body_append_null_value :: proc(buf: ^[dynamic]u8) -> (err: Error) {
	envelope_body_append_int(buf, -1) or_return
	return nil
}

envelope_body_append_not_set_value :: proc(buf: ^[dynamic]u8) -> (err: Error) {
	envelope_body_append_int(buf, -2) or_return
	return nil
}

// Variable length integer

envelope_body_append_unsigned_vint :: proc(buf: ^[dynamic]byte, n: $N) -> (err: Error)
	where intrinsics.type_is_unsigned(N)
{
	n := n

	tmp_buf: [9]byte = {}
	i := 0

	// split into 7 bits chunks with the most significant bit set when there are more bytes to read.
	//
	// 0x80 == 128 == 0b1000_0000
	// If the number is greater than or equal to that, it must be encoded as a chunk.

	for n >= 0x80 {
		// a chunk is:
		// * the least significant 7 bits
		// * the most significant  bit set to 1
		tmp_buf[i] = byte(n & 0x7F) | 0x80
		n >>= 7
		i += 1
	}

	// the remaining chunk that is less than 128. The most significant bit must not be set.
	tmp_buf[i] = byte(n)

	append(buf, ..tmp_buf[:i+1]) or_return

	return nil
}

envelope_body_append_vint :: proc(buf: ^[dynamic]byte, n: $N) -> (err: Error)
	where type_of(n) == i32 || type_of(n) == i64
{
	when type_of(n) == i32 {
		tmp := u32(n >> 31) ~ u32(n << 1)

		envelope_body_append_unsigned_vint(buf, tmp) or_return
	}

	when type_of(n) == i64 {
		tmp := u64(n >> 63) ~ u64(n << 1)

		envelope_body_append_unsigned_vint(buf, tmp) or_return
	}

	return nil
}

//
// Options
//

// TODO(vincent): implement options

// envelope_body_append_option :: proc(buf: ^[dynamic]byte, id: u16, value: $V) -> (err: Error) {
// 	envelope_body_append_short(buf, id) or_return
// 	return nil
// }

envelope_body_append_inet :: proc(buf: ^[dynamic]byte, address: net.Address, port: $N) -> (err: Error)
	where intrinsics.type_is_integer(N) && size_of(N) <= 8
{
	envelope_body_append_inetaddr(buf, address) or_return
	envelope_body_append_int(buf, i32(port)) or_return

	return nil
}

envelope_body_append_inetaddr :: proc(buf: ^[dynamic]byte, address: net.Address) -> (err: Error) {
	switch v in address {
	case net.IP4_Address:
		addr := v

		append(buf, 4) or_return
		append(buf, ..addr[:]) or_return

	case net.IP6_Address:
		addr := transmute([16]byte) v

		append(buf, 16) or_return
		append(buf, ..addr[:]) or_return
	}

	return nil
}

Consistency :: enum {
	ANY          = 0x0000,
	ONE          = 0x0001,
	TWO          = 0x0002,
	THREE        = 0x0003,
	QUORUM       = 0x0004,
	ALL          = 0x0005,
	LOCAL_QUORUM = 0x0006,
	EACH_QUORUM  = 0x0007,
	SERIAL       = 0x0008,
	LOCAL_SERIAL = 0x0009,
	LOCAL_ONE    = 0x000A,
}

envelope_body_append_consistency :: proc(buf: ^[dynamic]byte, consistency: Consistency) -> (err: Error) {
	envelope_body_append_short(buf, u16(consistency)) or_return
	return nil
}
