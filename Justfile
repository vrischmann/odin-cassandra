set positional-arguments

clean:
	rm odin-cassandra
	rm *.bin

vet:
	odin build lib -collection:cassandra=lib -collection:third_party=third_party -vet -debug
	odin build cmd/cqldebug -collection:cassandra=lib -collection:third_party=third_party -vet -debug

build-debugcli:
	odin build cmd/cqldebug -collection:cassandra=lib -collection:third_party=third_party -debug

run-debugcli *ARGS:
	odin run cmd/cqldebug -collection:cassandra=lib -collection:third_party=third_party -debug -- {{ARGS}}

run-repl:
	odin run cmd/cqldebug -collection:cassandra=lib -collection:third_party=third_party -debug -- repl

test:
	odin test lib/cql -collection:cassandra=lib -collection:third_party=third_party -debug
	odin test lib/mio -collection:cassandra=lib -collection:third_party=third_party -debug
