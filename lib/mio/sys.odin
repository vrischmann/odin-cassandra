package mio

import "core:c"
import "core:os"

foreign import uring "system:uring-ffi"

kernel_timespec :: struct {
	tv_sec: i64,
	tv_nsec: i64,
}

io_uring_params :: struct {
	sq_entries: u32,
}

io_uring_sqe :: struct {
	opcode: u8,		/* type of operation for this sqe */
	flags: u8,		/* IOSQE_ flags */
	ioprio: u16,		/* ioprio for the request */
	fd: i32,		/* file descriptor to do IO on */
	using _: struct #raw_union {
		off: u64,	/* offset into file */
		addr2: u64,
		using _: struct {
			cmd_op: u32,
			__pad1: u32,
		},
	},
	using _: struct #raw_union {
		addr: u64,	/* pointer to buffer or iovecs */
		splice_off_in: u64,
	},
	len: u32,		/* buffer size or number of iovecs */
	using _: struct #raw_union {
		rw_flags: c.int,
		fsync_flags: u32,
		poll_events: u16,	/* compatibility */
		poll32_events: u32,	/* word-reversed for BE */
		sync_range_flags: u32,
		msg_flags: u32,
		timeout_flags: u32,
		accept_flags: u32,
		cancel_flags: u32,
		open_flags: u32,
		statx_flags: u32,
		fadvise_advice: u32,
		splice_flags: u32,
		rename_flags: u32,
		unlink_flags: u32,
		hardlink_flags: u32,
		xattr_flags: u32,
		msg_ring_flags: u32,
		uring_cmd_flags: u32,
	},
	user_data: u64,	/* data to be passed back at completion time */
	/* pack this to avoid bogus arm OABI complaints */
	using _: struct #raw_union {
		/* index into fixed buffers, if used */
		buf_index: u16,
		/* for grouped buffer selection */
		buf_group: u16,
	},
	/* personality to use, if used */
	personality: u16,
	using _: struct #raw_union {
		splice_fd_in: i32,
		file_index: u32,
		using _: struct {
			addr_len: u16,
			__pad3: [1]u16,
		},
	},
	using _: struct #raw_union {
		using _: struct {
			addr3: u64,
			__pad2: [1]u64,
		},
	},
}
#assert(size_of(io_uring_sqe) == 64)

io_uring_cqe :: struct {
	user_data: u64,		/* sqe->data submission passed back */
	res: i32,		/* result code for this event */
	flags: u32,
}
#assert(size_of(io_uring_cqe) == 16)

@(private)
io_uring_sq :: struct {
	khead: ^c.uint,
	ktail: ^c.uint,
	// Deprecated: use `ring_mask` instead of `*kring_mask`
	kring_mask: ^c.uint,
	// Deprecated: use `ring_entries` instead of `*kring_entries`
	kring_entries: ^c.uint,
	kflags: ^c.uint,
	kdropped: ^c.uint,
	array: ^c.uint,
	sqes: [^]io_uring_sqe,

	sqe_head: c.uint,
	sqe_tail: c.uint,

	ring_sz: c.size_t,
	ring_ptr: rawptr,

	ring_mask: c.uint,
	ring_entries: c.uint,

	pad: [2]c.uint,
}

@(private)
io_uring_cq :: struct {
	khead: ^c.uint,
	ktail: ^c.uint,
	// Deprecated: use `ring_mask` instead of `*kring_mask`
	kring_mask : ^c.uint,
	// Deprecated: use `ring_entries` instead of `*kring_entries`
	kring_entries :^c.uint,
	kflags: ^c.uint,
	koverflow : ^c.uint,
	cqes: [^]io_uring_cqe,

	ring_sz: c.size_t,
	ring_ptr: rawptr,

	ring_mask: c.uint,
	ring_entries: c.uint,

	pad: [2]c.uint,
}

@(private)
io_uring :: struct {
	sq: io_uring_sq,
	cq: io_uring_cq,
	flags: c.uint,
	ring_fd: c.int,

	features: c.uint,
	enter_ring_fd: c.int,
	int_flags: c.uint8_t,

	pad: [3]c.uint8_t,
	pad2: c.uint,
}

@(private)
IOSQE_BIT :: enum {
	IOSQE_FIXED_FILE_BIT,
	IOSQE_IO_DRAIN_BIT,
	IOSQE_IO_LINK_BIT,
	IOSQE_IO_HARDLINK_BIT,
	IOSQE_ASYNC_BIT,
	IOSQE_BUFFER_SELECT_BIT,
	IOSQE_CQE_SKIP_SUCCESS_BIT,
};

IOSQE_FIXED_FILE :: (1 << uint(IOSQE_BIT.IOSQE_FIXED_FILE_BIT))      // use fixed fileset
IOSQE_IO_DRAIN :: (1 << uint(IOSQE_BIT.IOSQE_IO_DRAIN_BIT))          // issue after inflight IO
IOSQE_IO_LINK :: (1 << uint(IOSQE_BIT.IOSQE_IO_LINK_BIT))                      // links next sqe
IOSQE_IO_HARDLINK :: (1 << uint(IOSQE_BIT.IOSQE_IO_HARDLINK_BIT))              // like LINK, but stronger
IOSQE_ASYNC :: (1 << uint(IOSQE_BIT.IOSQE_ASYNC_BIT))                          // always go async
IOSQE_BUFFER_SELECT :: (1 << uint(IOSQE_BIT.IOSQE_BUFFER_SELECT_BIT))          // select buffer from sqe->buf_group
IOSQE_CQE_SKIP_SUCCESS :: (1 << uint(IOSQE_BIT.IOSQE_CQE_SKIP_SUCCESS_BIT))    // don't post CQE if request succeeded

IORING_TIMEOUT_ABS :: (1 << 0)
IORING_TIMEOUT_UPDATE :: (1 << 1)
IORING_TIMEOUT_BOOTTIME :: (1 << 2)
IORING_TIMEOUT_REALTIME :: (1 << 3)

IORING_CQE_F_BUFFER :: (1 << 0)
IORING_CQE_F_MORE :: (1 << 1)
IORING_CQE_F_SOCK_NONEMPTY :: (1 << 2)
IORING_CQE_F_NOTIF :: (1 << 3)

@(private, link_prefix = "io_uring_")
foreign uring {
	queue_init :: proc(entries: c.uint32_t, ring: ^io_uring, flags: c.uint) -> c.int ---
	queue_exit :: proc(ring: ^io_uring) ---

	get_sqe :: proc(ring: ^io_uring) -> ^io_uring_sqe ---

	submit :: proc(ring: ^io_uring) -> c.int ---
	submit_and_wait :: proc(ring: ^io_uring, wait_nr: c.uint) -> c.int ---
	submit_and_wait_timeout :: proc(ring: ^io_uring, wait_nr: c.uint, ts: ^kernel_timespec, sigmask: ^os.sigset_t) -> c.int ---
	peek_cqe :: proc(ring: ^io_uring, cqe: ^^io_uring_cqe) -> c.int ---
	peek_batch_cqe :: proc(ring: ^io_uring, cqes: ^^io_uring_cqe, count: c.uint) -> c.int ---
	cq_advance :: proc(ring: ^io_uring, nr: c.uint) ---

	prep_socket :: proc(sqe: ^io_uring_sqe, domain: c.int, type: c.int, protocol: c.int, flags: c.uint) ---
	prep_close :: proc(sqe: ^io_uring_sqe, fd: c.int) ---
	prep_connect :: proc(sqe: ^io_uring_sqe, sockfd: c.int, addr: ^os.SOCKADDR, addr_len: os.socklen_t) ---
	prep_write :: proc(sqe: ^io_uring_sqe, fd: c.int, buf: rawptr, nbytes: c.uint, offset: u64) ---
	prep_read :: proc(sqe: ^io_uring_sqe, fd: c.int, buf: rawptr, nbytes: c.uint, offset: u64) ---
	prep_timeout :: proc(sqe: ^io_uring_sqe, ts: ^kernel_timespec, count: c.uint, flags: c.uint) ---
	prep_link_timeout :: proc(sqe: ^io_uring_sqe, ts: ^kernel_timespec, flags: c.uint) ---
	prep_poll_multishot :: proc(sqe: ^io_uring_sqe, fd: c.int, poll_mask: c.uint) ---

	// setup :: proc(entries: c.uint32_t, p: ^params) -> c.int ---
}
