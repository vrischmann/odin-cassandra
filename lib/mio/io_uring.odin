package mio

import "core:c"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"

foreign import uring "system:uring.a"

ring :: struct {
	underlying: io_uring,
}

init_ring :: proc(ring: ^ring, entries: int) -> (Error) {
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

destroy_ring :: proc(ring: ^ring) {
	queue_exit(&ring.underlying)
}
