clean:
	rm odin-cassandra
	rm *.bin

vet:
	odin build lib -collection:cassandra=lib -vet -debug
	odin build cmd/cqlcli -collection:cassandra=lib -vet -debug

build-cli:
	odin build cmd/cqlcli -collection:cassandra=lib -debug

run-cli:
	odin run cmd/cqlcli -collection:cassandra=lib -debug

test:
	odin test lib/cql -collection:cassandra=lib -debug
	odin test lib/mio -collection:cassandra=lib -debug
