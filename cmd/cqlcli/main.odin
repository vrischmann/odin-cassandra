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

Error :: union #shared_nil {
	cql.Connection_Error,
}

runREPL :: proc(ring: ^mio.ring, connection: ^cql.Connection) -> (err: Error) {

	loop: for {
		line := linenoise.linenoise("hello> ")
		if line == nil {
			break loop
		}
		defer linenoise.linenoiseFree(line)

		fmt.printf("you wrote: %s\n", line)
	}
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

	endpoint, ok := net.parse_endpoint(hostname)
	if !ok {
		log.fatalf("invalid endpoint %v", hostname)
	}

	// Initialization
	ring: mio.ring = {}
	if err := mio.init_ring(&ring, 1024); err != nil {
		log.fatalf("unable to create ring, err: %v", err)
	}
	defer mio.destroy_ring(&ring)

	conn: cql.Connection = {}
	if err := cql.init_connection(&ring, &conn, 200); err != nil {
		log.fatalf("unable to initialize connection, err: %v", err)
	}

	if conn_err := cql.connect_endpoint(&ring, &conn, endpoint); conn_err != nil {
		log.fatalf("unable to create new connection, err: %v", conn_err)
	}
	defer cql.destroy_connection(&conn)

	// Run the client
	if err := runREPL(&ring, &conn); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
	fmt.println("stopped")
}
