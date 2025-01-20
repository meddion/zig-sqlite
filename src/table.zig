const std = @import("std");
const utils = @import("utils.zig");
const btree = @import("btree.zig");
const toKey = btree.toKey;

const assert = std.debug.assert;
const asBytes = std.mem.asBytes;
const bytesToValue = std.mem.bytesToValue;

const serialize = @import("utils.zig").serialize;
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const Row = @import("row.zig").Row;
const newMockRow = @import("row.zig").newMockRow;
const PageIndex = @import("pager.zig").Index;
const IndexedPage = @import("pager.zig").IndexedPage;

pub const DefaultTable = Table(Row, 100, 4096);

pub fn Table(comptime T: type, max_pages: comptime_int, page_size: comptime_int) type {
    return struct {
        alloc: std.mem.Allocator,
        pager: Pager(max_pages, page_size, null),
        root_page_idx: PageIndex,

        const Node = btree.Node(page_size);
        const InternalNode = btree.InternalNode(page_size);
        const LeafNode = btree.LeafNode(page_size);

        pub fn open(alloc: std.mem.Allocator, db_path: []const u8) !@This() {
            var table = @This(){
                .alloc = alloc,
                .pager = try Pager(max_pages, page_size, null).open(alloc, db_path),
                .root_page_idx = 0,
            };
            errdefer table.pager.close();

            // if (try table.pager.numPages() == 0) {
            //     // New empty table. Initialize the first page as a leaf node
            //     const indexed_page = try table.pager.nextEmptyPage();
            //     // _ = LeafNode.init(indexed_page.page, null);
            // }

            return table;
        }

        // leafNodeIdx returns idx of the leaf node which contains our key
        // TODO: impl
        fn leafNodeIdx(self: @This(), _: anytype) !PageIndex {
            return self.root_page_idx;
        }

        pub fn insertRow(self: *@This(), key: anytype, row: T) !void {
            const leaf_idx = try self.leafNodeIdx(key);

            const page = try self.pager.pageByIdx(leaf_idx);
            const indexed_page = IndexedPage{ .page = page, .idx = leaf_idx };

            var leaf_node = LeafNode._fromPageTODOrm(indexed_page);

            try leaf_node.insertNonFull(toKey(key), row);
        }

        pub fn iter(self: *@This()) Iter {
            return .{
                .pager = &self.pager,
                .page_idx = self.root_page_idx,
                .cell_idx = 0,
            };
        }

        pub const Iter = struct {
            pager: *Pager(max_pages, page_size, null),
            page_idx: PageIndex,
            cell_idx: PageIndex,

            pub fn next(self: *Iter) !?Row {
                const page = try self.pager.pageByIdx(self.page_idx);
                const indexed_page = IndexedPage{ .page = page, .idx = self.page_idx };

                const leaf_node = LeafNode._fromPageTODOrm(indexed_page);
                if (self.cell_idx >= leaf_node.header.cells_num) {
                    return null;
                }

                const row = leaf_node.cells[self.cell_idx].value;
                self.cell_idx += 1;

                return row;
            }
        };

        pub fn deinit(self: *@This()) void {
            self.pager.close();
        }
    };
}

// test Table {
//     const alloc = std.testing.allocator;
//     const file_path = try utils.randomStringWithPrefix(alloc, "/tmp/db-table-test-", 7);
//     defer alloc.free(file_path);
//     defer std.fs.cwd().deleteFile(file_path) catch @panic("could not delete file");

//     const rows = [_]Row{
//         newMockRow(1, "user1", "user1@mail.com"),
//         newMockRow(2, "user2", "user2@mail.com"),
//         newMockRow(4, "user4", "user4@mail.com"),
//     };

//     // Store
//     {
//         var table = try DefaultTable.open(alloc, file_path);
//         defer table.deinit();

//         for (rows, 0..) |row, i| {
//             try table.insertRow(i, row);
//         }

//         var iter = table.iter();
//         var i: u8 = 0;
//         while (try iter.next()) |row| {
//             try std.testing.expectEqual(rows[@intCast(i)], row);
//             i += 1;
//         }
//         try std.testing.expectEqual(rows.len, i);

//         for (rows, 0..) |row, j| {
//             // Write a duplicate
//             try std.testing.expectError(error.DuplicateKey, table.insertRow(j, row));
//         }
//     }
//     // Read from disk
//     {
//         var table = try DefaultTable.open(alloc, file_path);
//         defer table.deinit();

//         var iter = table.iter();
//         var i: u8 = 0;
//         while (try iter.next()) |row| {
//             try std.testing.expectEqual(rows[@intCast(i)], row);
//             i += 1;
//         }
//         try std.testing.expectEqual(rows.len, i);
//     }
// }

// test "Table at max capacity" {
//     const alloc = std.testing.allocator;
//     const file_path = try utils.randomStringWithPrefix(alloc, "/tmp/db-table-test-", 7);
//     defer alloc.free(file_path);
//     defer std.fs.cwd().deleteFile(file_path) catch @panic("could not delete file");

//     // Store max rows in one page
//     var table = try DefaultTable.open(alloc, file_path);
//     defer table.deinit();

//     const row = newMockRow(1, "user1", "user1@mail.com");

//     for (0..btree.NodeType.leaf.cellsMax(4096)) |i| {
//         try table.insertRow(i, row);
//     }

//     try table.insertRow(@as(u32, 49), row);
//     const page = try table.pager.pageByIdx(table.root_page_idx, false);
//     const indexed_page = IndexedPage{ .page = page, .idx = table.root_page_idx };
//     _ = btree.Node(4096).fromPage(indexed_page).internal;
// }
