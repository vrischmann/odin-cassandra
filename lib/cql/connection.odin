package cql

import "core:fmt"
import "core:io"
import "core:log"
import "core:net"
import "core:os"
import "core:runtime"

import "cassandra:mio"

Connection_Id :: distinct int

Connection_Error :: union #shared_nil {
	runtime.Allocator_Error,
	io.Error,
	mio.OS_Error,
	Process_Error,
}

connection_sequence: u64 = 0

Connection :: struct {
	id: Connection_Id,
	completion_count: int,

	ring: ^mio.ring,
	socket: os.Socket,

	state: struct {
		op: enum {
			Connect = 0,
			Write = 1,
			Read = 2,
			Timeout = 3,
		},

		buf: [dynamic]u8,
	},
}

init_connection :: proc(ring: ^mio.ring, conn: ^Connection, id: Connection_Id) -> (err: Connection_Error) {
	conn.id = id
	conn.completion_count = 0
	conn.ring = ring
	conn.socket = mio.create_socket() or_return
	conn.state = {}

	reserve(&conn.state.buf, 4096) or_return
	resize(&conn.state.buf, 0) or_return

	return nil
}

connect_endpoint :: proc(conn: ^Connection, endpoint: net.Endpoint) -> (err: Connection_Error) {
	// Prepare the SOCKADDR
	sockaddr: os.SOCKADDR = {}
	switch a in endpoint.address {
	case net.IP4_Address:
		(^os.sockaddr_in)(&sockaddr)^ = os.sockaddr_in {
			sin_family = u16(os.AF_INET),
			sin_port = u16be(endpoint.port),
			sin_addr = transmute(os.in_addr) a,
			sin_zero = {},
		}
	case net.IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_family = u16(os.AF_INET),
			sin6_port = u16be(endpoint.port),
			sin6_flowinfo = 0,
			sin6_addr = transmute(os.in6_addr) a,
			sin6_scope_id = 0,
		}
	}

	// Arm connection to the endpoint
	connect_sqe := mio.get_sqe(&conn.ring.underlying);
	mio.prep_connect(connect_sqe, i32(conn.socket), &sockaddr, size_of(os.SOCKADDR))
	connect_sqe.user_data = u64(uintptr(conn))

	return nil
}

destroy_connection :: proc(conn: ^Connection) {
	delete(conn.state.buf)
}

process_cqe :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	conn.completion_count += 1

	switch conn.state.op {
	case .Connect:
		return process_cqe_connect(conn, cqe)
	case .Write:
		return process_cqe_write(conn, cqe)
	case .Read:
		return process_cqe_read(conn, cqe)
	case .Timeout:
		return process_cqe_timeout(conn, cqe)
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
process_cqe_connect :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: connect]: %v", cqe)

	if cqe.res != 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	conn.state.op = .Write

	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.socket, len(conn.state.buf), conn.state.buf)

	write_sqe := mio.get_sqe(&conn.ring.underlying)
	mio.prep_write(write_sqe, i32(conn.socket), raw_data(conn.state.buf), u32(len(conn.state.buf)), 0)
	write_sqe.user_data = u64(uintptr(conn))

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

	log.infof("prep reading")

	read_sqe := mio.get_sqe(&conn.ring.underlying)
	mio.prep_read(read_sqe, i32(conn.socket), raw_data(conn.state.buf), u32(len(conn.state.buf)), 0)
	read_sqe.user_data = u64(uintptr(conn))

	return nil
}

@(private)
process_cqe_read :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: read]: %+v", cqe)

	if cqe.res < 0 {
		return mio.os_err_from_errno(-cqe.res)
	}

	// Sanity checks
	n := int(cqe.res)
	if n > len(conn.state.buf) {
		return .Short_Buffer
	}

	// Do stuff with the data

	read_data := conn.state.buf[0:n]
	log.infof("read data: %q", string(read_data))

	clear(&conn.state.buf)

	// Arm a timeout for the next write+read

	conn.state.op = .Timeout

	log.infof("prep timeout")

	ts := mio.kernel_timespec{
		tv_sec = 2,
		tv_nsec = 0,
	}

	timeout_sqe := mio.get_sqe(&conn.ring.underlying)
	mio.prep_timeout(timeout_sqe, &ts, 1, 0)
	timeout_sqe.user_data = u64(uintptr(conn))

	return nil
}

@(private)
process_cqe_timeout :: proc(conn: ^Connection, cqe: ^mio.io_uring_cqe) -> Connection_Error {
	log.infof("[OP: timeout]: %+v", cqe)

	if cqe.res < 0 {
		err := mio.os_err_from_errno(-cqe.res)
		if err != nil && err != .Timer_Expired {
			return err
		}
	}

	conn.state.op = .Write

	resize(&conn.state.buf, cap(conn.state.buf))

	data := fmt.bprintf(conn.state.buf[:], "writing, completion count: %d", conn.completion_count)

	resize(&conn.state.buf, len(data))

	log.infof("prep writing to socket fd=%d len=%v data=%q", conn.socket, len(data), data)

	write_sqe := mio.get_sqe(&conn.ring.underlying)
	mio.prep_write(write_sqe, i32(conn.socket), raw_data(conn.state.buf), u32(len(conn.state.buf)), 0)
	write_sqe.user_data = u64(uintptr(conn))

	return nil
}
