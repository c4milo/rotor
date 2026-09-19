//! The text rules the harness's records and renderers share: `Text`, a fixed buffer that holds one
//! short string the operating system reported, and the two ways a string leaves the harness, as a
//! Markdown table cell and as a JSON string. Nothing here allocates: every function writes to the
//! `std.Io.Writer` the caller backs with its own buffer.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// The most bytes one `Text` holds. The longest strings the harness stores are a CPU brand
/// string, 48 bytes on x86-64, and a kernel release, 64 bytes in Linux's `utsname`.
pub const text_bytes_max = 64;

/// The bytes a `Text` drops from both ends of what it is given.
const blank = " \t\r\n";

/// One short string in a fixed buffer, so a record that holds it needs no allocator and can be
/// copied as plain bytes. The empty text means the operating system reported nothing.
pub const Text = struct {
    bytes: [text_bytes_max]u8 = @splat(0),
    len: u8 = 0,

    comptime {
        assert(text_bytes_max <= std.math.maxInt(u8));
    }

    /// Stores `value` without the blanks at its ends. A value longer than the buffer is cut at
    /// `text_bytes_max`: the strings stored here are labels, and a cut label still names its
    /// machine.
    pub fn set(text: *Text, value: []const u8) void {
        const trimmed = std.mem.trim(u8, value, blank);
        const kept = trimmed[0..@min(trimmed.len, text_bytes_max)];
        @memcpy(text.bytes[0..kept.len], kept);
        text.len = @intCast(kept.len);
        assert(text.len <= text_bytes_max);
    }

    /// Stores `value` only when nothing is stored yet: the first of many equal lines wins.
    pub fn set_once(text: *Text, value: []const u8) void {
        if (text.len == 0) text.set(value);
    }

    /// The stored bytes, which live as long as the `Text` does.
    pub fn slice(text: *const Text) []const u8 {
        assert(text.len <= text_bytes_max);
        return text.bytes[0..text.len];
    }

    /// A `Text` that holds `value`, as `set` stores it.
    pub fn from(value: []const u8) Text {
        var text: Text = .{};
        text.set(value);
        return text;
    }
};

/// Writes `value` as the content of one Markdown table cell. A pipe would end the cell, so it is
/// escaped as `\|` (CLAUDE.md, Conventions). A line break would end the row, so it becomes a
/// space.
pub fn markdown_cell(writer: *Writer, value: []const u8) Writer.Error!void {
    for (value) |byte| {
        switch (byte) {
            '|' => try writer.writeAll("\\|"),
            '\n', '\r' => try writer.writeByte(' '),
            else => try writer.writeByte(byte),
        }
    }
}

/// Writes `value` as a JSON string, quotes included. The quote, the backslash and every control
/// byte are escaped; every other byte is written as it is, so UTF-8 stays UTF-8.
pub fn json_string(writer: *Writer, value: []const u8) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}

const testing = std.testing;

test "a text trims blanks, cuts at its limit and keeps the first value when asked to" {
    var text: Text = .{};
    try testing.expectEqualStrings("", text.slice());
    text.set("  Apple M1 Pro\t\n");
    try testing.expectEqualStrings("Apple M1 Pro", text.slice());
    text.set_once("another");
    try testing.expectEqualStrings("Apple M1 Pro", text.slice());

    text.set("x" ** (text_bytes_max + 9));
    try testing.expectEqual(text_bytes_max, text.slice().len);
    try testing.expectEqualStrings("x" ** text_bytes_max, text.slice());

    text.set("");
    try testing.expectEqualStrings("", text.slice());
    text.set_once("first");
    try testing.expectEqualStrings("first", Text.from(" first ").slice());
    try testing.expectEqualStrings("first", text.slice());
}

test "a Markdown cell escapes a pipe and flattens a line break" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try markdown_cell(&writer, "a|b\nc\rd, plain");
    try testing.expectEqualStrings("a\\|b c d, plain", writer.buffered());
}

test "a JSON string escapes the quote, the backslash and control bytes, and keeps UTF-8" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try json_string(&writer, "say \"hi\"\\ \n\x01 µs");
    try testing.expectEqualStrings("\"say \\\"hi\\\"\\\\ \\n\\u0001 µs\"", writer.buffered());
}

test "a full buffer is an error, never a cut line" {
    var buffer: [4]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, markdown_cell(&writer, "too long"));
    var second: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, json_string(&second, "too long"));
}
