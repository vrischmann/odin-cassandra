package rev

import "cassandra:mio"

Event_Loop :: struct {
	ring: mio.ring,
}

event_loop_init :: proc(event_loop: ^Event_Loop) -> (err: Error) {
	mio.ring_init(&event_loop.ring, 1024) or_return

	return nil
}

event_loop_destroy :: proc(event_loop: ^Event_Loop) {
	mio.ring_destroy(event_loop.ring)
}

create_socket :: proc(event_loop: ^Event_Loop, domain: int, type: int, protocol: int, flags: uint) -> (err: Error) {
	sqe := mio.ring_socket(&event_loop.ring, domain, type, protocol, flags)
	sqe.user_data = context.user_ptr

	return nil
}

close_socket :: proc(event_loop: ^Event_Loop, socket: os.Socket) {
}

@(private)
process_cqe :: proc(event_loop: ^Event_Loop, cqe: ^mio.io_uring_cqe) -> (err: Event_Loop_Error) {
}

Connection :: struct {
	ring:     ^mio.ring,
	socket:   os.Socket,
	sockaddr: os.SOCKADDR,
	timeout:  mio.kernel_timespec,
}

connection_init :: proc(conn: ^Connection, ring: ^mio.ring) -> (err: Error) {
	conn.ring = ring
}
