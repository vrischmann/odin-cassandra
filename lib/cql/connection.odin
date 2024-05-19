package cql

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:log"
import "core:net"
import "core:os"
import "core:time"

import "cassandra:mio"

Connection_Id :: distinct int

Connection_Stage :: enum {
	Invalid = 0,
	Create_Socket,
	Connect_To_Endpoint,
	Write_Frame,
	Read_Frame,
	Graceful_Shutdown,
}

Handshake_Stage :: enum {
	Invalid = 0,
	Write_STARTUP,
	Write_AUTH_RESPONSE,
	Write_OPTIONS,
	Read_SUPPORTED,
	Read_READY,
	Read_AUTHENTICATE,
	Read_AUTH_CHALLENGE,
	Read_AUTH_SUCCESS,
	Done,
}

Connection :: struct {
	// These fields are mandatory and must be provided by the caller either in [connection_init]
	ring:                     ^mio.ring,
	id:                       Connection_Id,
	endpoint:                 net.Endpoint,

	// These fields are optional but can be set by the caller
	connect_timeout:          time.Duration,
	read_timeout:             time.Duration,
	write_timeout:            time.Duration,

	// These fields are created and managed by the connection itself
	connection_attempt_start: time.Time,

	// Set to true when the connection has closed its socket
	// TODO(vincent): maybe don't do this ?
	closed:                   bool,

	// Low level stuff used to drive io_uring
	socket:                   os.Socket,
	sockaddr:                 os.SOCKADDR,
	timeout:                  mio.kernel_timespec,
	stage:                    Connection_Stage,
	buf:                      [dynamic]u8,

	// TODO(vincent): handle multiple streams
	stream:                   u16,

	// Protocol negotiation
	handshake_stage:          Handshake_Stage,
}

connection_init :: proc(conn: ^Connection, ring: ^mio.ring, id: Connection_Id, endpoint: net.Endpoint) -> (err: Error) {
	// Set provided fields
	conn.ring = ring
	conn.id = id
	conn.endpoint = endpoint

	// Set default values
	conn.connect_timeout = 1 * time.Second
	conn.read_timeout = 1 * time.Second
	conn.write_timeout = 1 * time.Second

	// Initialize state
	conn.buf = {}
	// TODO(vincent): handle multiple streams
	conn.stream = 10000

	reserve(&conn.buf, 4096) or_return
	resize(&conn.buf, 0) or_return

	// Prep the state machine and begin the work
	conn.stage = .Create_Socket

	domain: int = 0
	switch _ in endpoint.address {
	case net.IP4_Address:
		domain = os.AF_INET
	case net.IP6_Address:
		domain = os.AF_INET6
	}

	sqe := mio.ring_socket(conn.ring, domain, os.SOCK_STREAM, 0, 0)
	sqe.user_data = u64(uintptr(conn))

	return nil
}

connection_destroy :: proc(conn: ^Connection) {
	delete(conn.buf)
}

connection_graceful_shutdown :: proc(conn: ^Connection) -> (err: Error) {
	log.info("prepping graceful shutdown")

	conn.stage = .Graceful_Shutdown

	cancel_sqe := mio.ring_cancel_fd(conn.ring, os.Handle(conn.socket))
	cancel_sqe.user_data = 100
	cancel_sqe.flags |= mio.IOSQE_IO_HARDLINK

	shutdown_sqe := mio.ring_shutdown(conn.ring, conn.socket)
	shutdown_sqe.user_data = 100
	shutdown_sqe.flags |= mio.IOSQE_IO_HARDLINK

	close_sqe := mio.ring_close(conn.ring, os.Handle(conn.socket))
	close_sqe.user_data = u64(uintptr(conn))

	return nil
}

Processing_Result :: enum {
	Invalid = 0,
	Socket_Created,
	Connection_Established,
	Frame_Written,
	Frame_Read,
	Shutdown,
}

@(private)
Process_Error :: enum {
	None = 0,
	Invalid_Connection_Stage,
	Invalid_Handshake_Stage,
	Invalid_Response,
}

process_cqe :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> (res: Processing_Result, err: Error) {
	// TODO(vincent): add a more high-level "handshake" stage ?
	// TODO(vincent): also can we only return a subset of interesting processing results ?

	#partial switch conn.stage {
	case .Create_Socket:
		handle_create_socket(conn, cqe) or_return
		return .Socket_Created, nil
	case .Connect_To_Endpoint:
		handle_connect_to_endpoint(conn, cqe) or_return
		return .Connection_Established, nil
	case .Write_Frame:
		handle_write_frame(conn, cqe) or_return
		return .Frame_Written, nil
	case .Read_Frame:
		handle_read_frame(conn, cqe) or_return
		return .Frame_Read, nil
	case .Graceful_Shutdown:
		handle_graceful_shutdown(conn, cqe) or_return
		return .Shutdown, nil
	case:
		log.errorf("stage is %q", conn.stage)
		return .Invalid, .Invalid_Connection_Stage
	}
}

@(private)
handle_create_socket :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Error {
	log.infof("%v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}


	// We got a socket, connect to it

	conn.socket = os.Socket(cqe.res)
	conn.stage = .Connect_To_Endpoint

	// Prepare the SOCKADDR
	switch a in conn.endpoint.address {
	case net.IP4_Address:
		(^os.sockaddr_in)(&conn.sockaddr)^ = os.sockaddr_in {
			sin_family = u16(os.AF_INET),
			sin_port   = u16be(conn.endpoint.port),
			sin_addr   = transmute(os.in_addr)a,
			sin_zero   = {},
		}
	case net.IP6_Address:
		(^os.sockaddr_in6)(&conn.sockaddr)^ = os.sockaddr_in6 {
			sin6_family   = u16(os.AF_INET6),
			sin6_port     = u16be(conn.endpoint.port),
			sin6_flowinfo = 0,
			sin6_addr     = transmute(os.in6_addr)a,
			sin6_scope_id = 0,
		}
	}

	conn.connection_attempt_start = time.now()
	prep_connect_with_timeout(conn, conn.connect_timeout)

	return nil
}

@(private)
handle_connect_to_endpoint :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Error {
	log.infof("%v", cqe)

	if cqe.res != 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Connection is established, now start the handshake with the server
	conn.handshake_stage = .Write_OPTIONS
	clear(&conn.buf)
	write_OPTIONS_message(conn) or_return

	conn.stage = .Write_Frame
	prep_write_with_timeout(conn, conn.write_timeout)

	return nil
}

@(private)
handle_write_frame :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Error {
	log.infof("%v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	//
	// TODO(vincent): handle this better, trigger another write
	{
		n := int(cqe.res)
		switch {
		case n < len(conn.buf):
			return .Short_Write
		case n > len(conn.buf):
			return .Invalid_Write
		}
	}

	//

	conn.stage = .Read_Frame

	clear(&conn.buf)
	resize(&conn.buf, cap(conn.buf))

	log.infof("prep reading from socket fd=%d into buffer len=%v", conn.socket, len(conn.buf))

	sqe := mio.ring_read(conn.ring, os.Handle(conn.socket), conn.buf[:], 0)
	sqe.user_data = u64(uintptr(conn))

	return nil
}

@(private)
handle_read_frame :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> (err: Error) {
	log.infof("%v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	n := int(cqe.res)
	if n > len(conn.buf) {
		return .Short_Buffer
	}

	//

	read_data := conn.buf[0:n]
	log.infof("read data: %q", string(read_data))

	#partial switch conn.handshake_stage {
	case .Done:
		unimplemented("framing not implemented yet")
	case:
		handle_read_in_handshake(conn, read_data) or_return
	}

	clear(&conn.buf)

	return nil
}
//
// @(private)
// process_cqe_timeout :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
// 	log.infof("[STAGE: timeout]: %+v", cqe)
//
// 	if cqe.res < 0 {
// 		err := mio.os_err_from_errno(-cqe.res)
// 		if err != nil && err != .Timer_Expired {
// 			return err
// 		}
// 	}
//
// 	conn.op = .Write
//
// 	resize(&conn.buf, cap(conn.buf))
//
// 	data := fmt.bprintf(conn.buf[:], "writing, completion count: %d", conn.completion_count)
//
// 	resize(&conn.buf, len(data))
//
// 	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.socket, len(data), data)
//
// 	sqe := mio.ring_write(conn.ring, os.Handle(conn.socket), conn.buf[:], 0)
// 	sqe.user_data = u64(uintptr(conn))
//
// 	return nil
// }

@(private)
handle_graceful_shutdown :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Error {
	log.infof("%v", cqe)

	if cqe.res == 0 {
		log.infof("socket %v has been closed", conn.socket)
		conn.closed = true
	} else {
		err := mio.os_err_from_errno(-cqe.res)
		log.warnf("unable to close socket %v, err: %v", conn.socket, err)
	}

	return nil
}

@(private)
handle_write_options :: proc(conn: ^Connection, envelope: Envelope) -> (err: Error) {
	if envelope.header.opcode != Opcode.SUPPORTED {
		log.errorf("expected a SUPPORTED message, got %v", envelope.header.opcode)
		return .Invalid_Response
	}

	msg, _ := read_SUPPORTED_message(envelope.body) or_return

	fmt.printfln("supported: %v", msg)

	return nil
}

@(private)
handle_read_in_handshake :: proc(conn: ^Connection, data: []byte) -> (err: Error) {
	envelope := parse_envelope(data) or_return


	#partial switch conn.handshake_stage {
	case .Write_OPTIONS:
		handle_write_options(conn, envelope) or_return
	case .Write_STARTUP:
		unimplemented("Write_STARTUP")

	case .Write_AUTH_RESPONSE:
		unimplemented("Write_AUTH_RESPONSE")

	case:
		log.errorf("invalid stage %v while reading data", conn.handshake_stage)
		return .Invalid_Handshake_Stage
	}

	return nil
}


@(private)
prep_connect_with_timeout :: proc(conn: ^Connection, timeout: time.Duration) {
	log.infof("socket: %v, sockaddr: %v", conn.socket, conn.sockaddr)

	sqe := mio.ring_connect(conn.ring, conn.socket, &conn.sockaddr)
	sqe.flags |= mio.IOSQE_IO_LINK
	sqe.user_data = u64(uintptr(conn))

	conn.timeout = {}
	conn.timeout.tv_nsec = i64(1 * time.Second)

	timeout_sqe := mio.ring_link_timeout(conn.ring, &conn.timeout)
	timeout_sqe.user_data = 20

}

@(private)
prep_write_with_timeout :: proc(conn: ^Connection, timeout: time.Duration) {
	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.socket, len(conn.buf), conn.buf)

	sqe := mio.ring_write(conn.ring, os.Handle(conn.socket), conn.buf[:], 0)
	sqe.flags |= mio.IOSQE_IO_LINK
	sqe.user_data = u64(uintptr(conn))

	conn.timeout = {}
	conn.timeout.tv_nsec = i64(timeout)

	timeout_sqe := mio.ring_link_timeout(conn.ring, &conn.timeout)
	timeout_sqe.user_data = 20
}

@(private)
write_OPTIONS_message :: proc(conn: ^Connection) -> (err: Error) {
	options_hdr: EnvelopeHeader = {}
	options_hdr.version = .V5
	options_hdr.flags = 0
	options_hdr.stream = conn.stream
	options_hdr.opcode = .OPTIONS
	options_hdr.length = 0

	envelope_append(&conn.buf, options_hdr, nil) or_return

	return nil
}

@(private)
SUPPORTED :: struct {
	options: map[string][]string,
}

@(private)
read_SUPPORTED_message :: proc(body: EnvelopeBody, allocator := context.temp_allocator) -> (res: SUPPORTED, new_buf: []byte, err: Error) {
	// TODO(vincent): think about allocations

	res.options, new_buf = message_read_string_multimap(transmute([]byte)body, allocator = allocator) or_return

	return
}
