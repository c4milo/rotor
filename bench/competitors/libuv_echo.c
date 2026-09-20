/* libuv_echo: a TCP echo server on 127.0.0.1, the libuv side of rotor's echo comparison.
 *
 * Run:  libuv_echo PORT [--buffers one|two]      Stop it with SIGTERM or SIGINT.
 *
 * It is written the way that is fastest for libuv, so that no result of the harness comes from
 * this file. What "fastest" means was an open question, so this program answers it: it holds both
 * candidate shapes and `--buffers` picks one, and bench/competitors/README.md records which won
 * and by how much.
 *
 *   - `one`: one buffer per connection. The echo write borrows it, so reading has to stop until
 *     that write ends. Costs a `uv_read_stop` and a `uv_read_start` per message, which may or may
 *     not reach the kernel, because libuv batches its watcher changes.
 *   - `two`: two buffers and two write requests per connection. A read is never stopped: the next
 *     read lands in the buffer the write in flight is not using. Costs twice the memory per
 *     connection.
 *
 * Neither shape allocates per message. libuv's own test/echo-server.c does: it calls `malloc` in
 * `alloc_cb` and frees after the write, which is a third shape and the slowest of the three, so
 * it is not offered here.
 *
 * `uv_try_write` is not used. It would win a syscall on the common case, and libuv's own echo
 * server does not use it, so using it here would measure a program no libuv user writes.
 *
 * The listening line on standard output is the one libxev_echo and rotor_echo print, because the
 * harness waits for it before it connects. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

/* The read buffer of one connection, which is libuv's own suggested size. libuv gives a read its
 * buffer through `alloc_cb`, so a buffer belongs to a connection for as long as it is open, and
 * this is what that costs. rotor's provided-buffer group is what this is compared against. */
#define CONNECTION_BUFFER_BYTES (64 * 1024)

#define LISTEN_BACKLOG 1024

/* Buffers a connection holds in the `two` shape. The `one` shape uses the first alone. */
#define BUFFERS_MAX 2

/* One connection. One allocation, whichever shape is running. */
typedef struct {
    uv_tcp_t handle;
    uv_write_t write[BUFFERS_MAX];
    uv_buf_t writing[BUFFERS_MAX];
    /* 1 while that buffer's write is in flight and the buffer may not be read into. */
    int busy[BUFFERS_MAX];
    /* The buffer `alloc_cb` hands out next, in the `two` shape. */
    int next;
    char buffer[BUFFERS_MAX][CONNECTION_BUFFER_BYTES];
} connection_t;

/* Buffers per connection: 1 or BUFFERS_MAX, from --buffers. */
static int buffers_per_connection = BUFFERS_MAX;

static void on_read(uv_stream_t *stream, ssize_t count, const uv_buf_t *buffer);

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

/* libuv asks the caller for a buffer before every read. A buffer whose write is still in flight
 * cannot be read into, so this hands back a free one. A zero-length buffer tells libuv there is
 * none, and it answers with UV_ENOBUFS, which `on_read` treats as a connection it cannot serve.
 * In the `two` shape that cannot happen while one message is in flight per connection. */
static void on_alloc(uv_handle_t *handle, size_t suggested, uv_buf_t *buffer)
{
    connection_t *connection = (connection_t *)handle;
    (void)suggested;
    for (int offset = 0; offset < buffers_per_connection; offset++) {
        int index = (connection->next + offset) % buffers_per_connection;
        if (!connection->busy[index]) {
            *buffer = uv_buf_init(connection->buffer[index], CONNECTION_BUFFER_BYTES);
            return;
        }
    }
    *buffer = uv_buf_init(NULL, 0);
}

/* Which of the connection's buffers `base` is, or -1. */
static int buffer_index_of(const connection_t *connection, const char *base)
{
    for (int index = 0; index < buffers_per_connection; index++) {
        if (connection->buffer[index] == base) {
            return index;
        }
    }
    return -1;
}

static void on_write(uv_write_t *request, int status)
{
    connection_t *connection = (connection_t *)request->handle;
    int index = (int)(request - connection->write);
    connection->busy[index] = 0;
    if (status < 0) {
        close_connection(connection);
        return;
    }
    /* The `one` shape stopped reading while the write borrowed the only buffer. The `two` shape
     * never stopped, so it has nothing to restart. */
    if (buffers_per_connection == 1) {
        uv_read_start((uv_stream_t *)&connection->handle, on_alloc, on_read);
    }
}

static void on_read(uv_stream_t *stream, ssize_t count, const uv_buf_t *buffer)
{
    connection_t *connection = (connection_t *)stream;
    if (count < 0) {
        close_connection(connection);
        return;
    }
    if (count == 0) {
        return;
    }
    int index = buffer_index_of(connection, buffer->base);
    if (index < 0) {
        close_connection(connection);
        return;
    }
    /* The bytes have to go back out of the buffer they arrived in, so that buffer is busy until
     * its write ends. With one buffer that means reading stops; with two it does not. */
    connection->busy[index] = 1;
    connection->next = (index + 1) % buffers_per_connection;
    if (buffers_per_connection == 1) {
        uv_read_stop(stream);
    }
    connection->writing[index] = uv_buf_init(connection->buffer[index], (unsigned int)count);
    int failed = uv_write(&connection->write[index], stream, &connection->writing[index], 1,
                          on_write);
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
    memset(connection->busy, 0, sizeof(connection->busy));
    connection->next = 0;
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

/* Reads --buffers. Returns 0 when an argument is not understood. */
static int parse_buffers(int argc, char **argv)
{
    for (int index = 2; index + 1 < argc; index += 2) {
        if (strcmp(argv[index], "--buffers") != 0) {
            return 0;
        }
        if (strcmp(argv[index + 1], "one") == 0) {
            buffers_per_connection = 1;
        } else if (strcmp(argv[index + 1], "two") == 0) {
            buffers_per_connection = BUFFERS_MAX;
        } else {
            return 0;
        }
    }
    return 1;
}

int main(int argc, char **argv)
{
    unsigned short port = parse_port(argc > 1 ? argv[1] : NULL);
    if (port == 0 || !parse_buffers(argc, argv)) {
        fprintf(stderr, "usage: libuv_echo PORT [--buffers one|two]\n");
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
    printf("libuv_echo: libuv %s, %d buffers per connection, listening on 127.0.0.1:%u\n",
           uv_version_string(), buffers_per_connection, port);
    fflush(stdout);

    return uv_run(loop, UV_RUN_DEFAULT);
}
