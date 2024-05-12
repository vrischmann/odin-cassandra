package main

import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/unix"

import "cassandra:cql"
import "cassandra:mio"
import "third_party:linenoise"

Cli_Error :: enum {
	None = 0,
	Invalid_Endpoint = 1,
}

Error :: union #shared_nil {
	mio.Error,
	cql.Connection_Error,
	Cli_Error,
}

REPL :: struct {
	ring: ^mio.ring,

	ls: linenoise.linenoiseState,
	ls_buf: [1024]byte,
	running: bool,
	pending: int,

	connections: [dynamic]cql.Connection,
}

repl_init :: proc(repl: ^REPL, ring: ^mio.ring) -> (err: Error) {
	repl.ring = ring

	repl_init_linenoise(repl)
	repl.running = true
	repl.pending = 0

	return nil
}

repl_init_linenoise :: proc(repl: ^REPL) {
	linenoise.linenoiseEditStart(&repl.ls, -1, -1, raw_data(repl.ls_buf[:]), len(repl.ls_buf), "cqldebug> ")
}

repl_destroy :: proc(repl: ^REPL) {
	for &conn in repl.connections {
		cql.destroy_connection(&conn)
	}
	delete(repl.connections)
}

do_connect :: proc(repl: ^REPL, endpoint_str: string) -> (err: Error) {
	endpoint, ok := net.parse_endpoint(endpoint_str)
	if !ok {
		log.fatalf("invalid endpoint %v", endpoint_str)
		return .Invalid_Endpoint
	}

	//

	new_connection_id := len(repl.connections)

	conn: cql.Connection = {}
	cql.init_connection(&conn, repl.ring, cql.Connection_Id(new_connection_id)) or_return
	append(&repl.connections, conn)

	cql.connect_endpoint(&conn, endpoint) or_return

	return nil
}

repl_run :: proc(repl: ^REPL) -> (err: Error) {
	process_line :: proc(repl: ^REPL, line: string) {
		line := strings.trim_space(line)

		switch {
		case strings.has_prefix(line, "connect"):
			endpoint := strings.trim_space(line[len("connect"):])
			if len(endpoint) <= 0 {
				fmt.println("Usage: connect <hostname>")
				return
			}

			fmt.printf("endpoint: %v\n", endpoint)
		}
	}

	process_cqe :: proc(cqe: ^mio.io_uring_cqe) {
		repl := (^REPL)(context.user_ptr)

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

			defer linenoise.linenoiseFree(transmute(rawptr) line)

			fmt.printf("you wrote: %q\n", line)

			process_line(repl, string(line))

			repl_init_linenoise(repl)

		case:
			conn := (^cql.Connection)(uintptr(cqe.user_data))

			if err := cql.process_cqe(conn, cqe); err != nil {
				log.errorf("unable to process cqe")
			}
		}
	}

	issue_stdin_poll := true
	for repl.running {
		// Issue a multishot poll on stdin if necessary
		if issue_stdin_poll {
			sqe := mio.ring_poll_multishot(repl.ring, 1, unix.POLLIN)
			sqe.user_data = 1

			issue_stdin_poll = false
		}

		nr_wait := max(1, repl.pending)

		// Provide the repl as context so that we can access it in process_cqe
		context.user_ptr = rawptr(repl)
		mio.ring_submit_and_wait(repl.ring, nr_wait, process_cqe) or_return
		context.user_ptr = nil
	}

	// for {
	// 	switch line {
	// 	case "connect":
	// 		endpoint_str := string(line)
	//
	// 		if err := do_connect(repl, endpoint_str); err != nil {
	// 			fmt.printf("unable to connect, err: %v\n", err)
	// 		}
	// 	}
	//
	// 	tick(repl, pending_cqes) or_return
	// }

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
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	// Setup our own context
	// my_context : MyContext = {}
	// context.user_ptr = &my_context

	// Setup signal handlers
	libc.signal(i32(linux.Signal.SIGPIPE), proc "c" (_: i32) {})

	// libc.signal(i32(linux.Signal.SIGTERM), proc "c" (_: i32) {
	// 	context = runtime.default_context()
	//
	// 	my_context := (^MyContext)(context.user_ptr)^
	// })

	//
	//
	//

	// Initialization
	ring: mio.ring = {}
	if err := mio.ring_init(&ring, 1024); err != nil {
		log.fatalf("unable to create ring, err: %v", err)
	}
	defer mio.ring_destroy(&ring)

	repl: REPL = {}
	if err := repl_init(&repl, &ring); err != nil {
		log.fatalf("unable to initialize the repl, err: %v", err)
	}

	// Run the client
	if err := repl_run(&repl); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
}
