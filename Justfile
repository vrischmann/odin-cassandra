clean:
	rm odin-cassandra
	rm *.bin

build:
	odin build . -debug

test:
	odin test . -debug
	odin test cql -debug
