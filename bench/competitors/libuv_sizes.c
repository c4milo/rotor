/* libuv_sizes: prints the size and alignment in bytes of the libuv structures row 7 of the table
 * in docs/decisions/0003-speed-sources.md cites: the per-operation requests `uv_write_t` and
 * `uv_fs_t`, and the per-connection handle `uv_tcp_t`.
 *
 * Built by `zig build bench-competitors` against the libuv pinned in build.zig.zon. It calls
 * nothing in libuv, so it needs the headers alone and links no library.
 *
 * bench/competitors/README.md records what it printed on each target, and the Linux numbers there
 * were read from a cross-compile's assembly, because a Linux binary does not run on the
 * development machine. Running this on the `linux` machine is what confirms them. */
#include <stdalign.h>
#include <stddef.h>
#include <stdio.h>
#include <uv.h>

static void print_size(const char *name, size_t size, size_t alignment)
{
    printf("%s size %zu align %zu\n", name, size, alignment);
}

int main(void)
{
    print_size("uv_write_t", sizeof(uv_write_t), alignof(uv_write_t));
    print_size("uv_fs_t", sizeof(uv_fs_t), alignof(uv_fs_t));
    print_size("uv_tcp_t", sizeof(uv_tcp_t), alignof(uv_tcp_t));
    /* The loop itself is per thread and not per operation, so no row cites it. It is printed
     * because a reader comparing rotor's per-loop memory wants it beside the rest. */
    print_size("uv_loop_t", sizeof(uv_loop_t), alignof(uv_loop_t));
    return 0;
}
