//! What the benchmark harness measures and reports with. The workloads and the candidates they run
//! against come later and build on these files:
//!
//! - `histogram`: the bounded latency histogram of one worker thread, and its percentiles.
//! - `machine`: the record of the machine a run was made on, with `machine_proc`, the parsers of
//!   the Linux text files it reads.
//! - `series`: the several runs of one candidate on one workload, the median and spread they
//!   make, and the mark for a row whose runs disagree too much to decide anything.
//! - `report`: one result of one run and how it prints, with `report_comparison`, the table that
//!   sets several candidates against rotor and marks the rows rotor loses.
//! - `text`: the fixed-buffer string and the Markdown and JSON text rules the renderers share.
//! - `random`: the seeded generator the tests draw from, a copy of src/core/random.zig.
pub const histogram = @import("histogram.zig");
pub const series = @import("series.zig");
pub const machine = @import("machine.zig");
pub const machine_proc = @import("machine_proc.zig");
pub const report = @import("report.zig");
pub const report_comparison = @import("report_comparison.zig");
pub const text = @import("text.zig");
pub const random = @import("random.zig");

pub const Histogram = histogram.Histogram;
pub const Machine = machine.Machine;
pub const Result = report.Result;

test {
    _ = histogram;
    _ = machine;
    _ = machine_proc;
    _ = report;
    _ = report_comparison;
    _ = series;
    _ = text;
    _ = random;
}
