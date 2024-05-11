package main

import "core:c/libc"
import "core:io"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:runtime"
import "core:sync"
import "core:sys/linux"
import "core:time"

import "mio"

Error :: union #shared_nil {
	runtime.Allocator_Error,
	io.Error,
	mio.Error,
	Connection_Error,
}

MyContext :: struct {
	running: bool,
	running_mu: sync.Mutex,
}

run :: proc() -> Error {
	ring := mio.new_ring(1024) or_return
	defer mio.close_ring(ring)

	//
	// Connect to endpoint
	//

	sockaddr: os.SOCKADDR
	{
		endpoint := "127.0.0.1:32458"

		tmp, err := mio.endpoint_to_sockaddr(endpoint)
		if err != nil {
			log.errorf("unable to get sockaddr from endpoint %v, err: %v", endpoint, err)
			return err
		}
		sockaddr = tmp
	}

	socket := mio.create_socket() or_return
	conn := new_connection(1, ring, socket) or_return

	connect_sqe := mio.get_sqe(&ring.underlying);
	mio.prep_connect(connect_sqe, i32(socket), &sockaddr, size_of(os.SOCKADDR))
	connect_sqe.user_data = u64(uintptr(&conn))

	//

	CQES :: 16
	cqes: [CQES]^mio.io_uring_cqe = {}

	for {
		res := mio.submit_and_wait(&ring.underlying, 1)
		if res < 0 {
			log.fatalf("unable to submit sqes, err: (%d) %v", -res, libc.strerror(libc.int(-res)))
		}

		count := mio.peek_batch_cqe(&ring.underlying, &cqes[0], CQES)
		for cqe in cqes[:count] {
			connection := (^Connection)(uintptr(cqe.user_data))

			if err := process_cqe(connection, cqe); err != nil {
				log.errorf("unable to process CQE, err: %v", err)
			}
		}

		mio.cq_advance(&ring.underlying, u32(count))
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

	// Run the client

	if err := run(); err != nil {
		log.fatalf("unable to run, err: %v", err)
	}
}
