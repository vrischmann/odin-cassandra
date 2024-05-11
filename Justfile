clean:
	rm odin-cassandra
	rm *.bin

build:
	odin build . -debug

vet:
	odin build . -vet -debug
	odin build cqlcli -debug

build-cli:
	odin build cqlcli -debug

test:
	odin test . -debug
	odin test cql -debug
