package cql

import "base:runtime"
import "core:io"

import "cassandra:mio"

Error :: union #shared_nil {
	runtime.Allocator_Error,
	io.Error,
	mio.Error,
	Process_Error,
	Envelope_Parse_Error,
	Envelope_Body_Append_Error,
	Envelope_Body_Read_Error,
}
