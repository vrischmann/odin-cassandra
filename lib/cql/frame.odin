package cql

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import mathbits "core:math/bits"
import "core:net"

UncompressedFrame :: struct {}

CompressedFrame :: struct {}

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
	flags:   u8,
	stream:  u16,
	opcode:  Opcode,
	length:  u32,
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
	body:   EnvelopeBody,
}

Envelope_Parse_Error :: enum {
	None = 0,
	Envelope_Too_Short,
	Invalid_Message_Length,
}

@(private)
parse_envelope :: proc(data: []byte) -> (Envelope, Error) {
	ENVELOPE_HEADER_SIZE :: 9

	if len(data) < ENVELOPE_HEADER_SIZE {
		return {}, .Envelope_Too_Short
	}

	hdr: EnvelopeHeader = {}

	if data[0] & 0x80 == 0x80 {
		hdr.version = ProtocolVersion(data[0] & ~u8(0x80))
	} else {
		hdr.version = ProtocolVersion(data[0])
	}

	hdr.flags = data[1]
	hdr.stream = endian.get_u16(data[2:4], .Big) or_else 0xAAAA
	hdr.opcode = Opcode(data[4])
	hdr.length = endian.get_u32(data[5:9], .Big) or_else 0xAAAA_AAAA

	remaining := data[9:]

	length := int(hdr.length)
	if length != len(remaining) {
		return {}, .Invalid_Message_Length
	}

	res := Envelope {
		header = hdr,
		body   = EnvelopeBody(remaining),
	}

	return res, nil
}

//
// Specific envelope bodies
//

Envelope_SUPPORTED :: struct {
	options: map[string][]string,
}

envelope_parse_supported :: proc(data: []byte) -> (res: Envelope_SUPPORTED, err: Error) {
	unimplemented("not implemented")
}

//
// Envelope primitives
//

Envelope_Direction :: enum {
	Request,
	Response,
}

@(private)
envelope_append_header_version :: proc(buf: ^[dynamic]byte, version: ProtocolVersion, direction: Envelope_Direction) -> (err: Error) {
	switch direction {
	case .Request:
		append(buf, byte(version)) or_return
	case .Response:
		append(buf, byte(version) | 0x80) or_return
	}

	return nil
}

envelope_append_body :: proc(
	buf: ^[dynamic]byte,
	hdr: EnvelopeHeader,
	body: $B/[]$E/byte,
	direction: Envelope_Direction = .Request,
) -> (
	err: Error,
) {
	// Write the header

	// Note that we reuse some functions for building the envelope body because they work exactly the same here
	envelope_append_header_version(buf, hdr.version, direction) or_return
	append(buf, byte(hdr.flags)) or_return
	message_append_short(buf, hdr.stream) or_return
	append(buf, byte(hdr.opcode)) or_return
	message_append_int(buf, i32(len(body))) or_return

	// Write the body
	append(buf, ..body) or_return

	return nil
}

envelope_append_empty_body :: proc(buf: ^[dynamic]byte, hdr: EnvelopeHeader, direction: Envelope_Direction = .Request) -> (err: Error) {
	// Write the header

	// Note that we reuse some functions for building the envelope body because they work exactly the same here
	envelope_append_header_version(buf, hdr.version, direction) or_return
	append(buf, byte(hdr.flags)) or_return
	message_append_short(buf, hdr.stream) or_return
	append(buf, byte(hdr.opcode)) or_return
	message_append_int(buf, 0) or_return

	return nil
}

envelope_append :: proc {
	envelope_append_body,
	envelope_append_empty_body,
}

//
// Envelope body primitives
//

Message_Append_Error :: enum {
	None = 0,
	String_Too_Long,
	Bytes_Too_Long,
}

Message_Read_Error :: enum {
	None = 0,
	Too_Short,
}

message_append_int :: proc(buf: ^[dynamic]byte, n: i32) -> (err: Error) {
	tmp_buf: [4]byte = {}
	endian.put_i32(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

message_read_int :: proc(buf: []byte) -> (res: i32, new_buf: []byte, err: Error) {
	if len(buf) < 4 {
		err = .Too_Short
		return
	}

	res = endian.get_i32(buf[:], .Big) or_else 0
	new_buf = buf[4:]

	return
}

message_append_long :: proc(buf: ^[dynamic]byte, n: i64) -> (err: Error) {
	tmp_buf: [8]byte = {}
	endian.put_i64(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

@(private)
message_read_long :: proc(buf: []byte) -> (res: i64, new_buf: []byte, err: Error) {
	if len(buf) < 8 {
		err = .Too_Short
		return
	}

	res = endian.get_i64(buf[:], .Big) or_else 0
	new_buf = buf[:8]

	return
}

message_append_byte :: proc(buf: ^[dynamic]byte, b: u8) -> (err: Error) {
	append(buf, b) or_return
	return nil
}

message_read_byte :: proc(buf: []byte) -> (res: u8, new_buf: []byte, err: Error) {
	if len(buf) < 1 {
		err = .Too_Short
		return
	}

	res = buf[0]
	new_buf = buf[1:]

	return
}

message_append_short :: proc(buf: ^[dynamic]byte, n: u16) -> (err: Error) {
	tmp_buf: [2]byte = {}
	endian.put_u16(tmp_buf[:], .Big, n)

	append(buf, ..tmp_buf[:]) or_return

	return nil
}

message_read_short :: proc(buf: []byte) -> (res: u16, new_buf: []byte, err: Error) {
	if len(buf) < 2 {
		err = .Too_Short
		return
	}

	res = endian.get_u16(buf[:], .Big) or_else 0
	new_buf = buf[2:]

	return
}

message_append_string :: proc(buf: ^[dynamic]byte, str: string) -> (err: Error) {
	if len(str) >= mathbits.U16_MAX {
		return .String_Too_Long
	}

	message_append_short(buf, u16(len(str))) or_return
	append(buf, str) or_return

	return nil
}

message_read_string :: proc(buf: []byte) -> (str: string, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_short(buf) or_return

	str = string(tmp_buf[:n])
	new_buf = tmp_buf[n:]

	return
}

message_append_long_string :: proc(buf: ^[dynamic]byte, str: string) -> (err: Error) {
	if len(str) >= mathbits.I32_MAX {
		return .String_Too_Long
	}

	message_append_int(buf, i32(len(str))) or_return
	append(buf, str) or_return

	return nil
}

message_read_long_string :: proc(buf: []byte) -> (str: string, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_int(buf) or_return

	str = string(tmp_buf[:n])
	new_buf = tmp_buf[n:]

	return
}

UUID :: distinct [16]byte

message_append_uuid :: proc(buf: ^[dynamic]byte, uuid: UUID) -> (err: Error) {
	uuid := uuid

	append(buf, ..uuid[:]) or_return
	return nil
}

message_read_uuid :: proc(buf: []byte) -> (res: UUID, new_buf: []byte, err: Error) {
	if len(buf) < size_of(UUID) {
		err = .Too_Short
		return
	}

	copy(res[:], buf[:size_of(UUID)])
	new_buf = buf[:size_of(UUID)]

	return
}

message_append_string_list :: proc(buf: ^[dynamic]byte, strings: []string) -> (err: Error) {
	message_append_short(buf, u16(len(strings))) or_return
	for string in strings {
		message_append_string(buf, string) or_return
	}
	return nil
}

message_read_string_list :: proc(buf: []byte, allocator := context.temp_allocator) -> (res: []string, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_short(buf) or_return

	res = make([]string, n, allocator = allocator)
	for i in 0 ..< n {
		str: string
		str, tmp_buf = message_read_string(tmp_buf) or_return
		res[i] = str
	}

	new_buf = tmp_buf

	return
}

// Bytes stuff

message_append_bytes :: proc(buf: ^[dynamic]byte, bytes: []byte) -> (err: Error) {
	if len(bytes) >= mathbits.I32_MAX {
		return .Bytes_Too_Long
	}

	message_append_int(buf, i32(len(bytes))) or_return
	append(buf, ..bytes) or_return
	return nil
}

message_append_null_bytes :: proc(buf: ^[dynamic]byte) -> (err: Error) {
	message_append_int(buf, i32(-1)) or_return
	return nil
}

message_read_bytes :: proc(buf: []byte) -> (res: []byte, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_int(buf) or_return

	if n == -1 {
		res = nil
		return
	}

	res = tmp_buf[:n]
	new_buf = tmp_buf[n:]

	return
}

message_append_short_bytes :: proc(buf: ^[dynamic]byte, bytes: []byte) -> (err: Error) {
	if len(bytes) >= mathbits.U16_MAX {
		return .Bytes_Too_Long
	}

	message_append_short(buf, u16(len(bytes))) or_return
	append(buf, ..bytes) or_return
	return nil
}

message_read_short_bytes :: proc(buf: []byte) -> (res: []byte, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_short(buf) or_return

	res = tmp_buf[:n]
	new_buf = tmp_buf[n:]

	return
}

// Values

Data_Value :: distinct []byte
Null_Value :: struct {}
Not_Set_Value :: struct {}

Value :: union {
	Data_Value,
	Null_Value,
	Not_Set_Value,
}

message_append_value :: proc(buf: ^[dynamic]byte, value: Value) -> (err: Error) {
	switch v in value {
	case Data_Value:
		message_append_bytes(buf, cast([]byte)v) or_return

	case Null_Value:
		message_append_int(buf, -1) or_return

	case Not_Set_Value:
		message_append_int(buf, -2) or_return
	}

	return nil
}

message_read_value :: proc(buf: []byte) -> (res: Value, new_buf: []byte, err: Error) {
	n, tmp_buf := message_read_int(buf) or_return

	switch n {
	case -1:
		res = Null_Value{}
		new_buf = tmp_buf
	case -2:
		res = Not_Set_Value{}
		new_buf = tmp_buf
	case:
		res = Data_Value(tmp_buf[:n])
		new_buf = tmp_buf[n:]
	}

	return
}

// Variable length integer

message_append_unsigned_vint :: proc(buf: ^[dynamic]byte, n: $N) -> (err: Error) where intrinsics.type_is_unsigned(N) {
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

	append(buf, ..tmp_buf[:i + 1]) or_return

	return nil
}

message_read_unsigned_vint :: proc($T: typeid, buf: []byte) -> (n: T, new_buf: []byte, err: Error) where intrinsics.type_is_unsigned(T) {
	buf := buf

	shift := u64(0)
	count := 0
	for b in buf {
		tmp := T(b) & (~T(0x80))

		n |= (tmp << shift)
		count += 1

		if b & 0x80 == 0 {
			break
		}

		shift += 7
	}

	new_buf = buf[count:]

	return
}

message_append_vint :: proc(buf: ^[dynamic]byte, n: $N) -> (err: Error) where type_of(n) == i32 || type_of(n) == i64 {
	when type_of(n) == i32 {
		tmp := u32(n >> 31) ~ u32(n << 1)

		message_append_unsigned_vint(buf, tmp) or_return
	}

	when type_of(n) == i64 {
		tmp := u64(n >> 63) ~ u64(n << 1)

		message_append_unsigned_vint(buf, tmp) or_return
	}

	return nil
}

// Options
// TODO(vincent): implement options

// message_append_option :: proc(buf: ^[dynamic]byte, id: u16, value: $V) -> (err: Error) {
// 	message_append_short(buf, id) or_return
// 	return nil
// }

// Special types

message_append_inet :: proc(
	buf: ^[dynamic]byte,
	address: net.Address,
	port: $N,
) -> (
	err: Error,
) where intrinsics.type_is_integer(N) &&
	size_of(N) <= 8 {
	message_append_inetaddr(buf, address) or_return
	message_append_int(buf, i32(port)) or_return

	return nil
}

message_append_inetaddr :: proc(buf: ^[dynamic]byte, address: net.Address) -> (err: Error) {
	switch v in address {
	case net.IP4_Address:
		addr := v

		append(buf, 4) or_return
		append(buf, ..addr[:]) or_return

	case net.IP6_Address:
		addr := transmute([16]byte)v

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

message_append_consistency :: proc(buf: ^[dynamic]byte, consistency: Consistency) -> (err: Error) {
	message_append_short(buf, u16(consistency)) or_return
	return nil
}

// Maps

message_append_string_map :: proc(
	buf: ^[dynamic]byte,
	m: $M/map[$K]$V,
) -> (
	err: Error,
) where intrinsics.type_is_string(K) &&
	intrinsics.type_is_string(V) {
	message_append_short(buf, u16(len(m))) or_return
	for key, value in m {
		message_append_string(buf, key) or_return
		message_append_string(buf, cast(string)value) or_return
	}
	return nil
}

message_append_string_multimap :: proc(
	buf: ^[dynamic]byte,
	m: $M/map[$K]$V/[]$E,
) -> (
	err: Error,
) where intrinsics.type_is_string(K) &&
	intrinsics.type_is_slice(V) &&
	intrinsics.type_is_string(E) {
	message_append_short(buf, u16(len(m))) or_return
	for key, list in m {
		message_append_string(buf, key) or_return
		message_append_string_list(buf, cast([]string)list) or_return
	}
	return nil
}

message_append_bytes_map :: proc(
	buf: ^[dynamic]byte,
	m: $M/map[$K]$V/[]byte,
) -> (
	err: Error,
) where intrinsics.type_is_string(K) &&
	intrinsics.type_is_slice(V) {
	message_append_short(buf, u16(len(m))) or_return
	for key, list in m {
		message_append_string(buf, key) or_return
		message_append_bytes(buf, cast([]byte)list) or_return
	}
	return nil
}
