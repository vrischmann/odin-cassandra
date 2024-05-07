package cql

import "core:fmt"
import "core:testing"

@(test)
test_parse_frame_frame_too_short :: proc(t: ^testing.T) {
	data := []u8{0xde, 0xad}

	frame, err := parse_frame(data[:])
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Error.Frame_Too_Short)
}

@(test)
test_parse_frame_valid_frame :: proc(t: ^testing.T) {
	data := [dynamic]u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length
	}
	append(&data, "foobarba")

	frame, err := parse_frame(data[:])
	testing.expectf(t, err == nil, "got error: %v", err)

	testing.expect_value(t, frame.header.version, ProtocolVersion.V5)
	testing.expect_value(t, frame.header.flags, 2)
	testing.expect_value(t, frame.header.stream, 1)
	testing.expect_value(t, frame.header.opcode, Opcode.STARTUP)
	testing.expect_value(t, frame.header.length, 8)
}

@(test)
test_parse_frame_invalid_payload :: proc(t: ^testing.T) {
	data := [dynamic]u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length
	}
	append(&data, "foo") // payload is too short

	frame, err := parse_frame(data[:])
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Error.Invalid_Frame_Payload_Length)
}
