package cql

import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:testing"

@(test)
test_parse_envelope_too_short :: proc(t: ^testing.T) {
	data := []byte{0xde, 0xad}

	envelope, err := parse_envelope(data[:])
	testing.expectf(t, err != nil, "got error: %v", err)
	testing.expect_value(t, err, Envelope_Parse_Error.Envelope_Too_Short)
}

@(test)
test_parse_envelope_error :: proc(t: ^testing.T) {
	data := [dynamic]byte{
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
	data := []byte{
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
	data := []byte{
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
test_envelope_append :: proc(t: ^testing.T) {
	body := [dynamic]byte{}
	defer delete(body)

	{
		options := make(map[string]string)
		defer delete(options)

		options["CQL_VERSION"] = "3.0.0"
		options["DRIVER_NAME"] = "odin-cassandra"

		err := envelope_body_append_string_map(&body, options)
		testing.expectf(t, err == nil, "got error: %v", err)
	}

	startup_header: EnvelopeHeader = {}
	startup_header.version = .V5
	startup_header.flags = 0
	startup_header.stream = 10000
	startup_header.opcode = .STARTUP
	startup_header.length = u32(len(body))

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_append(&buf, startup_header, body[:])
	testing.expectf(t, err == nil, "got error: %v", err)

	fmt.printf("envelope: %x\n", buf[:])
}

@(test)
test_envelope_body_int :: proc(t: ^testing.T) {
	// [int]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_int(&buf, i32(495920))
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{0x00, 0x00, 0x00, 0x28})

	n, err2 := envelope_body_read_int(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect_value(t, n, 495920)
}

@(test)
test_envelope_body_long :: proc(t: ^testing.T) {
	// [long]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_long(&buf, i64(4095832250025))
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{
		0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x28,
	})

	n, err2 := envelope_body_read_long(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect_value(t, n, 4095832250025)
}


@(test)
test_envelope_body_byte :: proc(t: ^testing.T) {
	// [byte]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_byte(&buf, u8(40))
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{0x28})

	n, err2 := envelope_body_read_byte(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect_value(t, n, 40)
}


@(test)
test_envelope_body_short :: proc(t: ^testing.T) {
	// [short]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_short(&buf, u16(40000))
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{0x00, 0x28})

	n, err2 := envelope_body_read_short(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect_value(t, n, 40000)
}

@(test)
test_envelope_body :: proc(t: ^testing.T) {
	// [string]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_string(&buf, "hello")
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{
		0x00, 0x05,
		'h', 'e', 'l', 'l', 'o',
	})

	str, err2 := envelope_body_read_string(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	testing.expect_value(t, str, "hello")
}

@(test)
test_envelope_body :: proc(t: ^testing.T) {


	// [long string]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_long_string(&buf, "hello")
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x00, 0x00, 0x05,
			'h', 'e', 'l', 'l', 'o',
		})
	}

	// [uuid]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_uuid(&buf, UUID{
			0xfd, 0xd8, 0x73, 0xbc,
			0x14, 0xb5, 0x46, 0x9b,
			0x94, 0xa0, 0xb8, 0x9b,
			0xe9, 0x94, 0xb3, 0xf9,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0xfd, 0xd8, 0x73, 0xbc,
			0x14, 0xb5, 0x46, 0x9b,
			0x94, 0xa0, 0xb8, 0x9b,
			0xe9, 0x94, 0xb3, 0xf9,
		})
	}

	// [string list]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_string_list(&buf, []string{
			"foo", "bar",
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x02,
			0x00, 0x03, 'f', 'o', 'o',
			0x00, 0x03, 'b', 'a', 'r',
		})
	}

	// [bytes] - with data
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_bytes(&buf, []byte{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x00, 0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [bytes] - null
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_null_bytes(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0xff, 0xff, 0xff, 0xff,
		})
	}

	// [value] - with data
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_value(&buf, []byte{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x00, 0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [value] - null
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_null_value(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0xff, 0xff, 0xff, 0xff,
		})
	}

	// [value] - not set
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_not_set_value(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0xff, 0xff, 0xff, 0xfe,
		})
	}

	// [short bytes]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_short_bytes(&buf, []byte{
			0xde, 0xad, 0xbe, 0xef,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x04,
			0xde, 0xad, 0xbe, 0xef,
		})
	}

	// [unsigned vint]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_unsigned_vint(&buf, u64(282240))
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_unsigned_vint(&buf, u32(282240))
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		err3 := envelope_body_append_unsigned_vint(&buf, u16(24450))
		testing.expectf(t, err3 == nil, "got error: %v", err3)

		expect_equal_slices(t, buf[:], []byte{
			0x80, 0x9d, 0x11,
			0x80, 0x9d, 0x11,
			0x82, 0xbf, 0x1,
		})
	}

	// [vint]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_vint(&buf, i64(282240))
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_vint(&buf, i64(-2400))
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		err3 := envelope_body_append_vint(&buf, i32(-38000))
		testing.expectf(t, err3 == nil, "got error: %v", err3)

		err4 := envelope_body_append_vint(&buf, i32(80000000))
		testing.expectf(t, err4 == nil, "got error: %v", err4)

		expect_equal_slices(t, buf[:], []byte{
			0x80, 0xba, 0x22,         // 2822240
			0xbf, 0x25,               // -2400
			0xdf, 0xd1, 0x04,         // -38000
			0x80, 0xd0, 0xa5, 0x4c,   // 80000000
		})
	}

	// [inet]
	{
		buf := [dynamic]byte{}
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

		expect_equal_slices(t, buf[:], []byte{
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

	// [inetaddr]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_inetaddr(&buf, net.IP4_Address{
			192, 168, 1, 1,
		})
		testing.expectf(t, err == nil, "got error: %v", err)

		err2 := envelope_body_append_inetaddr(&buf, net.IP6_Address{
			0xfe80, 0x0000, 0x0003, 0x0003,
			0x0002, 0x0002, 0x0001, 0x0001,
		})
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		expect_equal_slices(t, buf[:], []byte{
			0x04,                         // address size
			192, 168, 1, 1,               // address bytes

			0x10,                         // address size
			0xfe, 0x80, 0x00, 0x00,       // address
			0x00, 0x03, 0x00, 0x03,
			0x00, 0x02, 0x00, 0x02,
			0x00, 0x01, 0x00, 0x01,
		})
	}

	// [consistency]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_consistency(&buf, .LOCAL_QUORUM)
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{
			0x00, 0x06,
		})
	}
}

// This test is separate because it requires specific stuff to test maps due to the random iteration order so I'd rather put it in a specific function.
test_envelope_body_maps :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, got: []byte, exp1: []byte, exp2: []byte) {
		if !slice.equal(got, exp1) && !slice.equal(got, exp2) {
			fmt.printf(" got: %x\n", got)
			fmt.printf("exp1: %x\n", exp1)
			fmt.printf("exp2: %x\n", exp2)
			testing.fail_now(t)
		}
	}

	// [string map]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		m := make(map[string]string)
		defer delete(m)

		m["foo"] = "bar"
		m["name"] = "Vincent"

		err := envelope_body_append_string_map(&buf, m)
		testing.expectf(t, err == nil, "got error: %v", err)

		exp1 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x03,    // key length
			'f', 'o', 'o', // key data
			0x00, 0x03,    // value length
			'b', 'a', 'r', // value data

			0x00, 0x04,                         // key length
			'n', 'a', 'm', 'e',                 // key data
			0x00, 0x07,                         // value length
			'V', 'i', 'n', 'c', 'e', 'n', 't',  // value data
		}

		exp2 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x04,                         // key length
			'n', 'a', 'm', 'e',                 // key data
			0x00, 0x07,                         // value length
			'V', 'i', 'n', 'c', 'e', 'n', 't',  // value data

			0x00, 0x03,    // key length
			'f', 'o', 'o', // key data
			0x00, 0x03,    // value length
			'b', 'a', 'r', // value data
		}

		check(t, buf[:], exp1, exp2)
	}

	// [string multimap]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		m := make(map[string][]string)
		defer delete(m)

		m["foo"] = []string{"he", "lo"}
		m["names"] = []string{"Vince", "Jose"}

		err := envelope_body_append_string_multimap(&buf, m)
		testing.expectf(t, err == nil, "got error: %v", err)

		exp1 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x03,    // key length
			'f', 'o', 'o', // key data
			0x00, 0x02,    // list length
			0x00, 0x02,    // list element 0 length
			'h', 'e',      // list element 0 data
			0x00, 0x02,    // list element 1 length
			'l', 'o',      // list element 1 data

			0x00, 0x05,               // key length
			'n', 'a', 'm', 'e', 's',  // key data
			0x00, 0x02,               // list length
			0x00, 0x05,               // list element 0 length
			'V', 'i', 'n', 'c', 'e',  // list element 0 data
			0x00, 0x04,               // list element 1 length
			'J', 'o', 's', 'e',       // list element 1 data
		}

		exp2 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x05,               // key length
			'n', 'a', 'm', 'e', 's',  // key data
			0x00, 0x02,               // list length
			0x00, 0x05,               // list element 0 length
			'V', 'i', 'n', 'c', 'e',  // list element 0 data
			0x00, 0x04,               // list element 1 length
			'J', 'o', 's', 'e',       // list element 1 data

			0x00, 0x03,    // key length
			'f', 'o', 'o', // key data
			0x00, 0x02,    // list length
			0x00, 0x02,    // list element 0 length
			'h', 'e',      // list element 0 data
			0x00, 0x02,    // list element 1 length
			'l', 'o',      // list element 1 data

		}

		check(t, buf[:], exp1, exp2)
	}

	// [bytes map]
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		BODY :: distinct []byte

		m := make(map[string]BODY)
		defer delete(m)

		m["foo"] = BODY{0xde, 0xad}
		m["name"] = BODY{0xbe, 0xef}

		err := envelope_body_append_bytes_map(&buf, m)
		testing.expectf(t, err == nil, "got error: %v", err)

		exp1 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x03,             // key length
			'f', 'o', 'o',          // key data
			0x00, 0x04,             // value length
			0xde, 0xad, 0xbe, 0xef, // value data

			0x00, 0x04,             // key length
			'n', 'a', 'm', 'e',     // key data
			0x00, 0x04,             // value length
			0xbe, 0xef,             // value data
		}

		exp2 := []byte{
			0x00, 0x02,    // map length

			0x00, 0x04,             // key length
			'n', 'a', 'm', 'e',     // key data
			0x00, 0x04,             // value length
			0xbe, 0xef,             // value data

			0x00, 0x03,             // key length
			'f', 'o', 'o',          // key data
			0x00, 0x04,             // value length
			0xde, 0xad, 0xbe, 0xef, // value data
		}

		check(t, buf[:], exp1, exp2)
	}
}

expect_equal_slices :: proc(t: ^testing.T, got, exp: $T/[]$E) {
	if !slice.equal(got, exp) {
		fmt.printf("got: %x\n", got)
		fmt.printf("exp: %x\n", exp)
		testing.errorf(t, "expected %v, got %v", exp, got)
	}
}
