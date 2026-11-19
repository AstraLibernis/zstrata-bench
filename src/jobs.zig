// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Every job, in the order of docs/PLAN.md.

const harness = @import("harness.zig");
const d2 = @import("jobs/data/d2_filter.zig");
const d4 = @import("jobs/data/d4_group.zig");

pub const all = [_]*const harness.Job{
    &@import("jobs/data/d1_sum.zig").job,
    &d2.half,
    &d2.sparse,
    &@import("jobs/data/d3_sort.zig").job,
    &d4.few,
    &d4.many,
    &d4.huge,
    &@import("jobs/data/d5_join.zig").job,
};

test {
    _ = @import("jobs/data/d1_sum.zig");
    _ = d2;
    _ = @import("jobs/data/d3_sort.zig");
    _ = d4;
    _ = @import("jobs/data/d5_join.zig");
    _ = @import("kit/radix.zig");
    _ = @import("kit/table.zig");
}
