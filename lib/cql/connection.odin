package cql

import "core:fmt"
import "core:io"
import "core:log"
import "core:net"
import "core:os"
import "core:runtime"
import "core:time"

import "cassandra:mio"

Connection_Id :: distinct int

Connection_Error :: union #shared_nil {
	runtime.Allocator_Error,
	io.Error,
	mio.Error,
	Process_Error,
}

Connection_Stage :: enum {
	Invalid = 0,
	Create_Socket,
	Connect_To_Endpoint,
	Write_Frame,
	Read_Frame,

	Graceful_Shutdown,
}

Connection :: struct {
	// These fields are provided by the caller either in [init_connection] or [connect_endpoint]
	id: Connection_Id,
	ring: ^mio.ring,
	endpoint: net.Endpoint,

	// These fields are created and managed by the connection itself

	connection_attempt_start: time.Time,

	// Set to true when the connection has closed its socket
	// TODO(vincent): maybe don't do this ?
	closed: bool,

	// Low level stuff used to drive io_uring
	socket: os.Socket,
	sockaddr: os.SOCKADDR,
	timeout: mio.kernel_timespec,
	stage: Connection_Stage,

	buf: [dynamic]u8,

	// TODO(vincent): handle multiple streams
	stream: u16,
}

connection_init :: proc(conn: ^Connection, ring: ^mio.ring, id: Connection_Id) -> (err: Connection_Error) {
	conn.id = id
	conn.ring = ring
	conn.stage = .Create_Socket
	conn.buf = {}
	// TODO(vincent): handle multiple streams
	conn.stream = 10000

	reserve(&conn.buf, 4096) or_return
	resize(&conn.buf, 0) or_return

	return nil
}

connect_endpoint :: proc(conn: ^Connection, endpoint: net.Endpoint) -> (err: Connection_Error) {
	conn.endpoint = endpoint

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

connection_graceful_shutdown :: proc(conn: ^Connection) -> (err: Connection_Error) {
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

process_cqe :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> (res: Processing_Result, err: Connection_Error) {
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
		handle_read(conn, cqe) or_return
		return .Frame_Read, nil
	case .Graceful_Shutdown:
		handle_graceful_shutdown(conn, cqe) or_return
		return .Shutdown, nil
	case:
		return .Invalid, .Invalid_Stage
	}
}

@(private)
Process_Error :: enum {
	None = 0,
	Invalid_Stage,
}

@(private)
handle_create_socket :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
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
			sin_port = u16be(conn.endpoint.port),
			sin_addr = transmute(os.in_addr) a,
			sin_zero = {},
		}
	case net.IP6_Address:
		(^os.sockaddr_in6)(&conn.sockaddr)^ = os.sockaddr_in6 {
			sin6_family = u16(os.AF_INET6),
			sin6_port = u16be(conn.endpoint.port),
			sin6_flowinfo = 0,
			sin6_addr = transmute(os.in6_addr) a,
			sin6_scope_id = 0,
		}
	}

	log.infof("socket: %v, sockaddr: %v", conn.socket, conn.sockaddr)

	conn.connection_attempt_start = time.now()

	sqe := mio.ring_connect(conn.ring, conn.socket, &conn.sockaddr)
	sqe.flags |= mio.IOSQE_IO_LINK
	sqe.user_data = u64(uintptr(conn))

	conn.timeout = {}
	conn.timeout.tv_nsec = i64(1 * time.Second)

	timeout_sqe := mio.ring_link_timeout(conn.ring, &conn.timeout)
	timeout_sqe.user_data = 20


	return nil
}

@(private)
handle_connect_to_endpoint :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("%v", cqe)

	if cqe.res != 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Connection is established, now start the handshake with the server
	//
	// First step is a OPTIONS envelope _unframed_

	conn.stage = .Write_Frame

	options_hdr: EnvelopeHeader = {}
	options_hdr.version = .V4
	options_hdr.flags = 0
	options_hdr.stream = conn.stream
	options_hdr.opcode = .OPTIONS
	options_hdr.length = 0

	clear(&conn.buf)
	envelope_append(&conn.buf, options_hdr, nil)

	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.socket, len(conn.buf), conn.buf)

	sqe := mio.ring_write(conn.ring, os.Handle(conn.socket), conn.buf[:], 0)
	sqe.user_data = u64(uintptr(conn))

	return nil
}

@(private)
handle_write_frame :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("%v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	{
		n := int(cqe.res)
		switch {
		case n < len(conn.buf):
			return .Short_Write
		case n > len(conn.buf):
			return .Invalid_Write
		}
	}

	// TODO(vincent): write this

	conn.stage = .Read_Frame

	clear(&conn.buf)
	resize(&conn.buf, cap(conn.buf))

	log.infof("prep reading from socket fd=%d into buffer len=%v", conn.socket, len(conn.buf))

	sqe := mio.ring_read(conn.ring, os.Handle(conn.socket), conn.buf[:], 0)
	sqe.user_data = u64(uintptr(conn))

	return nil
}

@(private)
handle_read :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("%v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	n := int(cqe.res)
	if n > len(conn.buf) {
		return .Short_Buffer
	}

	// Do stuff with the data

	read_data := conn.buf[0:n]
	log.infof("read data: %q", string(read_data))

	clear(&conn.buf)

	// TODO(vincent): write me

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
handle_graceful_shutdown :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
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

