// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Every job, in the order of docs/PLAN.md.

const harness = @import("harness.zig");

pub const all = [_]*const harness.Job{
    &@import("jobs/data/d1_sum.zig").job,
};

test {
    _ = @import("jobs/data/d1_sum.zig");
}
