package mio

import "core:c"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:time"

ring :: struct {
	underlying: io_uring,
}

ring_init :: proc(ring: ^ring, entries: int) -> Error {
	errno := queue_init(c.uint32_t(entries), &ring.underlying, 0)
	if errno < 0 {
		return os_err_from_errno(-errno)
	}

	log.debugf(
		"[ring fd: %v] flags: %v. sb entries=%d, cq entries=%d",
		ring.underlying.ring_fd,
		ring.underlying.flags,
		ring.underlying.sq.ring_entries,
		ring.underlying.cq.ring_entries,
	)

	return nil
}

ring_destroy :: proc(ring: ^ring) {
	queue_exit(&ring.underlying)
}

ring_socket :: proc(ring: ^ring, domain: int, type: int, protocol: int, flags: uint) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	log.debugf("[ring fd: %v] prepping socket for domain=%v, type=%v, protocol=%v", ring.underlying.ring_fd, domain, type, protocol)

	prep_socket(sqe, c.int(domain), c.int(type), c.int(protocol), c.uint(flags))

	return sqe
}

ring_close :: proc(ring: ^ring, fd: os.Handle) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	prep_close(sqe, c.int(fd))

	return sqe
}

ring_connect :: proc(ring: ^ring, socket: os.Socket, sockaddr: ^os.SOCKADDR) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	log.debugf("[ring fd: %v] prepping connect to %v", ring.underlying.ring_fd, sockaddr)

	prep_connect(sqe, c.int(socket), sockaddr, size_of(os.SOCKADDR))

	return sqe
}

ring_write :: proc(ring: ^ring, fd: os.Handle, buf: []byte, offset: int) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	log.debugf("[ring fd: %v] prepping write to %v", ring.underlying.ring_fd, fd)

	prep_write(sqe, c.int(fd), raw_data(buf), u32(len(buf)), u64(offset))

	return sqe
}

ring_read :: proc(ring: ^ring, fd: os.Handle, buf: []byte, offset: int) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	log.debugf("[ring fd: %v] prepping read from %v", ring.underlying.ring_fd, fd)

	prep_read(sqe, c.int(fd), raw_data(buf), u32(len(buf)), u64(offset))

	return sqe
}

// ring_timeout :: proc(ring: ^ring, timeout: time.Duration) -> ^io_uring_sqe {
// 	sqe := get_sqe(&ring.underlying)
//
// 	ts := kernel_timespec{
// 		tv_sec = 0,
// 		tv_nsec = i64(timeout),
// 	}
//
// 	prep_timeout(sqe, &ts, 1, 0)
//
// 	return sqe
// }

ring_link_timeout :: proc(ring: ^ring, timeout: ^kernel_timespec) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	log.debugf("[ring fd: %v] prepping link timeout with timeout=%v", ring.underlying.ring_fd, timeout)

	prep_link_timeout(sqe, timeout, 0)

	return sqe
}

ring_poll_multishot :: proc(ring: ^ring, fd: os.Handle, mask: uint) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	prep_poll_multishot(sqe, c.int(fd), c.uint(mask))

	return sqe
}

// ring_submit_and_wait_timeout :: proc(ring: ^ring, #any_int nr_wait: int, timeout: time.Duration, process_cqe_callback: proc(cqe: ^io_uring_cqe)) -> (err: Error) {
// 	ts := kernel_timespec{
// 		tv_sec = 0,
// 		tv_nsec = i64(timeout),
// 	}
//
// 	res := submit_and_wait_timeout(&ring.underlying, c.uint(nr_wait), &ts, nil)
// 	if res < 0 {
// 		return os_err_from_errno(-res)
// 	}
//
// 	// TODO(vincent): make this dynamic ? attach to the ring itself ?
// 	CQES :: 16
// 	cqes: [CQES]^io_uring_cqe = {}
//
// 	count := peek_batch_cqe(&ring.underlying, &cqes[0], CQES)
// 	for cqe in cqes[:count] {
// 		process_cqe_callback(cqe)
// 	}
//
// 	cq_advance(&ring.underlying, u32(count))
//
// 	return nil
// }

ring_cancel_fd :: proc(ring: ^ring, fd: os.Handle) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	prep_cancel_fd(sqe, c.int(fd), 0)

	return sqe
}

ring_shutdown :: proc(ring: ^ring, fd: os.Socket) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	prep_shutdown(sqe, c.int(fd), c.int(os.SHUT_WR))

	return sqe
}

ring_submit_and_wait :: proc(ring: ^ring, #any_int nr_wait: int, process_cqe_callback: proc(cqe: ^io_uring_cqe)) -> (err: Error) {
	res := submit_and_wait(&ring.underlying, c.uint(nr_wait))
	if res < 0 {
		return os_err_from_errno(-res)
	}

	// TODO(vincent): make this dynamic ? attach to the ring itself ?
	CQES :: 16
	cqes: [CQES]^io_uring_cqe = {}

	count := peek_batch_cqe(&ring.underlying, &cqes[0], CQES)

	log.infof("got cqes: %v", cqes[:count])

	for cqe in cqes[:count] {
		log.infof("processing cqe %v", cqe)

		process_cqe_callback(cqe)
	}

	cq_advance(&ring.underlying, u32(count))

	return nil
}
