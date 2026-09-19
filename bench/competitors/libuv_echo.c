/* libuv_echo: a TCP echo server on 127.0.0.1, the libuv side of rotor's echo comparison.
 *
 * Run:  libuv_echo PORT        Stop it with SIGTERM or SIGINT.
 *
 * It is written the way that is fastest for libuv, so that no result of the harness comes from
 * this file. One read buffer serves every connection, so there is no malloc per read. A read is
 * echoed with uv_try_write, which is one write(2) and queues nothing. Only when the socket's send
 * buffer is full does the rest go through uv_write, in a copy, and the connection then reads
 * nothing more until that write ends, which bounds the copy to one read per connection.
 *
 * Built by `zig build bench-competitors` against the libuv pinned in build.zig.zon.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

/* The read size libuv itself suggests to the allocation callback (src/unix/stream.c:1049). */
#define ECHO_READ_BYTES (64 * 1024)
/* The backlog passed to listen(2). */
#define ECHO_BACKLOG 1024
/* The largest TCP port. */
#define ECHO_PORT_MAX 65535

/* The part of a read that uv_try_write could not send: the request, then a copy of the bytes. */
typedef struct {
  uv_write_t request;
  char bytes[];
} pending_write_t;

/* Safe to share: libuv calls on_read for a read before it asks for the next buffer. */
static char read_buffer[ECHO_READ_BYTES];

static void fail(const char *what, int status) {
  fprintf(stderr, "libuv_echo: %s: %s\n", what, uv_strerror(status));
  exit(EXIT_FAILURE);
}

static void on_close(uv_handle_t *handle) {
  free(handle);
}

/* uv_close aborts on a handle that is already closing, so every close goes through here. */
static void close_connection(uv_stream_t *stream) {
  if (!uv_is_closing((uv_handle_t *)stream)) uv_close((uv_handle_t *)stream, on_close);
}

static void on_alloc(uv_handle_t *handle, size_t suggested_bytes, uv_buf_t *buffer) {
  (void)handle;
  (void)suggested_bytes;
  *buffer = uv_buf_init(read_buffer, sizeof(read_buffer));
}

static void on_read(uv_stream_t *stream, ssize_t read_bytes, const uv_buf_t *buffer);

/* The queued rest of a read was sent, or failed: release the copy and read again. */
static void on_write(uv_write_t *request, int status) {
  uv_stream_t *stream = request->handle;
  free(request); /* pending_write_t starts with the request, so this frees the whole copy. */
  if (status < 0 || uv_read_start(stream, on_alloc, on_read) < 0) close_connection(stream);
}

/* The slow path: copy what uv_try_write left, queue it, and stop reading until it is sent. */
static void queue_rest(uv_stream_t *stream, const char *bytes, size_t rest_bytes) {
  pending_write_t *pending = malloc(sizeof(*pending) + rest_bytes);
  if (pending == NULL) {
    close_connection(stream);
    return;
  }
  memcpy(pending->bytes, bytes, rest_bytes);
  uv_buf_t rest = uv_buf_init(pending->bytes, (unsigned int)rest_bytes);
  if (uv_read_stop(stream) < 0 || uv_write(&pending->request, stream, &rest, 1, on_write) < 0) {
    free(pending);
    close_connection(stream);
  }
}

static void on_read(uv_stream_t *stream, ssize_t read_bytes, const uv_buf_t *buffer) {
  if (read_bytes == 0) return; /* EAGAIN: libuv reports it as a read of nothing. */
  if (read_bytes < 0) {        /* UV_EOF, or an error: either way the connection is over. */
    close_connection(stream);
    return;
  }
  uv_buf_t echo = uv_buf_init(buffer->base, (unsigned int)read_bytes);
  int written_bytes = uv_try_write(stream, &echo, 1);
  if (written_bytes == UV_EAGAIN) written_bytes = 0;
  if (written_bytes < 0) {
    close_connection(stream);
    return;
  }
  if (written_bytes < read_bytes) {
    queue_rest(stream, buffer->base + written_bytes, (size_t)(read_bytes - written_bytes));
  }
}

static void on_connection(uv_stream_t *server, int status) {
  if (status < 0) fail("accept", status);
  uv_tcp_t *connection = malloc(sizeof(*connection));
  if (connection == NULL) fail("malloc", UV_ENOMEM);
  status = uv_tcp_init(server->loop, connection);
  if (status < 0) fail("uv_tcp_init", status);
  uv_stream_t *stream = (uv_stream_t *)connection;
  /* TCP_NODELAY, as every candidate of the comparison sets it: an echo must not wait for Nagle. */
  if (uv_accept(server, stream) < 0 || uv_tcp_nodelay(connection, 1) < 0 ||
      uv_read_start(stream, on_alloc, on_read) < 0) {
    close_connection(stream);
  }
}

int main(int argc, char **argv) {
  char *end = NULL;
  long port = argc == 2 ? strtol(argv[1], &end, 10) : 0;
  if (argc != 2 || *end != '\0' || port < 1 || port > ECHO_PORT_MAX) {
    fprintf(stderr, "usage: libuv_echo PORT\n");
    return EXIT_FAILURE;
  }

  uv_loop_t *loop = uv_default_loop();
  uv_tcp_t server;
  struct sockaddr_in address;
  int status = uv_tcp_init(loop, &server);
  if (status < 0) fail("uv_tcp_init", status);
  status = uv_ip4_addr("127.0.0.1", (int)port, &address);
  if (status < 0) fail("uv_ip4_addr", status);
  status = uv_tcp_bind(&server, (const struct sockaddr *)&address, 0);
  if (status < 0) fail("uv_tcp_bind", status);
  status = uv_listen((uv_stream_t *)&server, ECHO_BACKLOG, on_connection);
  if (status < 0) fail("uv_listen", status);

  /* The harness waits for this line before it connects. */
  if (printf("libuv_echo: libuv %s listening on 127.0.0.1:%ld\n", uv_version_string(), port) < 0 ||
      fflush(stdout) != 0) {
    return EXIT_FAILURE;
  }
  /* uv_run returns nonzero when it stops with handles still active, which nothing here asks for. */
  return uv_run(loop, UV_RUN_DEFAULT) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
