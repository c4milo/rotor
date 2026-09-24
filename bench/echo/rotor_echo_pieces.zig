//! The pieces of one connection's stream that `rotor_echo` has received and not yet echoed, each
//! with the provided buffer it arrived in.
//!
//! A multishot receive from a group names one buffer per piece, and TCP can deliver the second
//! piece of a message before the send of the first has completed. Until 2026-09-24 the server kept
//! one send per connection, and the second piece overwrote the first: the first buffer was never
//! given back and the second was given back twice (`bench/alternatives/README.md`). Here each piece
//! keeps its own buffer and length until its bytes have all been sent.
//!
//! The pieces go out one send at a time, oldest first. A short send's rest has to go out before the
//! next piece. Two sends on one socket in flight at once can also put their bytes on the stream in
//! the wrong order: kqueue and epoll try a new send at once even while an older one waits for room,
//! and io_uring orders two requests only when they are linked.
//!
//! Split from `rotor_echo.zig` on 2026-09-24, when the fix passed that file's 500 lines.
const std = @import("std");
const assert = std.debug.assert;

/// Pieces one connection holds at once. The harness's client keeps one message in flight per
/// connection, so a connection holds the pieces of one message at most. The largest message,
/// 64 KiB, cut into the smallest buffer `rotor_echo` takes, 2 KiB, is 32 pieces, and every place
/// TCP split the message can end a piece early and add one more. Twice 32 leaves room for those
/// splits. `rotor_echo.zig` asserts that this holds for its own limits.
pub const pieces_max = 64;

/// One piece: the provided buffer it arrived in and how many bytes of it arrived. 8 bytes, 4-byte
/// aligned.
pub const Piece = struct {
    len: u32,
    buffer_id: u16,
};

/// A connection's pieces, oldest first, in a ring. Whenever the ring holds a piece, the send of the
/// oldest one is in flight, and no other send is.
pub const Pieces = struct {
    ring: [pieces_max]Piece,
    /// Bytes of the oldest piece already sent.
    sent: u32,
    /// Where the oldest piece is in `ring`.
    first: u8,
    /// Pieces held.
    count: u8,

    pub const empty: Pieces = .{ .ring = undefined, .sent = 0, .first = 0, .count = 0 };

    /// True when the ring holds `pieces_max` pieces and takes no more.
    pub fn full(pieces: *const Pieces) bool {
        assert(pieces.count <= pieces_max);
        return pieces.count == pieces_max;
    }

    /// Holds `piece` behind the others, in a ring that is not full. True when it is the only one,
    /// and so the caller starts its send; a piece behind another waits for that one's bytes to go.
    pub fn push(pieces: *Pieces, piece: Piece) bool {
        assert(piece.len > 0);
        assert(!pieces.full());
        pieces.ring[(pieces.first + pieces.count) % pieces_max] = piece;
        pieces.count += 1;
        return pieces.count == 1;
    }

    /// The oldest piece, whose send is in flight.
    pub fn oldest(pieces: *const Pieces) Piece {
        assert(pieces.count > 0);
        const piece = pieces.ring[pieces.first];
        assert(pieces.sent < piece.len);
        return piece;
    }

    /// Records that the send of the oldest piece moved `bytes`. Returns that piece, taken off,
    /// when all of it has gone, so its buffer is the caller's to give back. Returns null when some
    /// of it is still to send.
    pub fn advance(pieces: *Pieces, bytes: u32) ?Piece {
        const piece = pieces.oldest();
        assert(bytes <= piece.len - pieces.sent);
        pieces.sent += bytes;
        if (pieces.sent < piece.len) return null;
        return pieces.pop();
    }

    /// Takes the oldest piece off whether or not it was sent, or returns null when none is left:
    /// for a connection that is closing, which gives every buffer back.
    pub fn pop(pieces: *Pieces) ?Piece {
        if (pieces.count == 0) return null;
        const piece = pieces.ring[pieces.first];
        pieces.first = @intCast((pieces.first + 1) % pieces_max);
        pieces.count -= 1;
        pieces.sent = 0;
        return piece;
    }
};

comptime {
    assert(@sizeOf(Piece) == 8);
    assert(@alignOf(Piece) == 4);
    // `first` and `count` are u8: the ring's positions and its count have to fit.
    assert(pieces_max <= std.math.maxInt(u8));
}

const testing = std.testing;

test "a second piece waits for the first, and each piece gives back its own buffer once" {
    var pieces: Pieces = .empty;
    // The first piece starts its send; the second arrives while that send is in flight.
    try testing.expect(pieces.push(.{ .len = 65483, .buffer_id = 15 }));
    try testing.expect(!pieces.push(.{ .len = 53, .buffer_id = 16 }));
    try testing.expectEqual(@as(u16, 15), pieces.oldest().buffer_id);

    // The first send completes whole: its own buffer comes back, and the second piece is next.
    const first = pieces.advance(65483) orelse return error.PieceNotDone;
    try testing.expectEqual(@as(u16, 15), first.buffer_id);
    try testing.expectEqual(Piece{ .len = 53, .buffer_id = 16 }, pieces.oldest());
    try testing.expectEqual(@as(u32, 0), pieces.sent);

    const second = pieces.advance(53) orelse return error.PieceNotDone;
    try testing.expectEqual(@as(u16, 16), second.buffer_id);
    try testing.expectEqual(@as(?Piece, null), pieces.pop());
}

test "a short send keeps its piece first until the rest has gone" {
    var pieces: Pieces = .empty;
    _ = pieces.push(.{ .len = 4096, .buffer_id = 3 });
    _ = pieces.push(.{ .len = 100, .buffer_id = 4 });

    // Two short sends: the piece stays first, and what is left of it is what goes next.
    try testing.expectEqual(@as(?Piece, null), pieces.advance(1000));
    try testing.expectEqual(@as(?Piece, null), pieces.advance(3000));
    try testing.expectEqual(@as(u16, 3), pieces.oldest().buffer_id);
    try testing.expectEqual(@as(u32, 4000), pieces.sent);

    const done = pieces.advance(96) orelse return error.PieceNotDone;
    try testing.expectEqual(@as(u16, 3), done.buffer_id);
    // The next piece starts from its first byte.
    try testing.expectEqual(@as(u32, 0), pieces.sent);
    try testing.expectEqual(@as(u16, 4), pieces.oldest().buffer_id);
}

test "a ring is full at its bound, and a closing connection gets every buffer back in order" {
    var pieces: Pieces = .empty;
    // Past the end of the ring, so the positions wrap.
    for (0..pieces_max / 2) |index| {
        _ = pieces.push(.{ .len = 1, .buffer_id = @intCast(index) });
        _ = pieces.advance(1) orelse return error.PieceNotDone;
    }
    for (0..pieces_max) |index| {
        try testing.expect(!pieces.full());
        const alone = pieces.push(.{ .len = 10, .buffer_id = @intCast(100 + index) });
        try testing.expectEqual(index == 0, alone);
    }
    try testing.expect(pieces.full());

    try testing.expectEqual(@as(?Piece, null), pieces.advance(4));
    for (0..pieces_max) |index| {
        const piece = pieces.pop() orelse return error.PieceMissing;
        try testing.expectEqual(@as(u16, @intCast(100 + index)), piece.buffer_id);
        // A piece taken off part sent leaves nothing behind for the next.
        try testing.expectEqual(@as(u32, 0), pieces.sent);
    }
    try testing.expectEqual(@as(?Piece, null), pieces.pop());
}
