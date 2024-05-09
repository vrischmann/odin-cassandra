package cql

import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:testing"

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

	err := envelope_body_append_string(&data, "foobarbaz")
	testing.expectf(t, err == nil, "got error: %v", err)

	//

	envelope, err2 := parse_envelope(data[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect(t, is_request(&envelope.header))
	testing.expect_value(t, envelope.header.version, ProtocolVersion.V5)
	testing.expect_value(t, envelope.header.flags, 2)
	testing.expect_value(t, envelope.header.stream, 1)
	testing.expect_value(t, envelope.header.opcode, Opcode.ERROR)
	testing.expect_value(t, envelope.header.length, 11)
}

@(test)
test_parse_envelope_startup :: proc(t: ^testing.T) {
	data := []u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length

		'f', 'o', 'o', 'b', 'a', 'r', 'b', 'a', // body
	}

	//

	envelope, err := parse_envelope(data)
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
	data := []u8{
		0x05,                   // version
		0x02,                   // flags
		0x00, 0x01,             // stream
		u8(Opcode.STARTUP),     // opcode
		0x00, 0x00, 0x00, 0x08, // length

		'f', 'o', 'o', // body is too short
	}

	envelope, err := parse_envelope(data)
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Envelope_Parse_Error.Invalid_Envelope_Body_Length)
}

@(test)
test_envelope_body :: proc(t: ^testing.T) {
	// [int]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_int(&buf, i32(40))
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{0x00, 0x00, 0x00, 0x28})
	}

	// [long]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_long(&buf, i64(40))
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x00, 0x00, 0x00,
			0x00, 0x00, 0x00, 0x28,
		})
	}

	// [byte]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_byte(&buf, u8(40))
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{0x28})
	}

	// [short]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_short(&buf, u16(40))
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{0x00, 0x28})
	}

	// [string]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_string(&buf, "hello")
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x05,
			'h', 'e', 'l', 'l', 'o',
		})
	}

	// [long string]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_long_string(&buf, "hello")
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x00, 0x00, 0x05,
			'h', 'e', 'l', 'l', 'o',
		})
	}

	// [uuid]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_uuid(&buf, &UUID{
			0xfd, 0xd8, 0x73, 0xbc,
			0x14, 0xb5, 0x46, 0x9b,
			0x94, 0xa0, 0xb8, 0x9b,
			0xe9, 0x94, 0xb3, 0xf9,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0xfd, 0xd8, 0x73, 0xbc,
			0x14, 0xb5, 0x46, 0x9b,
			0x94, 0xa0, 0xb8, 0x9b,
			0xe9, 0x94, 0xb3, 0xf9,
		})
	}

	// [string list]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_string_list(&buf, []string{
			"foo", "bar",
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x02,
			0x00, 0x03, 'f', 'o', 'o',
			0x00, 0x03, 'b', 'a', 'r',
		})
	}

	// [bytes] - with data
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_bytes(&buf, []u8{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x00, 0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [bytes] - null
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_null_bytes(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0xff, 0xff, 0xff, 0xff,
		})
	}

	// [value] - with data
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_value(&buf, []u8{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x00, 0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [value] - null
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_null_value(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0xff, 0xff, 0xff, 0xff,
		})
	}

	// [value] - not set
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_not_set_value(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0xff, 0xff, 0xff, 0xfe,
		})
	}

	// [short bytes]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_short_bytes(&buf, []u8{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_envelope_body(t, buf[:], []u8{
			0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [unsigned vint]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_unsigned_vint(&buf, u64(282240))
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_unsigned_vint(&buf, u32(282240))
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		err3 := envelope_body_append_unsigned_vint(&buf, u16(24450))
		testing.expectf(t, err3 == nil, "got error: %v", err3)

		expect_envelope_body(t, buf[:], []u8{
			0x80, 0x9d, 0x11,
			0x80, 0x9d, 0x11,
			0x82, 0xbf, 0x1,
		})
	}

	// [vint]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_vint(&buf, i64(282240))
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_vint(&buf, i64(-2400))
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		err3 := envelope_body_append_vint(&buf, i32(-38000))
		testing.expectf(t, err3 == nil, "got error: %v", err3)

		err4 := envelope_body_append_vint(&buf, i32(80000000))
		testing.expectf(t, err4 == nil, "got error: %v", err4)

		expect_envelope_body(t, buf[:], []u8{
			0x80, 0xba, 0x22,         // 2822240
			0xbf, 0x25,               // -2400
			0xdf, 0xd1, 0x04,         // -38000
			0x80, 0xd0, 0xa5, 0x4c,   // 80000000
		})
	}

	// [inet]
	{
		buf := [dynamic]u8{}
		defer delete(buf)

		err := envelope_body_append_inet(&buf,
			net.IP4_Address{
				192, 168, 1, 1,
			},
			i32(24000),
		)
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_inet(&buf,
			net.IP6_Address{
				0xfe80, 0x0000, 0x0003, 0x0003,
				0x0002, 0x0002, 0x0001, 0x0001,
			},
			i32(24000),
		)
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		expect_envelope_body(t, buf[:], []u8{
			0x04,                         // address size
			192, 168, 1, 1,               // address bytes
			0x00, 0x00, 0x5d, 0xc0,       // port

			0x10,                         // address size
			0xfe, 0x80, 0x00, 0x00,       // address
			0x00, 0x03, 0x00, 0x03,
			0x00, 0x02, 0x00, 0x02,
			0x00, 0x01, 0x00, 0x01,
			0x00, 0x00, 0x5d, 0xc0,       // port
		})
	}
}

expect_envelope_body :: proc(t: ^testing.T, got: []u8, exp: []u8) {
	if !slice.equal(got, exp) {
		fmt.printf("got: %x\n", got)
		fmt.printf("exp: %x\n", exp)
		testing.errorf(t, "expected %v, got %v", exp, got)
	}
}
