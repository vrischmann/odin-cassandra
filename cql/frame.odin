package cql

import "core:encoding/endian"
import "core:fmt"

Error :: enum {
	None = 0,
	Frame_Too_Short,
	Invalid_Frame_Payload_Length,
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

FrameHeader :: struct {
	version: ProtocolVersion,
	flags: u8,
	stream: u16,
	opcode: Opcode,
	length: u32,
}

is_request_frame :: proc(header: ^FrameHeader) -> bool {
	return u8(header.version) & 0x80 == 0
}

is_response_frame :: proc(header: ^FrameHeader) -> bool {
	return u8(header.version) & 0x80 == 0x80
}

FramePayload :: distinct []u8

Frame :: struct {
	header: FrameHeader,
	payload: FramePayload,
}

parse_frame :: proc(data: []u8) -> (Frame, Error) {
	FRAME_HEADER_SIZE :: 9

	if len(data) <  FRAME_HEADER_SIZE {
		return {}, .Frame_Too_Short
	}

	hdr: FrameHeader = {}
	hdr.version = ProtocolVersion(data[0])
	hdr.flags = data[1]
	hdr.stream  = endian.get_u16(data[2:4], .Big) or_else 0xAAAA
	hdr.opcode = Opcode(data[4])
	hdr.length = endian.get_u32(data[5:9], .Big) or_else 0xAAAA_AAAA

	remaining := data[9:]

	length := int(hdr.length)
	if length != len(remaining) {
		return {}, .Invalid_Frame_Payload_Length,
	}

	res := Frame{
		header = hdr,
		payload = FramePayload(remaining),
	}

	return res, nil
}
