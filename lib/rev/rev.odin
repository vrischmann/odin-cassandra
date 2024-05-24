package rev

import "core:os"

Event_Loop_Op :: enum {
	Socket,
	Close,
	Connect,
}

Event_Loop_Event :: struct {
	op:        Event_Loop_Op,
	user_data: rawptr,
}

OS_Error :: enum {
	None = 0,
	Access_Denied,
	Invalid_Argument,
	Too_Many_Open_Files,
	Broken_Pipe,
	Timer_Expired,
	Canceled,
	Connection_Refused,
	Address_Family_Not_Supported,
	Timed_Out,
	Unexpected,
}

os_err_from_errno :: proc(#any_int errno: os.Errno, location := #caller_location) -> OS_Error {
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
	case os.EAFNOSUPPORT:
		return .Address_Family_Not_Supported
	case os.ETIMEDOUT:
		return .Timed_Out
	case:
		log.warnf("unexpected errno %d", errno, location = location)

		return .Unexpected
	}
}

Error :: union #shared_nil {
	OS_Error,
}
