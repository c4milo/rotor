//! echo_client: one measurement of the echo workload against a server already listening, printed
//! as a Markdown row and a JSON line. `client.zig` holds the load generator; this file is the
//! command line around it, for a run made by hand. `echo_runner` is what a comparison uses.
//!
//! Run:  echo_client PORT [--connections N] [--payload BYTES] [--seconds S] [--warmup S]
//!                        [--candidate NAME] [--version TEXT]
const std = @import("std");
const harness = @import("harness");
const client = @import("client.zig");

const Options = client.Options;
const Result = harness.report.Result;

const output_buffer_bytes = 4096;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    const result = try client.run(options);

    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll(harness.report.markdown_header);
    try result.render_markdown_row(writer);
    try writer.writeByte('\n');
    try result.render_json_line(writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    var options: Options = .{ .port = try std.fmt.parseInt(u16, arguments[1], 10) };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.connections == 0 or options.payload_bytes == 0) return error.EmptyConfiguration;
    return options;
}

/// The numbers. Split from the names so each stays inside the complexity limit.
fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--connections")) {
        options.connections = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--payload")) {
        options.payload_bytes = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup_seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--cpu")) {
        options.cpu = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, name, "--cores")) {
        options.cores = try std.fmt.parseInt(u32, value, 10);
    } else {
        try apply_text(options, name, value);
    }
}

/// The ones that are text, which a report carries as it was given them.
fn apply_text(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--candidate")) {
        options.candidate = value;
    } else if (std.mem.eql(u8, name, "--version")) {
        options.version = value;
    } else {
        return error.UnknownArgument;
    }
}
