package linenoise

foreign import linenoise "system:linenoise"

foreign linenoise {
	linenoise :: proc(prompt: cstring) -> [^]u8 ---
	linenoiseFree :: proc(ptr: rawptr) ---
}
