package mio

import "core:os"
import "core:c"
import "core:log"
import "core:c/libc"
import "core:net"

OS_Error :: enum {
	None = 0,
	Access_Denied,
	Invalid_Argument,
	Too_Many_Open_Files,
	Broken_Pipe,
	Timer_Expired,
	Canceled,
	Connection_Refused,

	Unexpected,
}

Error :: union #shared_nil {
	OS_Error,
}

os_err_from_errno :: proc(#any_int errno: os.Errno) -> OS_Error {
	switch errno {
	case os.EACCES:
		return .Access_Denied
	case os.EINVAL:
		return .Invalid_Argument
	case os.ENFILE:
		return .Too_Many_Open_Files
	case os.EPIPE:
		return .Broken_Pipe
	case os.ETIME:
		return .Timer_Expired
	case os.ECANCELED:
		return .Canceled
	case os.ECONNREFUSED:
		return .Connection_Refused
	case:
		log.warnf("unexpected errno %d", errno)

		return .Unexpected
	}
}

create_socket :: proc() -> (os.Socket, OS_Error) {
	tmp, errno := os.socket(os.AF_INET, os.SOCK_STREAM, 0)
	if errno < 0 {
		log.errorf("unable to create socket, err: %v", libc.strerror(libc.int(errno)))
		return 0, os_err_from_errno(-errno)
	}

	return tmp, nil
}
