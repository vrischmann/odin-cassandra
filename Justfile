clean:
	rm odin-cassandra
	rm *.bin

vet:
	odin build lib -collection:cassandra=lib -vet -debug
	odin build cmd/cqldebug -collection:cassandra=lib -vet -debug

build-debugcli:
	odin build cmd/cqldebug -collection:cassandra=lib -debug

run-debugcli:
	odin run cmd/cqldebug -collection:cassandra=lib -debug

test:
	odin test lib/cql -collection:cassandra=lib -debug
	odin test lib/mio -collection:cassandra=lib -debug
