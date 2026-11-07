//! A library names a buffer group by a literal id, which could be another library's group.
//! `zig build test-compile-fail` requires this file to fail to compile: each call that names a
//! group takes a `rotor.BufferGroup`, which only `reserve_buffer_group` makes (decision 29).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    shared.release_buffers(1);
}

test "a library names a buffer group by a literal" {
    _ = &library;
}
