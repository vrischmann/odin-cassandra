package main

import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:sys/linux"

import "cassandra:cql"
import "cassandra:linenoise"
import "cassandra:mio"

Cli_Error :: enum {
	None = 0,
	Invalid_Endpoint = 1,
}

Error :: union #shared_nil {
	mio.OS_Error,
	cql.Connection_Error,
	Cli_Error,
}

REPL :: struct {
	ring: ^mio.ring,

	connections: [dynamic]cql.Connection,
}

init_repl :: proc(repl: ^REPL, ring: ^mio.ring) -> (err: Error) {
	repl.ring = ring
	return nil
}

destroy_repl :: proc(repl: ^REPL) {
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

run_repl :: proc(repl: ^REPL) -> (err: Error) {
	// Process CQE callback
	// callback :: proc(cqe: ^mio.io_uring_cqe) {
	// }

	// Submit SQEs, process CQEs
	tick :: proc(repl: ^REPL, nr_wait: int) -> Error {
		err := mio.ring_submit_and_wait_timeout(repl.ring, nr_wait, proc(cqe: ^mio.io_uring_cqe) {
			conn := (^cql.Connection)(uintptr(cqe.user_data))

			if err := cql.process_cqe(conn, cqe); err != nil {
				log.errorf("unable to process cqe")
			}
		})
		if err != nil {
			return err
		}

		return nil
	}

	//

	pending_cqes := 1

	loop: for {
		line := linenoise.linenoise("hello> ")
		if line == nil {
			break loop
		}
		defer linenoise.linenoiseFree(transmute(rawptr) line)

		fmt.printf("you wrote: %s\n", line)

		switch line {
		case "connect":
			endpoint_str := string(line)

			if err := do_connect(repl, endpoint_str); err != nil {
				fmt.printf("unable to connect, err: %v\n", err)
			}
		}

		tick(repl, pending_cqes) or_return
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

	// TODO(vincent): flag parsing and stuff

	// if len(os.args) < 1 {
	// 	log.fatal("Please provide the hostname: cqlcli <hostname>")
	// }
	// hostname := os.args[0]
	hostname := "127.0.0.1:9042"


	// Initialization
	ring: mio.ring = {}
	if err := mio.ring_init(&ring, 1024); err != nil {
		log.fatalf("unable to create ring, err: %v", err)
	}
	defer mio.ring_destroy(&ring)

	repl: REPL = {}
	if err := init_repl(&repl, &ring); err != nil {
		log.fatalf("unable to initialize the repl, err: %v", err)
	}

	// Run the client
	if err := run_repl(&repl); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
}
