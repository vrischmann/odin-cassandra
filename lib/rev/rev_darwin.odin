package rev

import "core:os"

KQueue :: struct {}

Event_Loop :: struct {
	queue: KQueue,
}

event_loop_init :: proc(event_loop: ^Event_Loop) -> (err: Error) {
	return nil
}

event_loop_destroy :: proc(event_loop: ^Event_Loop) {
}

create_socket :: proc(event_loop: ^Event_Loop, domain: int, type: int, protocol: int, flags: uint) -> (err: Error) {
	socket, errno := os.socket(os.AF_INET, os.SOCK_STREAM, 0)
	if errno < 0 {
		return os_err_from_errno(errno)
	}
}

event_loop_close :: proc(event_loop: ^Event_Loop) {
}
