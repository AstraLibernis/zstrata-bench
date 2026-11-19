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
    &@import("jobs/science/s1_stats.zig").job,
    &@import("jobs/science/s2_histogram.zig").job,
    &@import("jobs/science/s3_quantiles.zig").job,
    &@import("jobs/science/s4_correlation.zig").job,
    &@import("jobs/science/s5_distances.zig").job,
    &@import("jobs/science/s6_matmul.zig").job,
    &@import("jobs/model/m1_tree_histogram.zig").job,
    &@import("jobs/model/m2_split_scan.zig").job,
    &@import("jobs/model/m3_tree_inference.zig").job,
    &@import("jobs/model/m4_dense_forward.zig").job,
    &@import("jobs/model/m5_dense_update.zig").job,
    &@import("jobs/model/m6_adam_step.zig").job,
};

test {
    _ = @import("jobs/data/d1_sum.zig");
    _ = d2;
    _ = @import("jobs/data/d3_sort.zig");
    _ = d4;
    _ = @import("jobs/data/d5_join.zig");
    _ = @import("jobs/science/s1_stats.zig");
    _ = @import("jobs/science/s2_histogram.zig");
    _ = @import("jobs/science/s3_quantiles.zig");
    _ = @import("jobs/science/s4_correlation.zig");
    _ = @import("jobs/science/s5_distances.zig");
    _ = @import("jobs/science/s6_matmul.zig");
    _ = @import("jobs/model/m1_tree_histogram.zig");
    _ = @import("jobs/model/m2_split_scan.zig");
    _ = @import("jobs/model/m3_tree_inference.zig");
    _ = @import("jobs/model/m4_dense_forward.zig");
    _ = @import("jobs/model/m5_dense_update.zig");
    _ = @import("jobs/model/m6_adam_step.zig");
    _ = @import("kit/radix.zig");
    _ = @import("kit/table.zig");
}
