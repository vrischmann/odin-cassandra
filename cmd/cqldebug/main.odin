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

tick :: proc(ring: ^mio.ring) -> Error {
	CQES :: 16
	cqes: [CQES]^mio.io_uring_cqe = {}

	for {
		res := mio.submit_and_wait(&ring.underlying, 1)
		if res < 0 {
			log.fatalf("unable to submit sqes, err: (%d) %v", -res, libc.strerror(libc.int(-res)))
		}

		count := mio.peek_batch_cqe(&ring.underlying, &cqes[0], CQES)
		for cqe in cqes[:count] {
			conn := (^cql.Connection)(uintptr(cqe.user_data))

			if err := cql.process_cqe(conn, cqe); err != nil {
				log.errorf("unable to process CQE, err: %v", err)
			}
		}

		mio.cq_advance(&ring.underlying, u32(count))
	}
}


runREPL :: proc(ring: ^mio.ring, connection: ^cql.Connection) -> (err: Error) {

	loop: for {
		tick(ring) or_return

		line := linenoise.linenoise("hello> ")
		if line == nil {
			break loop
		}
		defer linenoise.linenoiseFree(transmute(rawptr) line)

		fmt.printf("you wrote: %s\n", line)

		switch line {
		case "startup":
			do_startup(ring)
		}
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
	defer cql.destroy_connection(&conn)

	if err := cql.connect_endpoint(&conn, endpoint); err != nil {
		log.fatalf("unable to create new connection, err: %v", err)
	}

	// Run the client
	if err := runREPL(&ring, &conn); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
}
