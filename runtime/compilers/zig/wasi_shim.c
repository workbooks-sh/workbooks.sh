/* auto-generated: zig's C-backend wasi bare names -> wasi-libc __wasi_ imports.
   Generated from <wasi/wasip1.h> (see compilers/zig/README.org). */
#include <wasi/wasip1.h>
__wasi_errno_t args_get(uint8_t **argv, uint8_t *argv_buf) { return __wasi_args_get(argv, argv_buf); }
__wasi_errno_t args_sizes_get(__wasi_size_t *retptr0, __wasi_size_t *retptr1) { return __wasi_args_sizes_get(retptr0, retptr1); }
__wasi_errno_t clock_res_get(__wasi_clockid_t id, __wasi_timestamp_t *retptr0) { return __wasi_clock_res_get(id, retptr0); }
__wasi_errno_t clock_time_get(__wasi_clockid_t id, __wasi_timestamp_t precision, __wasi_timestamp_t *retptr0) { return __wasi_clock_time_get(id, precision, retptr0); }
__wasi_errno_t environ_get(uint8_t **environ, uint8_t *environ_buf) { return __wasi_environ_get(environ, environ_buf); }
__wasi_errno_t environ_sizes_get(__wasi_size_t *retptr0, __wasi_size_t *retptr1) { return __wasi_environ_sizes_get(retptr0, retptr1); }
__wasi_errno_t fd_close(__wasi_fd_t fd) { return __wasi_fd_close(fd); }
__wasi_errno_t fd_fdstat_get(__wasi_fd_t fd, __wasi_fdstat_t *retptr0) { return __wasi_fd_fdstat_get(fd, retptr0); }
__wasi_errno_t fd_filestat_get(__wasi_fd_t fd, __wasi_filestat_t *retptr0) { return __wasi_fd_filestat_get(fd, retptr0); }
__wasi_errno_t fd_filestat_set_size(__wasi_fd_t fd, __wasi_filesize_t size) { return __wasi_fd_filestat_set_size(fd, size); }
__wasi_errno_t fd_filestat_set_times(__wasi_fd_t fd, __wasi_timestamp_t atim, __wasi_timestamp_t mtim, __wasi_fstflags_t fst_flags) { return __wasi_fd_filestat_set_times(fd, atim, mtim, fst_flags); }
__wasi_errno_t fd_pread(__wasi_fd_t fd, const __wasi_iovec_t *iovs, size_t iovs_len, __wasi_filesize_t offset, __wasi_size_t *retptr0) { return __wasi_fd_pread(fd, iovs, iovs_len, offset, retptr0); }
__wasi_errno_t fd_pwrite(__wasi_fd_t fd, const __wasi_ciovec_t *iovs, size_t iovs_len, __wasi_filesize_t offset, __wasi_size_t *retptr0) { return __wasi_fd_pwrite(fd, iovs, iovs_len, offset, retptr0); }
__wasi_errno_t fd_read(__wasi_fd_t fd, const __wasi_iovec_t *iovs, size_t iovs_len, __wasi_size_t *retptr0) { return __wasi_fd_read(fd, iovs, iovs_len, retptr0); }
__wasi_errno_t fd_readdir(__wasi_fd_t fd, uint8_t *buf, __wasi_size_t buf_len, __wasi_dircookie_t cookie, __wasi_size_t *retptr0) { return __wasi_fd_readdir(fd, buf, buf_len, cookie, retptr0); }
__wasi_errno_t fd_seek(__wasi_fd_t fd, __wasi_filedelta_t offset, __wasi_whence_t whence, __wasi_filesize_t *retptr0) { return __wasi_fd_seek(fd, offset, whence, retptr0); }
__wasi_errno_t fd_sync(__wasi_fd_t fd) { return __wasi_fd_sync(fd); }
__wasi_errno_t fd_write(__wasi_fd_t fd, const __wasi_ciovec_t *iovs, size_t iovs_len, __wasi_size_t *retptr0) { return __wasi_fd_write(fd, iovs, iovs_len, retptr0); }
__wasi_errno_t path_create_directory(__wasi_fd_t fd, const char *path) { return __wasi_path_create_directory(fd, path); }
__wasi_errno_t path_filestat_get(__wasi_fd_t fd, __wasi_lookupflags_t flags, const char *path, __wasi_filestat_t *retptr0) { return __wasi_path_filestat_get(fd, flags, path, retptr0); }
__wasi_errno_t path_link(__wasi_fd_t old_fd, __wasi_lookupflags_t old_flags, const char *old_path, __wasi_fd_t new_fd, const char *new_path) { return __wasi_path_link(old_fd, old_flags, old_path, new_fd, new_path); }
__wasi_errno_t path_open(__wasi_fd_t fd, __wasi_lookupflags_t dirflags, const char *path, __wasi_oflags_t oflags, __wasi_rights_t fs_rights_base, __wasi_rights_t fs_rights_inheriting, __wasi_fdflags_t fdflags, __wasi_fd_t *retptr0) { return __wasi_path_open(fd, dirflags, path, oflags, fs_rights_base, fs_rights_inheriting, fdflags, retptr0); }
__wasi_errno_t path_readlink(__wasi_fd_t fd, const char *path, uint8_t *buf, __wasi_size_t buf_len, __wasi_size_t *retptr0) { return __wasi_path_readlink(fd, path, buf, buf_len, retptr0); }
__wasi_errno_t path_remove_directory(__wasi_fd_t fd, const char *path) { return __wasi_path_remove_directory(fd, path); }
__wasi_errno_t path_rename(__wasi_fd_t fd, const char *old_path, __wasi_fd_t new_fd, const char *new_path) { return __wasi_path_rename(fd, old_path, new_fd, new_path); }
__wasi_errno_t path_symlink(const char *old_path, __wasi_fd_t fd, const char *new_path) { return __wasi_path_symlink(old_path, fd, new_path); }
__wasi_errno_t path_unlink_file(__wasi_fd_t fd, const char *path) { return __wasi_path_unlink_file(fd, path); }
__wasi_errno_t poll_oneoff(const __wasi_subscription_t *in, __wasi_event_t *out, __wasi_size_t nsubscriptions, __wasi_size_t *retptr0) { return __wasi_poll_oneoff(in, out, nsubscriptions, retptr0); }
_Noreturn void proc_exit(__wasi_exitcode_t rval) { return __wasi_proc_exit(rval); }
__wasi_errno_t random_get(uint8_t *buf, __wasi_size_t buf_len) { return __wasi_random_get(buf, buf_len); }
