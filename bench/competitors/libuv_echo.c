/* libuv_echo: a TCP echo server on 127.0.0.1, the libuv side of rotor's echo comparison.
 *
 * Run:  libuv_echo PORT        Stop it with SIGTERM or SIGINT.
 *
 * It is written the way that is fastest for libuv, so that no result of the harness comes from
 * this file:
 *
 * - One allocation per connection, made at accept, holding the handle, the write request and the
 *   read buffer together. Nothing is allocated per read or per write.
 * - `alloc_cb` hands back that connection's own buffer, which is what libuv's API asks for and
 *   what its own benchmarks do. libuv calls `malloc` itself only for a write of more than four
 *   buffers, and an echo writes one.
 * - `uv_try_write` is not used. It would win a syscall on the common case, and libuv's own echo
 *   server does not use it either; using it here would measure a program no libuv user writes.
 *
 * So a connection costs one read callback and one write per message, which is the shape row 2 of
 * the table in docs/decisions/0003-speed-sources.md records: libuv does not have multishot reads,
 * and a buffer belongs to a connection for as long as it is open.
 *
 * The listening line on standard output is the same one libxev_echo prints, because the harness
 * waits for it before it connects. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

/* The read buffer of one connection. libuv gives a read its buffer through `alloc_cb`, so the
 * buffer belongs to the connection for as long as it is open, and this is what that costs.
 * rotor's provided-buffer group is the thing this number is compared against. */
#define CONNECTION_BUFFER_BYTES (64 * 1024)

#define LISTEN_BACKLOG 1024

/* One connection: the handle, the one write request it reuses, and its buffer. One allocation. */
typedef struct {
    uv_tcp_t handle;
    uv_write_t write;
    /* The bytes the write in flight is sending, which is a slice of `buffer`. */
    uv_buf_t writing;
    char buffer[CONNECTION_BUFFER_BYTES];
} connection_t;

static void on_close(uv_handle_t *handle)
{
    free(handle->data);
}

static void close_connection(connection_t *connection)
{
    uv_handle_t *handle = (uv_handle_t *)&connection->handle;
    if (uv_is_closing(handle)) {
        return;
    }
    handle->data = connection;
    uv_close(handle, on_close);
}

/* libuv asks the caller for a buffer before every read. The connection owns one and hands back
 * the whole of it: the read is the only operation in flight on it. */
static void on_alloc(uv_handle_t *handle, size_t suggested, uv_buf_t *buffer)
{
    connection_t *connection = (connection_t *)handle;
    (void)suggested;
    buffer->base = connection->buffer;
    buffer->len = sizeof(connection->buffer);
}

static void on_read(uv_stream_t *stream, ssize_t count, const uv_buf_t *buffer);

static void on_write(uv_write_t *request, int status)
{
    connection_t *connection = (connection_t *)request->handle;
    if (status < 0) {
        close_connection(connection);
        return;
    }
    /* The buffer is free again, so the next read may use it. */
    uv_read_start((uv_stream_t *)&connection->handle, on_alloc, on_read);
}

static void on_read(uv_stream_t *stream, ssize_t count, const uv_buf_t *buffer)
{
    connection_t *connection = (connection_t *)stream;
    (void)buffer;
    if (count < 0) {
        close_connection(connection);
        return;
    }
    if (count == 0) {
        return;
    }
    /* The buffer holds the bytes that must go back out, so reading stops until the write is
     * done with it. This is the cost rotor's provided buffers remove: libuv cannot read again
     * into a buffer it is still sending from. */
    uv_read_stop(stream);
    connection->writing = uv_buf_init(connection->buffer, (unsigned int)count);
    int failed = uv_write(&connection->write, stream, &connection->writing, 1, on_write);
    if (failed) {
        close_connection(connection);
    }
}

static void on_connection(uv_stream_t *listener, int status)
{
    if (status < 0) {
        return;
    }
    connection_t *connection = malloc(sizeof(*connection));
    if (connection == NULL) {
        return;
    }
    if (uv_tcp_init(listener->loop, &connection->handle)) {
        free(connection);
        return;
    }
    if (uv_accept(listener, (uv_stream_t *)&connection->handle)) {
        close_connection(connection);
        return;
    }
    uv_tcp_nodelay(&connection->handle, 1);
    uv_read_start((uv_stream_t *)&connection->handle, on_alloc, on_read);
}

/* The port named by `text`, or 0 when it is missing, not a number, or out of range. */
static unsigned short parse_port(const char *text)
{
    if (text == NULL) {
        return 0;
    }
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (end == text || *end != '\0' || value <= 0 || value > 65535) {
        return 0;
    }
    return (unsigned short)value;
}

int main(int argc, char **argv)
{
    unsigned short port = parse_port(argc > 1 ? argv[1] : NULL);
    if (port == 0) {
        fprintf(stderr, "usage: libuv_echo PORT\n");
        return 1;
    }

    uv_loop_t *loop = uv_default_loop();
    uv_tcp_t listener;
    if (uv_tcp_init(loop, &listener)) {
        return 1;
    }
    struct sockaddr_in address;
    if (uv_ip4_addr("127.0.0.1", port, &address)) {
        return 1;
    }
    if (uv_tcp_bind(&listener, (const struct sockaddr *)&address, 0)) {
        return 1;
    }
    if (uv_listen((uv_stream_t *)&listener, LISTEN_BACKLOG, on_connection)) {
        return 1;
    }

    /* The harness waits for this line before it connects. */
    printf("libuv_echo: libuv %s listening on 127.0.0.1:%u\n", uv_version_string(), port);
    fflush(stdout);

    return uv_run(loop, UV_RUN_DEFAULT);
}
