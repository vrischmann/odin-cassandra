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

new_ring :: proc(entries: int) -> (^ring, Error) {
	res := new(ring)

	errno := queue_init(c.uint32_t(entries), &res.underlying, 0)
	if errno < 0 {
		return nil, os_err_from_errno(-errno)
	}

	log.debugf("ring fd: %v, flags: %v. sb entries=%d, cq entries=%d",
		res.underlying.ring_fd,
		res.underlying.flags,
		res.underlying.sq.ring_entries,
		res.underlying.cq.ring_entries,
	)

	return res, nil
}

destroy_ring :: proc(ring: ^ring) {
	queue_exit(&ring.underlying)
	free(ring)
}
