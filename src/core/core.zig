//! The `core` module: the named limits and, once docs/decisions/ is accepted, the types every
//! backend shares. It imports nothing but std. No loop code exists yet: the decision records come
//! first (CLAUDE.md, Where the work stands).
pub const constants = @import("constants.zig");

test {
    _ = constants;
}
