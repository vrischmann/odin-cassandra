package main

foreign import linenoise "system:linenoise"

@(private)
foreign linenoise {
	linenoise :: proc(prompt: cstring) -> [^]u8 ---
	linenoiseFree :: proc(ptr: rawptr) ---
}
