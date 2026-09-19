/* libuv_sizes: prints the size in bytes of the libuv structures that row 7 of the table in
 * docs/decisions/0003-speed-sources.md cites, for the target it was built for.
 *
 * Built by `zig build bench-competitors` against the headers of the libuv pinned in
 * build.zig.zon. It calls nothing in libuv, so it links libc alone.
 */
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>

int main(void) {
  /* uv_write_t and uv_fs_t are the per-operation requests; uv_tcp_t is the per-socket handle. */
  if (printf("uv_write_t %zu\nuv_fs_t %zu\nuv_tcp_t %zu\n", sizeof(uv_write_t), sizeof(uv_fs_t),
             sizeof(uv_tcp_t)) < 0) {
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
