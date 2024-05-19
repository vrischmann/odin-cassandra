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
	data := [dynamic]byte{}
	append(&data, 0x05) // version
	append(&data, 0x02) // flags
	append(&data, 0x00, 0x01) // stream
	append(&data, u8(Opcode.ERROR)) // opcode
	append(&data, 0x00, 0x00, 0x00, 0x0B) // length
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
	data := [dynamic]byte{}
	append(&data, 0x05) // version
	append(&data, 0x02) // flags
	append(&data, 0x00, 0x01) // stream
	append(&data, u8(Opcode.STARTUP)) // opcode
	append(&data, 0x00, 0x00, 0x00, 0x08) // length
	append(&data, 'f', 'o', 'o', 'b', 'a', 'r', 'b', 'a') // body
	defer delete(data)

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
	data := [dynamic]byte{}
	append(&data, 0x05) // version
	append(&data, 0x02) // flags
	append(&data, 0x00, 0x01) // stream
	append(&data, u8(Opcode.STARTUP)) // opcode
	append(&data, 0x00, 0x00, 0x00, 0x08) // length
	append(&data, 'f', 'o', 'o') // body is too short
	defer delete(data)


	envelope, err := parse_envelope(data[:])
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

	expect_equal_slices(t, buf[:], []byte{0x00, 0x07, 0x91, 0x30})

	n, _, err2 := envelope_body_read_int(buf[:])
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

	expect_equal_slices(t, buf[:], []byte{0x00, 0x00, 0x03, 0xb9, 0xa2, 0xa0, 0x56, 0xa9})

	n, _, err2 := envelope_body_read_long(buf[:])
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

	n, _, err2 := envelope_body_read_byte(buf[:])
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
	expect_equal_slices(t, buf[:], []byte{0x9c, 0x40})

	n, _, err2 := envelope_body_read_short(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)
	testing.expect_value(t, n, 40000)
}

@(test)
test_envelope_body_string :: proc(t: ^testing.T) {
	// [string]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x00, 0x05) // string length
	append(&exp_buf, "hello") // string data

	//

	err := envelope_body_append_string(&buf, "hello")
	testing.expectf(t, err == nil, "got error: %v", err)
	expect_equal_slices(t, buf[:], exp_buf[:])

	str, _, err2 := envelope_body_read_string(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)
	testing.expect_value(t, str, "hello")
}

@(test)
test_envelope_body_long_string :: proc(t: ^testing.T) {
	// [long string]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)
	append(&exp_buf, 0x00, 0x00, 0x00, 0x05) // string length
	append(&exp_buf, "hello") // string data

	//

	err := envelope_body_append_long_string(&buf, "hello")
	testing.expectf(t, err == nil, "got error: %v", err)
	expect_equal_slices(t, buf[:], exp_buf[:])

	str, _, err2 := envelope_body_read_long_string(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)
	testing.expect_value(t, str, "hello")
}

@(test)
test_envelope_body_uuid :: proc(t: ^testing.T) {
	// [uuid]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)
	append(&exp_buf, 0xfd, 0xd8, 0x73, 0xbc)
	append(&exp_buf, 0x14, 0xb5, 0x46, 0x9b)
	append(&exp_buf, 0x94, 0xa0, 0xb8, 0x9b)
	append(&exp_buf, 0xe9, 0x94, 0xb3, 0xf9)

	exp_uuid: UUID = {}
	copy(exp_uuid[:], exp_buf[:])

	//

	err := envelope_body_append_uuid(&buf, exp_uuid)
	testing.expectf(t, err == nil, "got error: %v", err)
	expect_equal_slices(t, buf[:], exp_buf[:])

	uuid, _, err2 := envelope_body_read_uuid(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)
	testing.expect_value(t, uuid, exp_uuid)
}

@(test)
test_envelope_body_string_list :: proc(t: ^testing.T) {
	// [string list]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp := []string{"foo", "bar"}

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x00, 0x02) // list length
	append(&exp_buf, 0x00, 0x03) // first element length and data
	append(&exp_buf, "foo")
	append(&exp_buf, 0x00, 0x03) // second element length and data
	append(&exp_buf, "bar")

	//

	err := envelope_body_append_string_list(&buf, exp)
	testing.expectf(t, err == nil, "got error: %v", err)
	expect_equal_slices(t, buf[:], exp_buf[:])

	list, _, err2 := envelope_body_read_string_list(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	expect_equal_slices(t, list, exp)
}

@(test)
test_envelope_body_bytes :: proc(t: ^testing.T) {
	// [bytes] - with data
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		exp := []byte{0xde, 0xad, 0xbe, 0xef}

		exp_buf := [dynamic]byte{}
		defer delete(exp_buf)

		append(&exp_buf, 0x00, 0x00, 0x00, 0x04)
		append(&exp_buf, 0xde, 0xad, 0xbe, 0xef)

		//

		err := envelope_body_append_bytes(&buf, exp)
		testing.expectf(t, err == nil, "got error: %v", err)
		expect_equal_slices(t, buf[:], exp_buf[:])

		bytes, _, err2 := envelope_body_read_bytes(buf[:])
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		expect_equal_slices(t, bytes, exp)
	}

	// [bytes] - null
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		//

		err := envelope_body_append_null_bytes(&buf)
		testing.expectf(t, err == nil, "got error: %v", err)
		expect_equal_slices(t, buf[:], []byte{0xff, 0xff, 0xff, 0xff})

		bytes, _, err2 := envelope_body_read_bytes(buf[:])
		testing.expectf(t, err2 == nil, "got error: %v", err2)
		testing.expect(t, len(bytes) == 0, "bytes not null")
	}
}

@(test)
test_envelope_body_value :: proc(t: ^testing.T) {
	// [value] - with data
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		exp_buf := [dynamic]byte{}
		defer delete(exp_buf)

		append(&exp_buf, 0x00, 0x00, 0x00, 0x04)
		append(&exp_buf, 0xde, 0xad, 0xbe, 0xef)

		err := envelope_body_append_value(&buf, Data_Value([]byte{0xde, 0xad, 0xbe, 0xef}))
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], exp_buf[:])
	}

	// [value] - null
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_value(&buf, Null_Value{})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{0xff, 0xff, 0xff, 0xff})

		value, _, err2 := envelope_body_read_value(buf[:])
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		_, ok := value.(Null_Value)
		testing.expectf(t, ok, "value is %v, should be %v", value, Null_Value{})
	}

	// [value] - not set
	{
		buf := [dynamic]byte{}
		defer delete(buf)

		err := envelope_body_append_value(&buf, Not_Set_Value{})
		testing.expectf(t, err == nil, "got error: %v", err)

		expect_equal_slices(t, buf[:], []byte{0xff, 0xff, 0xff, 0xfe})

		value, _, err2 := envelope_body_read_value(buf[:])
		testing.expectf(t, err2 == nil, "got error: %v", err2)

		_, ok := value.(Not_Set_Value)
		testing.expectf(t, ok, "value is %v, should be %v", value, Not_Set_Value{})
	}
}

@(test)
test_envelope_body_short_bytes :: proc(t: ^testing.T) {
	// [short bytes]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp := []byte{0xde, 0xad, 0xbe, 0xef}

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x00, 0x04)
	append(&exp_buf, 0xde, 0xad, 0xbe, 0xef)

	//

	err := envelope_body_append_short_bytes(&buf, exp)
	testing.expectf(t, err == nil, "got error: %v", err)
	expect_equal_slices(t, buf[:], exp_buf[:])

	bytes, _, err2 := envelope_body_read_short_bytes(buf[:])
	testing.expectf(t, err2 == nil, "got error: %v", err2)
	expect_equal_slices(t, bytes, exp)
}

@(test)
test_envelope_body_unsigned_vint :: proc(t: ^testing.T) {
	// [unsigned vint]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x80, 0x9d, 0x11)
	append(&exp_buf, 0xf6, 0xc5, 0x08)
	append(&exp_buf, 0x82, 0xbf, 0x1)

	//

	err := envelope_body_append_unsigned_vint(&buf, u64(282240))
	testing.expectf(t, err == nil, "got error: %v", err)

	err2 := envelope_body_append_unsigned_vint(&buf, u32(140022))
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	err3 := envelope_body_append_unsigned_vint(&buf, u16(24450))
	testing.expectf(t, err3 == nil, "got error: %v", err3)

	expect_equal_slices(t, buf[:], exp_buf[:])

	n, new_buf, err4 := envelope_body_read_unsigned_vint(buf[:])
	testing.expectf(t, err4 == nil, "got error: %v", err4)
	testing.expect_value(t, n, u64(282240))

	n, new_buf, err4 = envelope_body_read_unsigned_vint(new_buf)
	testing.expectf(t, err4 == nil, "got error: %v", err4)
	testing.expect_value(t, n, u64(140022))

	n, new_buf, err4 = envelope_body_read_unsigned_vint(new_buf)
	testing.expectf(t, err4 == nil, "got error: %v", err4)
	testing.expect_value(t, n, u64(24450))
}

@(test)
test_envelope_body_vint :: proc(t: ^testing.T) {
	// [vint]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x80, 0xba, 0x22) // 2822240
	append(&exp_buf, 0xbf, 0x25) // -2400
	append(&exp_buf, 0xdf, 0xd1, 0x04) // -38000
	append(&exp_buf, 0x80, 0xd0, 0xa5, 0x4c) // 80000000

	//

	err := envelope_body_append_vint(&buf, i64(282240))
	testing.expectf(t, err == nil, "got error: %v", err)

	err2 := envelope_body_append_vint(&buf, i64(-2400))
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	err3 := envelope_body_append_vint(&buf, i32(-38000))
	testing.expectf(t, err3 == nil, "got error: %v", err3)

	err4 := envelope_body_append_vint(&buf, i32(80000000))
	testing.expectf(t, err4 == nil, "got error: %v", err4)

	expect_equal_slices(t, buf[:], exp_buf[:])
}

@(test)
test_envelope_body_inet :: proc(t: ^testing.T) {
	// [inet]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x04) // address size
	append(&exp_buf, 192, 168, 1, 1) // address bytes
	append(&exp_buf, 0x00, 0x00, 0x5d, 0xc0) // port

	append(&exp_buf, 0x10) // address size
	append(&exp_buf, 0xfe, 0x80, 0x00, 0x00) // address
	append(&exp_buf, 0x00, 0x03, 0x00, 0x03)
	append(&exp_buf, 0x00, 0x02, 0x00, 0x02)
	append(&exp_buf, 0x00, 0x01, 0x00, 0x01)
	append(&exp_buf, 0x00, 0x00, 0x5d, 0xc0) // port

	//

	err := envelope_body_append_inet(&buf, net.IP4_Address{192, 168, 1, 1}, i32(24000))
	testing.expectf(t, err == nil, "got error: %v", err)

	err2 := envelope_body_append_inet(&buf, net.IP6_Address{0xfe80, 0x0000, 0x0003, 0x0003, 0x0002, 0x0002, 0x0001, 0x0001}, i32(24000))
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	expect_equal_slices(t, buf[:], exp_buf[:])
}

@(test)
test_envelope_body_inetaddr :: proc(t: ^testing.T) {
	// [inetaddr]

	buf := [dynamic]byte{}
	defer delete(buf)

	exp_buf := [dynamic]byte{}
	defer delete(exp_buf)

	append(&exp_buf, 0x04) // address size
	append(&exp_buf, 192, 168, 1, 1) // address bytes

	append(&exp_buf, 0x10) // address size
	append(&exp_buf, 0xfe, 0x80, 0x00, 0x00) // address
	append(&exp_buf, 0x00, 0x03, 0x00, 0x03)
	append(&exp_buf, 0x00, 0x02, 0x00, 0x02)
	append(&exp_buf, 0x00, 0x01, 0x00, 0x01)

	//

	err := envelope_body_append_inetaddr(&buf, net.IP4_Address{192, 168, 1, 1})
	testing.expectf(t, err == nil, "got error: %v", err)

	err2 := envelope_body_append_inetaddr(&buf, net.IP6_Address{0xfe80, 0x0000, 0x0003, 0x0003, 0x0002, 0x0002, 0x0001, 0x0001})
	testing.expectf(t, err2 == nil, "got error: %v", err2)

	expect_equal_slices(t, buf[:], exp_buf[:])
}

@(test)
test_envelope_body_consistency :: proc(t: ^testing.T) {
	// [consistency]

	buf := [dynamic]byte{}
	defer delete(buf)

	err := envelope_body_append_consistency(&buf, .LOCAL_QUORUM)
	testing.expectf(t, err == nil, "got error: %v", err)

	expect_equal_slices(t, buf[:], []byte{0x00, 0x06})
}

check_map :: proc(t: ^testing.T, got: []byte, exp1: []byte, exp2: []byte, loc := #caller_location) {
	if !slice.equal(got, exp1) && !slice.equal(got, exp2) {
		fmt.printf(" got: %x\n", got)
		fmt.printf("exp1: %x\n", exp1)
		fmt.printf("exp2: %x\n", exp2)
		testing.fail_now(t, loc = loc)
	}
}

test_envelope_body_string_map :: proc(t: ^testing.T) {
	// [string map]

	buf := [dynamic]byte{}
	defer delete(buf)

	m := make(map[string]string)
	defer delete(m)

	m["foo"] = "bar"
	m["name"] = "Vincent"

	err := envelope_body_append_string_map(&buf, m)
	testing.expectf(t, err == nil, "got error: %v", err)

	//

	exp_buf1 := [dynamic]byte{}
	defer delete(exp_buf1)

	append(&exp_buf1, 0x00, 0x02) // map length

	append(&exp_buf1, 0x00, 0x03) // key length
	append(&exp_buf1, "foo") // key data
	append(&exp_buf1, 0x00, 0x03) // value length
	append(&exp_buf1, "bar") // value data

	append(&exp_buf1, 0x00, 0x04) // key length
	append(&exp_buf1, "name") // key data
	append(&exp_buf1, 0x00, 0x07) // value length
	append(&exp_buf1, "Vincent") // value data

	exp_buf2 := [dynamic]byte{}
	defer delete(exp_buf2)

	append(&exp_buf2, 0x00, 0x02) // map length

	append(&exp_buf2, 0x00, 0x04) // key length
	append(&exp_buf2, "name") // key data
	append(&exp_buf2, 0x00, 0x07) // value length
	append(&exp_buf2, "Vincent") // value data

	append(&exp_buf2, 0x00, 0x03) // key length
	append(&exp_buf2, "foo") // key data
	append(&exp_buf2, 0x00, 0x03) // value length
	append(&exp_buf2, "bar") // value data

	check_map(t, buf[:], exp_buf1[:], exp_buf2[:])
}

test_envelope_body_string_multimap :: proc(t: ^testing.T) {
	// [string multimap]

	buf := [dynamic]byte{}
	defer delete(buf)

	m := make(map[string][]string)
	defer delete(m)

	m["foo"] = []string{"he", "lo"}
	m["names"] = []string{"Vince", "Jose"}

	err := envelope_body_append_string_multimap(&buf, m)
	testing.expectf(t, err == nil, "got error: %v", err)
	
	//odinfmt: disable
	exp1 := []byte{
		0x00, 0x02, // map length

		0x00, 0x03,    // key length
		'f', 'o', 'o', // key data
		0x00, 0x02,    // list length
		0x00, 0x02,    // list element 0 length
		'h', 'e',      // list element 0 data
		0x00, 0x02,    // list element 1 length
		'l', 'o',      // list element 1 data

		0x00, 0x05,              // key length
		'n', 'a', 'm', 'e', 's', // key data
		0x00, 0x02,              // list length
		0x00, 0x05,              // list element 0 length
		'V', 'i', 'n', 'c', 'e', // list element 0 data
		0x00, 0x04,              // list element 1 length
		'J', 'o', 's', 'e',      // list element 1 data
	}

	exp2 := []byte{
		0x00, 0x02, // map length

		0x00, 0x05,              // key length
		'n', 'a', 'm', 'e', 's', // key data
		0x00, 0x02,              // list length
		0x00, 0x05,              // list element 0 length
		'V', 'i', 'n', 'c', 'e', // list element 0 data
		0x00, 0x04,              // list element 1 length
		'J', 'o', 's', 'e',      // list element 1 data

		0x00, 0x03,     // key length
		'f', 'o', 'o',  // key data
		0x00, 0x02,     // list length
		0x00, 0x02,     // list element 0 length
		'h', 'e',       // list element 0 data
		0x00, 0x02,     // list element 1 length
		'l', 'o',       // list element 1 data
	}
	//odinfmt: enable

	check_map(t, buf[:], exp1, exp2)
}

test_envelope_body_bytes_map :: proc(t: ^testing.T) {
	// [bytes map]

	buf := [dynamic]byte{}
	defer delete(buf)

	BODY :: distinct []byte

	m := make(map[string]BODY)
	defer delete(m)

	m["foo"] = BODY{0xde, 0xad}
	m["name"] = BODY{0xbe, 0xef}

	err := envelope_body_append_bytes_map(&buf, m)
	testing.expectf(t, err == nil, "got error: %v", err)
	
	//odinfmt: disable
	exp1 := []byte {
		0x00, 0x02, // map length

		0x00, 0x03,             // key length
		'f', 'o', 'o',          // key data
		0x00, 0x04,             // value length
		0xde, 0xad, 0xbe, 0xef, // value data

		0x00, 0x04,         // key length
		'n', 'a', 'm', 'e', // key data
		0x00, 0x04,         // value length
		0xbe, 0xef,         // value data
	}

	exp2 := []byte {
		0x00, 0x02, // map length

		0x00, 0x04,         // key length
		'n', 'a', 'm', 'e', // key data
		0x00, 0x04,         // value length
		0xbe, 0xef,         // value data

		0x00, 0x03,             // key length
		'f', 'o', 'o',          // key data
		0x00, 0x04,             // value length
		0xde, 0xad, 0xbe, 0xef, // value data
	}
	//odinfmt: enable

	check_map(t, buf[:], exp1, exp2)
}

expect_equal_slices :: proc(t: ^testing.T, got, exp: $T/[]$E) {
	if !slice.equal(got, exp) {
		fmt.printf("got: %x\n", got)
		fmt.printf("exp: %x\n", exp)
		testing.errorf(t, "expected %v, got %v", exp, got)
	}
}
