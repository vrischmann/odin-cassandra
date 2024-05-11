package main

import "core:fmt"
import "core:os"
import "core:log"

import "cassandra:cql"
import "cassandra:linenoise"

main :: proc() {

	// TODO(vincent): flag parsing and stuff

	// if len(os.args) < 1 {
	// 	log.fatal("Please provide the hostname: cqlcli <hostname>")
	// }
	// hostname := os.args[0]


	//

	hostname := "127.0.0.1:9042"


	// Start the REPL

	loop: for {
		line := linenoise.linenoise("hello> ")
		if line == nil {
			break loop
		}
		defer linenoise.linenoiseFree(line)

		fmt.printf("you wrote: %s\n", line)
	}
}
