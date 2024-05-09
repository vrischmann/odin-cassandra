package cql

import "core:fmt"
import "core:testing"
import "core:encoding/endian"

@(test)
test_parse_envelope_too_short :: proc(t: ^testing.T) {
	data := []u8{0xde, 0xad}

	envelope, err := parse_envelope(data[:])
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Envelope_Parse_Error.Envelope_Too_Short)
}

@(test)
test_parse_envelope_error :: proc(t: ^testing.T) {
	data := [dynamic]u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.ERROR),       // opcode
		0x00, 0x00, 0x00, 0x0B, // length placeholder
	}
	defer delete(data)

	envelope_append_string(&data, "foobarbaz")

	envelope, err := parse_envelope(data[:])
	testing.expectf(t, err == nil, "got error: %v", err)

	testing.expect(t, is_request(&envelope.header))
	testing.expect_value(t, envelope.header.version, ProtocolVersion.V5)
	testing.expect_value(t, envelope.header.flags, 2)
	testing.expect_value(t, envelope.header.stream, 1)
	testing.expect_value(t, envelope.header.opcode, Opcode.ERROR)
	testing.expect_value(t, envelope.header.length, 11)
}

@(test)
test_parse_envelope_startup :: proc(t: ^testing.T) {
	data := [dynamic]u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length
	}
	defer delete(data)

	append(&data, "foobarba") // body

	envelope, err := parse_envelope(data[:])
	testing.expectf(t, err == nil, "got error: %v", err)

	testing.expect(t, is_request(&envelope.header))
	testing.expect_value(t, envelope.header.version, ProtocolVersion.V5)
	testing.expect_value(t, envelope.header.flags, 2)
	testing.expect_value(t, envelope.header.stream, 1)
	testing.expect_value(t, envelope.header.opcode, Opcode.STARTUP)
	testing.expect_value(t, envelope.header.length, 8)
}

@(test)
test_parse_envelope_invalid_body :: proc(t: ^testing.T) {
	data := [dynamic]u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length
	}
	defer delete(data)

	append(&data, "foo") // body is too short

	envelope, err := parse_envelope(data[:])
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Envelope_Parse_Error.Invalid_Envelope_Body_Length)
}
