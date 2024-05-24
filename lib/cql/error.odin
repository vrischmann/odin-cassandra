package cql

import "base:runtime"
import "core:io"

import "cassandra:rev"

Error :: union #shared_nil {
	runtime.Allocator_Error,
	io.Error,
	rev.Error,
	Process_Error,
	Envelope_Parse_Error,
	Message_Append_Error,
	Message_Read_Error,
}
