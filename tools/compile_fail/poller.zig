//! A library's poller answers decision 26's `bool`. `zig build test-compile-fail` requires this
//! file to fail to compile: a poller returns a `rotor.WaitLimit` (decision 29).
const rotor = @import("rotor");

const Library = struct {
    poller: rotor.Poller = .init(Library, "poller", polled),

    fn polled(library: *Library) bool {
        _ = library;
        return false;
    }
};

test "a library's poller answers a bool" {
    var library: Library = .{};
    _ = &library;
}
