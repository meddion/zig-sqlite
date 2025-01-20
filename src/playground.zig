const std = @import("std");
const debug = std.log.debug;
const print = std.debug.print;
const t = @import("table.zig");
const btree = @import("btree.zig");
const utils = @import("utils.zig");
const TreePager = btree.TreePager;
const Tree = btree.Tree;
const toKey = btree.toKey;
const newMockRow = @import("row.zig").newMockRow;

pub fn main() !void {
    const page_size = std.mem.page_size;
    std.debug.print("OS Page Size: {} bytes\n", .{page_size});
}
