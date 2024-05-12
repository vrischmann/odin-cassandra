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

ring_init :: proc(ring: ^ring, entries: int) -> (Error) {
	errno := queue_init(c.uint32_t(entries), &ring.underlying, 0)
	if errno < 0 {
		return os_err_from_errno(-errno)
	}

	log.debugf("ring fd: %v, flags: %v. sb entries=%d, cq entries=%d",
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

ring_connect :: proc(ring: ^ring, socket: i32, sockaddr: ^os.SOCKADDR) -> ^io_uring_sqe {
	sqe := get_sqe(&ring.underlying)

	prep_connect(sqe, socket, sockaddr, size_of(os.SOCKADDR))

	return sqe
}

ring_submit_and_wait_timeout :: proc(ring: ^ring, #any_int nr_wait: int, timeout: time.Duration, process_cqe_callback: proc(cqe: ^io_uring_cqe)) -> (err: Error) {
	ts := kernel_timespec{
		tv_sec = 0,
		tv_nsec = i64(timeout),
	}

	res := submit_and_wait_timeout(&ring.underlying, c.uint(nr_wait), &ts, nil)
	if res < 0 {
		return os_err_from_errno(-res)
	}

	// TODO(vincent): make this dynamic ? attach to the ring itself ?
	CQES :: 16
	cqes: [CQES]^io_uring_cqe = {}

	count := peek_batch_cqe(&ring.underlying, &cqes[0], CQES)
	for cqe in cqes[:count] {
		process_cqe_callback(cqe)
	}

	cq_advance(&ring.underlying, u32(count))

	return nil
}
