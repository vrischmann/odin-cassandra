package linenoise

import "core:c"

// TODO(vincent): fork/port linenoise to work natively with io_uring ?
//
// We need a way to provide the data read from stdin via a buffer since io_uring is completion based, not readiness based.

foreign import linenoise "system:linenoise"

linenoiseEditMore: cstring = "If you see this, you are misusing the API: when linenoiseEditFeed() is called, if it returns linenoiseEditMore the user is yet editing the line. See the README file for more information."

linenoiseState :: struct {
	in_completion: c.int,
	completion_idx: c.size_t,
	ifd: c.int,
	ofd: c.int,
	buf: [^]byte,
	buflen: c.size_t,
	prompt: cstring,
	plen: c.size_t,
	pos: c.size_t,
	oldpos: c.size_t,
	len: c.size_t,
	cols: c.size_t,
	oldrows: c.size_t,
	history_index: c.int,
}

foreign linenoise {
	// linenoise :: proc(prompt: cstring) -> cstring ---
	// linenoiseFree :: proc(ptr: rawptr) ---
	linenoiseEditStart :: proc(l: ^linenoiseState, stdin_fd: c.int, stdout_fd: c.int, buf: [^]byte, buflen: c.size_t, prompt: cstring) -> c.int ---
	linenoiseEditFeed :: proc(l: ^linenoiseState) ---
	linenoiseEditStop :: proc(l: ^linenoiseState) ---
	linenoiseHide :: proc(l: ^linenoiseState) ---
	linenoiseShow :: proc(l: ^linenoiseState) ---
}
