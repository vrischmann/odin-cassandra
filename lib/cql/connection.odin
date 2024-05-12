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

Connection :: struct {
	// These fields are provided by the caller either in [init_connection] or [connect_endpoint]
	id: Connection_Id,
	ring: ^mio.ring,
	endpoint: net.Endpoint,

	// These fields are created and managed by the connection itself

	completion_count: int,

	state: struct {
		closed: bool,

		socket: os.Socket,
		sockaddr: os.SOCKADDR,

		current_timeout: mio.kernel_timespec,

		op: enum {
			Socket = 0,
			Close,
			Connect,
			Write,
			Read,
			Timeout,
		},

		buf: [dynamic]u8,
	},
}

init_connection :: proc(conn: ^Connection, ring: ^mio.ring, id: Connection_Id) -> (err: Connection_Error) {
	conn.id = id
	conn.completion_count = 0
	conn.ring = ring
	conn.state = {}

	reserve(&conn.state.buf, 4096) or_return
	resize(&conn.state.buf, 0) or_return

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

destroy_connection :: proc(conn: ^Connection) {
	delete(conn.state.buf)
}

process_cqe :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	conn.completion_count += 1

	#partial switch conn.state.op {
	case .Socket:
		return process_cqe_socket(conn, cqe)
	case .Close:
		return process_cqe_close(conn, cqe)
	case .Connect:
		return process_cqe_connect(conn, cqe)
	case .Write:
		return process_cqe_write(conn, cqe)
	// case .Read:
	// 	return process_cqe_read(conn, cqe)
	// case .Timeout:
	// 	return process_cqe_timeout(conn, cqe)
	case:
		return .Invalid_Op
	}
}

@(private)
Process_Error :: enum {
	None = 0,
	Invalid_Op,
}

@(private)
process_cqe_socket :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: socket]: %v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}


	// We got a socket, connect to it

	conn.state.socket = os.Socket(cqe.res)
	conn.state.op = .Connect

	// Prepare the SOCKADDR
	switch a in conn.endpoint.address {
	case net.IP4_Address:
		(^os.sockaddr_in)(&conn.state.sockaddr)^ = os.sockaddr_in {
			sin_family = u16(os.AF_INET),
			sin_port = u16be(conn.endpoint.port),
			sin_addr = transmute(os.in_addr) a,
			sin_zero = {},
		}
	case net.IP6_Address:
		(^os.sockaddr_in6)(&conn.state.sockaddr)^ = os.sockaddr_in6 {
			sin6_family = u16(os.AF_INET6),
			sin6_port = u16be(conn.endpoint.port),
			sin6_flowinfo = 0,
			sin6_addr = transmute(os.in6_addr) a,
			sin6_scope_id = 0,
		}
	}

	log.infof("socket: %v, sockaddr: %v", conn.state.socket, conn.state.sockaddr)

	sqe := mio.ring_connect(conn.ring, conn.state.socket, &conn.state.sockaddr)
	sqe.flags |= mio.IOSQE_IO_LINK
	sqe.user_data = u64(uintptr(conn))

	conn.state.current_timeout.tv_sec = 0
	conn.state.current_timeout.tv_nsec = i64(1 * time.Second)

	timeout_sqe := mio.ring_link_timeout(conn.ring, &conn.state.current_timeout)
	timeout_sqe.user_data = u64(uintptr(conn))


	return nil
}

@(private)
process_cqe_close :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.debugf("[OP: close]: %v", cqe)

	if cqe.res == 0 {
		log.infof("socket %v has been closed", conn.state.socket)
		conn.state.closed = true
	} else {
		err := mio.os_err_from_errno(-cqe.res)
		log.warnf("unable to close socket %v, err: %v", conn.state.socket, err)
	}

	return nil
}

@(private)
process_cqe_connect :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: connect]: %v", cqe)

	if cqe.res != 0 {
		err := mio.os_err_from_errno(-cqe.res)
		#partial switch err {
		case .Timer_Expired:
			log.debug("timeout triggered")
			return nil
		case .Canceled:
			log.warnf("connection attempt timed out, closing socket")

			conn.state.op = .Close

			sqe := mio.ring_close(conn.ring, os.Handle(conn.state.socket))
			sqe.user_data = u64(uintptr(conn))

			return nil

		case:
			return err
		}
	}

	conn.state.op = .Write

	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.state.socket, len(conn.state.buf), conn.state.buf)

	sqe := mio.ring_write(conn.ring, os.Handle(conn.state.socket), conn.state.buf[:], 0)
	sqe.user_data = u64(uintptr(conn))

	log.infof("prepped write")

	return nil
}

@(private)
process_cqe_write :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: write]: %v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	{
		n := int(cqe.res)
		switch {
		case n < len(conn.state.buf):
			return .Short_Write
		case n > len(conn.state.buf):
			return .Invalid_Write
		}
	}

	//

	conn.state.op = .Read

	clear(&conn.state.buf)
	resize(&conn.state.buf, cap(conn.state.buf))

	log.infof("prep reading from socket fd=%d into buffer len=%v", conn.state.socket, len(conn.state.buf))

	sqe := mio.ring_read(conn.ring, os.Handle(conn.state.socket), conn.state.buf[:], 0)
	sqe.user_data = u64(uintptr(conn))

	return nil
}

// @(private)
// process_cqe_read :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
// 	log.infof("[OP: read]: %+v", cqe)
//
// 	if cqe.res < 0 {
// 		return mio.os_err_from_errno(-cqe.res)
// 	}
//
// 	// Sanity checks
// 	n := int(cqe.res)
// 	if n > len(conn.state.buf) {
// 		return .Short_Buffer
// 	}
//
// 	// Do stuff with the data
//
// 	read_data := conn.state.buf[0:n]
// 	log.infof("read data: %q", string(read_data))
//
// 	clear(&conn.state.buf)
//
// 	// Arm a timeout for the next write+read
//
// 	conn.state.op = .Timeout
//
// 	log.infof("prep timeout")
//
// 	sqe := mio.ring_timeout(conn.ring, 2 * time.Second)
// 	sqe.user_data = u64(uintptr(conn))
//
// 	return nil
// }
//
// @(private)
// process_cqe_timeout :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
// 	log.infof("[OP: timeout]: %+v", cqe)
//
// 	if cqe.res < 0 {
// 		err := mio.os_err_from_errno(-cqe.res)
// 		if err != nil && err != .Timer_Expired {
// 			return err
// 		}
// 	}
//
// 	conn.state.op = .Write
//
// 	resize(&conn.state.buf, cap(conn.state.buf))
//
// 	data := fmt.bprintf(conn.state.buf[:], "writing, completion count: %d", conn.completion_count)
//
// 	resize(&conn.state.buf, len(data))
//
// 	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.state.socket, len(data), data)
//
// 	sqe := mio.ring_write(conn.ring, os.Handle(conn.state.socket), conn.state.buf[:], 0)
// 	sqe.user_data = u64(uintptr(conn))
//
// 	return nil
// }
