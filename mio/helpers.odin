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
	Parse_Address_Error,
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

create_socket :: proc() -> (os.Socket, Error) {
	tmp, errno := os.socket(os.AF_INET, os.SOCK_STREAM, 0)
	if errno < 0 {
		log.errorf("unable to create socket, err: %v", libc.strerror(libc.int(errno)))
		return 0, os_err_from_errno(-errno)
	}

	return tmp, nil
}


Parse_Address_Error :: enum {
	None = 0,
	Bad_Address,
}

endpoint_to_sockaddr :: proc(endpoint: string) -> (sockaddr: os.SOCKADDR, err: Error) {
	endpoint, ok := net.parse_endpoint(endpoint)
	if !ok {
		return {}, .Bad_Address
	}

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

	return
}

