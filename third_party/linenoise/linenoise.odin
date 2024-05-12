package linenoise

import "core:c"
import "core:fmt"
import "base:runtime"

// TODO(vincent): fork/port linenoise to work natively with io_uring ?
//
// We need a way to provide the data read from stdin via a buffer since io_uring is completion based, not readiness based.

foreign import linenoise "src/linenoise.a"

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

RED :: 31
GREEN :: 32
YELLOW :: 33
BLUE :: 34
MAGENTA :: 35
CYAN :: 36
WHITE :: 37

foreign linenoise {
	linenoise :: proc(prompt: cstring) -> cstring ---
	linenoiseFree :: proc(ptr: rawptr) ---

	linenoiseEditStart :: proc(l: ^linenoiseState, stdin_fd: c.int, stdout_fd: c.int, buf: [^]byte, buflen: c.size_t, prompt: cstring) -> c.int ---
	linenoiseEditFeed :: proc(l: ^linenoiseState) -> cstring ---
	linenoiseEditStop :: proc(l: ^linenoiseState) ---
	linenoiseHide :: proc(l: ^linenoiseState) ---
	linenoiseShow :: proc(l: ^linenoiseState) ---

	linenoiseSetHintsCallback :: proc(cb: proc "c" (buf: cstring, color: ^c.int, bold: ^c.int) -> cstring) ---

	linenoiseHistoryAdd :: proc(line: cstring) -> c.int ---
	linenoiseHistorySetMaxLen :: proc(len: c.int) -> c.int ---
	linenoiseHistorySave :: proc(filename: cstring) -> c.int ---
	linenoiseHistoryLoad :: proc(filename: cstring) -> c.int ---
}
