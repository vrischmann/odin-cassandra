package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/unix"
import "core:time"

import "cassandra:cql"
import "third_party:linenoise"

SIGPIPE :: 13

Cli_Error :: enum {
	None             = 0,
	Invalid_Endpoint = 1,
}

Error :: union #shared_nil {
	runtime.Allocator_Error,
	cql.Error,
	Cli_Error,
}

REPL :: struct {
	event_loop:          ^Event_Loop,
	ls:                  linenoise.linenoiseState,
	ls_buf:              [1024]byte,
	ls_history_filename: string,
	running:             bool,
	pending:             int, // TODO(vincent): this doesn't seem useful ?
	last_submit_time:    time.Time,

	// TODO(vincent): implement some client abstraction to talk over multiple connections to multiple servers
	conn:                ^cql.Connection,
}

repl_init :: proc(repl: ^REPL, history_filename: string, event_loop: ^Event_Loop) -> (err: Error) {
	repl.event_loop = event_loop
	repl.ls_history_filename = history_filename

	repl_linenoise_init(repl)
	repl_linenoise_reset(repl)

	repl.running = true
	repl.pending = 0

	return nil
}

repl_linenoise_init :: proc(repl: ^REPL) {
	linenoise.linenoiseSetHintsCallback(repl_linenoise_hints_callback)

	history_filename := strings.clone_to_cstring(repl.ls_history_filename, context.temp_allocator)

	linenoise.linenoiseHistoryLoad(history_filename)
	linenoise.linenoiseHistorySetMaxLen(1000)
}

repl_linenoise_hints_callback :: proc "c" (buf: cstring, color: ^c.int, bold: ^c.int) -> cstring {
	buf := string(buf)

	if len(buf) >= 2 && buf[:2] == "co" {
		color^ = linenoise.MAGENTA
		bold^ = 1
		return " <endpoint>"
	}

	return nil
}

repl_linenoise_reset :: proc(repl: ^REPL) {
	linenoise.linenoiseEditStart(&repl.ls, -1, -1, raw_data(repl.ls_buf[:]), len(repl.ls_buf), "cqldebug> ")
}

repl_destroy :: proc(repl: ^REPL) {
	if repl.conn == nil {
		return
	}

	cql.connection_destroy(repl.conn)
	free(repl.conn)
	repl.conn = nil
}

repl_reap_closed_connections :: proc(repl: ^REPL) {
	if repl.conn == nil {
		return
	}

	if repl.conn.closed {
		log.infof("reaping connection %v", repl.conn)

		cql.connection_destroy(repl.conn)
		free(repl.conn)
		repl.conn = nil
	}
}

repl_process_line :: proc(repl: ^REPL, line: string) -> (err: Error) {
	save_line := false
	line := strings.trim_space(line)

	sb := strings.builder_make_none(allocator = context.temp_allocator)

	switch {
	case strings.has_prefix(line, "connect"):
		//
		// Command: connect <hostname>
		//
		// Parse the endpoint to validate it

		endpoint_str := strings.trim_space(line[len("connect"):])
		if len(endpoint_str) <= 0 {
			fmt.eprintfln("\x1b[1mUsage\x1b[0m: connect <hostname>")
			return
		}

		endpoint, ok := net.parse_endpoint(endpoint_str)
		if !ok {
			fmt.eprintfln("\x1b[1m\x1b[31mendpoint is invalid\x1b[0m\x1b[22m")
			return
		}

		save_line = true

		// Create and open the connection
		repl.conn = new(cql.Connection)
		cql.connection_init(repl.conn, repl.ring, 1, endpoint) or_return
	}

	if save_line {
		cline := strings.clone_to_cstring(line, context.temp_allocator)
		history_filename := strings.clone_to_cstring(repl.ls_history_filename, context.temp_allocator)

		linenoise.linenoiseHistoryAdd(cline)
		linenoise.linenoiseHistorySave(history_filename)
	}

	return nil
}


repl_process_cqe :: proc(repl: ^REPL, cqe: ^mio.io_uring_cqe) -> (err: Error) {
	switch cqe.user_data {
	case 1:
		// stdin is ready
		line := linenoise.linenoiseEditFeed(&repl.ls)
		if line == linenoise.linenoiseEditMore {
			return
		}

		// either we got a line or the user has exited; reset the state
		linenoise.linenoiseEditStop(&repl.ls)

		if line == nil {
			repl.running = false
			return
		}

		defer linenoise.linenoiseFree(transmute(rawptr)line)

		repl_process_line(repl, string(line)) or_return
		repl_linenoise_reset(repl)

		if cqe.flags & mio.IORING_CQE_F_MORE == 0 {
			log.debug("not more")
		} else {
			log.debug("has more")
		}

	case 100, 20:
	// Expected; on some SQE we don't use the connection pointer because it's not absolutely necessary
	//
	// We could simply use 0 and don't log anything but while working on this code I want to be able to see when I let 0 by mistake

	case 0:
		log.warnf("got cqe without user data: %v, res as errno: %v", cqe, mio.os_err_from_errno(os.Errno(-cqe.res)))

	case:
		conn := (^cql.Connection)(uintptr(cqe.user_data))

		linenoise.linenoiseHide(&repl.ls)
		defer linenoise.linenoiseShow(&repl.ls)

		// log.debugf("got cqe %v for conn %v", cqe, conn)

		// TODO(vincent): this is ugly as hell but seems like the more straightforward way to handle errors

		result, err := cql.process_cqe(conn, cqe)
		#partial switch e in err {
		case rev.OS_Error:
			#partial switch e {
			case .Canceled, .Connection_Refused:
				#partial switch conn.stage {
				case .Connect_To_Endpoint:
					fmt.eprintfln(
						"\x1b[1m\x1b[31munable to connect to endpoint %v: %v\x1b[0m\x1b[22m",
						net.endpoint_to_string(conn.endpoint),
						err,
					)
				}

				cql.connection_graceful_shutdown(conn) or_return

			case:
				return err
			}

		case nil:
			#partial switch result {
			case .Connection_Established:
				fmt.printfln(
					"\x1b[1m\x1b[32mconnection to %v established in %v\x1b[0m\x1b[22m",
					net.endpoint_to_string(conn.endpoint),
					time.since(conn.connection_attempt_start),
				)
			}

		case:
			return err
		}
	}

	return nil
}


repl_run :: proc(repl: ^REPL) -> (err: Error) {
	issue_stdin_poll := true
	for repl.running {
		// Issue a multishot poll on stdin if necessary
		if issue_stdin_poll {
			sqe := mio.ring_poll_multishot(repl.ring, 1, unix.POLLIN)
			sqe.user_data = 1

			issue_stdin_poll = false
		}

		nr_wait := max(1, repl.pending)

		repl.last_submit_time = time.now()

		// Provide the repl as context so that we can access it in process_cqe
		context.user_ptr = rawptr(repl)
		mio.ring_submit_and_wait(repl.ring, nr_wait, proc(cqe: ^mio.io_uring_cqe) {
			repl := (^REPL)(context.user_ptr)

			err := repl_process_cqe(repl, cqe)
			if err != nil {
				linenoise.linenoiseHide(&repl.ls)
				defer linenoise.linenoiseShow(&repl.ls)

				fmt.eprintfln("\x1b[1m\x1b[31munable to process CQE, err: %v\x1b[0m\x1b[22m", err)
			}
		}) or_return
		context.user_ptr = nil

		// Reap closed connections.
		//
		// Connections can be closed for a number of reasons; the remote endpoint is not available or closed its connection,
		// network is unreachable, etc.
		//
		// When that happens the connection closes its socket and marks itself as closed which renders it unusable.
		//
		// TODO(vincent): maybe we could reuse the connection instead: rearm it to start from scratch

		repl_reap_closed_connections(repl)
	}

	fmt.println("stopped")

	return nil
}

main :: proc() {
	// Setup allocator
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}

		logging: log.Log_Allocator
		log.log_allocator_init(&logging, .Debug, .Human, context.allocator)
		context.allocator = log.log_allocator(&logging)
	}

	// Setup logger
	log_file, log_file_errno := os.open(".cqldebug.log", os.O_CREATE | os.O_TRUNC | os.O_RDWR, 0o0644)
	if log_file_errno != 0 {
		log.fatalf("unable to open log file, err: %v", log_file_errno)
	}

	logger := log.create_file_logger(log_file)
	defer log.destroy_file_logger(&logger)
	context.logger = logger

	// Setup signal handlers
	libc.signal(SIGPIPE, proc "c" (_: i32) {})

	//
	//
	//

	history_filename := ".cqldebug.history"

	// Initialization
	event_loop: Event_Loop = {}
	if err := event_loop_init(&event_loop); err != nil {
		log.fatalf("unable to initialize event loop, err: %v", err)
	}

	repl: REPL = {}
	if err := repl_init(&repl, history_filename, &event_loop); err != nil {
		log.fatalf("unable to initialize the repl, err: %v", err)
	}
	defer repl_destroy(&repl)

	// Run the client
	if err := repl_run(&repl); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
}
