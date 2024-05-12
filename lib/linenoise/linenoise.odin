package linenoise

foreign import linenoise "system:linenoise"

foreign linenoise {
	linenoise :: proc(prompt: cstring) -> cstring ---
	linenoiseFree :: proc(ptr: rawptr) ---
}
