//! What the benchmark harness measures and reports with. The workloads and the candidates they run
//! against come later and build on these files:
//!
//! - `histogram`: the bounded latency histogram of one worker thread, and its percentiles.
//! - `machine`: the record of the machine a run was made on, with `machine_proc`, the parsers of
//!   the Linux text files it reads.
//! - `series`: the several runs of one candidate on one workload, the median and spread they
//!   make, and the mark for a row whose runs disagree too much to decide anything.
//! - `report`: one result of one run and how it prints, with `report_comparison`, the table that
//!   sets several candidates against rotor and marks the rows rotor loses, and `report_parse`,
//!   which reads a result back from the line a candidate in its own process printed.
//! - `clock`: the monotonic clock every benchmark reads, so two spans are comparable.
//! - `load`: the machine's load average, and the window of it a series was taken inside, so a row
//!   spoiled by other work arriving says so instead of leaving it to the spread.
//! - `percentile`: the nearest-rank percentile of an exactly kept sample, which five bench programs
//!   each carried a copy of.
//! - `candidates`: starting a candidate's program and reading back the line it printed, which
//!   the workloads that measure themselves all share.
//! - `text`: the fixed-buffer string and the Markdown and JSON text rules the renderers share.
//! - `random`: the seeded generator the tests draw from, a copy of src/core/random.zig.
pub const histogram = @import("histogram.zig");
pub const series = @import("series.zig");
pub const machine = @import("machine.zig");
pub const machine_block = @import("machine_block.zig");
pub const machine_proc = @import("machine_proc.zig");
pub const report = @import("report.zig");
pub const report_comparison = @import("report_comparison.zig");
pub const report_parse = @import("report_parse.zig");
pub const clock = @import("clock.zig");
pub const other_work = @import("other_work.zig");
pub const percentile = @import("percentile.zig");
pub const candidates = @import("candidates.zig");
pub const text = @import("text.zig");
pub const random = @import("random.zig");
pub const placement = @import("placement.zig");

pub const Histogram = histogram.Histogram;
pub const Machine = machine.Machine;
pub const Result = report.Result;
pub const Placement = placement.Placement;

test {
    _ = histogram;
    _ = @import("histogram_test.zig");
    _ = machine;
    _ = machine_block;
    _ = machine_proc;
    _ = report;
    _ = report_comparison;
    _ = report_parse;
    _ = series;
    _ = clock;
    _ = other_work;
    _ = percentile;
    _ = candidates;
    _ = text;
    _ = random;
    _ = placement;
}
