const std = @import("std");
const rand = std.crypto.random;

const utils = @import("utils.zig");
const assert = std.debug.assert;
const Row = @import("row.zig").Row;
const newMockRow = @import("row.zig").newMockRow;
const serialize = @import("utils.zig").serialize;

const PageIndex = @import("pager.zig").Index;
const PageErrors = @import("pager.zig").PageErrors;

pub const page_alignment = @max(@alignOf(InternalHeader), @alignOf(LeafHeader), @alignOf(InternalCell), @alignOf(LeafCell));

pub fn TreePager(max_pages: comptime_int, page_size: comptime_int) type {
    return @import("pager.zig").Pager(max_pages, page_size, page_alignment);
}

pub fn Tree(
    max_pages: comptime_int,
    page_size: comptime_int,
    comptime _int_cells_max: ?u32,
    comptime _leaf_cells_max: ?u32,
) type {
    const Pager = TreePager(max_pages, page_size);
    const Page = Pager.Page;

    const DeleteErrors = error{KeyNotFound};

    return struct {
        root: Node,
        root_idx: PageIndex,
        pager: *Pager,

        const Self = @This();

        // TempPager used in tests
        const TempPager = @import("pager.zig").TempPager(Pager);
        const int_cells_max = _int_cells_max orelse cellsMax(NodeType.internal, page_size);
        const leaf_cells_max = _leaf_cells_max orelse cellsMax(NodeType.leaf, page_size);

        // Every node other than the root must have at least this number of keys
        const int_cells_min = int_cells_max / 2;
        const leaf_cells_min = leaf_cells_max / 2;

        comptime {
            // TODO: add helpful messages instead of these
            assert(int_cells_min > 1);
            assert(leaf_cells_min > 1);
            assert(int_cells_max > 3);
            assert(leaf_cells_max > 3);

            assert(page_size >= pageSizeFromCells(NodeType.internal, int_cells_max));
            assert(page_size >= pageSizeFromCells(NodeType.leaf, leaf_cells_max));
        }

        // new creates a new tree. User must close the pager.
        pub fn new(pager: *Pager) !Self {
            // Initialize the first empty page as a leaf node
            const indexed_page = try pager.nextEmptyPage();
            return .{
                .root = LeafNode.init(indexed_page.page).asNode(),
                .root_idx = indexed_page.idx,
                .pager = pager,
            };
        }

        // init initializes a tree from a given page
        // or creates a new tree if the pages has no pages allocated. User must close the pager.
        pub fn init(pager: *Pager, page_idx: PageIndex) !Self {
            if (try pager.numPages() == 0) {
                const page = try pager.pageByIdx(page_idx);

                return .{
                    .root = LeafNode.init(page, null).asNode(),
                    .root_idx = page_idx,
                    .pager = pager,
                };
            }

            const page = try pager.pageByIdx(page_idx);
            return .{ .root = Node.fromPage(page), .root_idx = page_idx, .pager = pager };
        }

        pub fn insert(self: *Self, key: Key, value: Value) !void {
            // Split the root: the only way the three grows in height
            if (self.root.isFull()) {
                const indexed_page = try self.pager.nextEmptyPage();
                var new_root = try InternalNode.init(
                    indexed_page.page,
                    &[1]InternalCell{.{
                        .child_idx = self.root_idx,
                        .key = undefined,
                    }},
                );
                try new_root.splitChild(self.pager, 0);
                try new_root.insertNonFull(self.pager, key, value);

                self.root = new_root.asNode();
                self.root_idx = indexed_page.idx;

                return;
            }

            try self.root.insertNonFull(self.pager, key, value);
        }

        pub fn print(self: Self, writer: std.io.AnyWriter) !void {
            if (self.root.cellsNum() == 0) {
                try writer.print("(empty tree)", .{});
                return;
            }

            var buf: [1024]u8 = undefined; // Or depth 512 max
            try self.root.print(self.pager, writer, &buf, 0);
        }

        fn expectTreeEqual(self: Self, alloc: std.mem.Allocator, expTreeStr: []const u8) !void {
            var list = std.ArrayList(u8).init(alloc);
            defer list.deinit();

            try self.print(list.writer().any());
            try std.testing.expectEqualStrings(expTreeStr, list.items);
        }

        pub fn exists(self: Self, key: Key) !bool {
            var node = self.root;

            while (true) {
                node = switch (node) {
                    .leaf => |leaf| {
                        const key_pos = leaf.keyPos(key);
                        if (key_pos == leaf.header.cells_num or keyCompare(key, leaf.cells[key_pos].key) != .eq)
                            return false;

                        return true;
                    },
                    .internal => |int| try int.child(self.pager, int.keyPos(key)),
                };
            }
        }

        pub fn delete(self: *Self, key: Key) !void {
            if (self.root == .leaf) {
                try self.root.leaf.delete(key);
                return;
            }

            var parent = self.root.internal;

            while (true) {
                const key_pos = parent.keyPos(key);
                var node_child = try parent.child(self.pager, key_pos);

                switch (node_child) {
                    .leaf => |*leaf_child| {
                        try leaf_child.delete(key);
                        // Return if the leaf node remains at least half full after deletion
                        if (leaf_child.header.cells_num >= leaf_cells_min) {
                            return;
                        }

                        try parent.handleUnderflow(self.pager, key_pos);

                        if (parent.header.cells_num == 1) {
                            self.root = leaf_child.asNode();
                        }

                        return;
                    },
                    .internal => |*int_child| {
                        if (int_child.header.cells_num < int_cells_min + 1) {
                            // Internal node in recursion path has only int_cells_min keys
                            try parent.handleUnderflow(self.pager, key_pos);
                        }

                        if (parent.header.cells_num == 1) {
                            self.root = int_child.asNode();
                        }

                        parent = int_child.*;
                    },
                }
            }
        }

        pub fn getValue(self: Self, key: Key) !?Value {
            var node = self.root;

            while (true) {
                switch (node) {
                    .leaf => |leaf| {
                        const key_pos = leaf.keyPos(key);
                        if (key_pos == leaf.header.cells_num or keyCompare(key, leaf.cells[key_pos].key) != .eq)
                            return null;

                        return leaf.cells[key_pos].value;
                    },
                    .internal => |int| {
                        const key_pos = int.keyPos(key);
                        const page = try self.pager.pageByIdx(int.cells[key_pos].child_idx);
                        node = Node.fromPage(page);
                    },
                }
            }
        }

        fn cellPtr(comptime node_type: NodeType, cells_max: comptime_int, page: Page) *[cells_max](if (node_type == .leaf) LeafCell else InternalCell) {
            const header_type = if (node_type == .leaf) LeafHeader else InternalHeader;
            const cell_type = if (node_type == .leaf) LeafCell else InternalCell;

            const base_ptr_int = @intFromPtr(page.ptr);
            const header_end = base_ptr_int + @sizeOf(header_type);

            const aligned_address = std.mem.alignForward(usize, header_end, @alignOf(cell_type));
            // Calculate the offset relative to the base pointer.
            const aligned_offset = aligned_address - base_ptr_int;

            return @ptrCast(@alignCast(page[aligned_offset..]));
        }

        const Node = union(NodeType) {
            internal: InternalNode,
            leaf: LeafNode,

            fn fromPage(page: Page) Node {
                const node_type: *NodeType = @ptrCast(@alignCast(page));

                return switch (node_type.*) {
                    .leaf => .{ .leaf = LeafNode.fromPage(page) },
                    .internal => .{ .internal = InternalNode.fromPage(page) },
                };
            }

            fn insertNonFull(self: *Node, pager: *Pager, key: Key, value: Value) !void {
                switch (self.*) {
                    .leaf => |*leaf| try leaf.insertNonFull(key, value),
                    .internal => |*int| try int.insertNonFull(pager, key, value),
                }
            }

            fn prepend(self: *Node, left: Node) void {
                const left_len = left.cellsNum();
                const right_len = self.cellsNum();

                switch (self.*) {
                    .leaf => |*right| {
                        assert(left == .leaf);
                        assert(left_len + left_len <= leaf_cells_max);
                        @memcpy(right.cells[left_len..][0..right_len], right.cells[0..right_len]);
                        @memcpy(right.cells[0..left_len], left.leaf.cells[0..left_len]);
                    },
                    .internal => |*right| {
                        assert(left == .internal);
                        assert(left_len + right_len <= int_cells_max);
                        @memcpy(right.cells[left_len..][0..right_len], right.cells[0..right_len]);
                        @memcpy(right.cells[0..left_len], left.internal.cells[0..left_len]);
                    },
                }

                self.commonHeader().cells_num += left_len;
            }

            fn append(self: *Node, right: Node) void {
                const left_len = self.cellsNum();
                const right_len = right.cellsNum();

                switch (self.*) {
                    .leaf => |*left| {
                        assert(right == .leaf);
                        assert(left_len + left_len <= leaf_cells_max);
                        @memcpy(left.cells[left_len..][0..right_len], right.leaf.cells[0..right_len]);
                    },
                    .internal => |*left| {
                        assert(right == .internal);
                        assert(left_len + right_len <= int_cells_max);
                        @memcpy(left.cells[left_len..][0..right_len], right.internal.cells[0..right_len]);
                    },
                }

                self.commonHeader().cells_num += right_len;
            }

            fn commonHeader(self: *Node) *CommonHeader {
                return switch (self.*) {
                    .leaf => |*leaf| leaf.header,
                    .internal => |*int| int.header,
                };
            }

            fn deleteAt(self: *Node, key_pos: u32) void {
                switch (self.*) {
                    .leaf => |*leaf| leaf.deleteAt(key_pos),
                    .internal => |*int| int.deleteAt(key_pos),
                }
            }

            fn keyAtPos(self: Node, key_pos: u32) Key {
                return switch (self) {
                    .leaf => |n| n.cells[key_pos].key,
                    .internal => |n| n.cells[key_pos].key,
                };
            }

            fn lastKey(self: Node) Key {
                return switch (self) {
                    .leaf => |n| n.lastKey(),
                    .internal => |n| n.lastKey(),
                };
            }

            fn isFull(self: Node) bool {
                return switch (self) {
                    .leaf => |leaf| leaf.header.cells_num == leaf_cells_max,
                    .internal => |int| int.header.cells_num == int_cells_max,
                };
            }

            fn cellsNum(self: Node) u32 {
                return switch (self) {
                    .leaf => |leaf| leaf.header.cells_num,
                    .internal => |int| int.header.cells_num,
                };
            }

            fn print(self: Node, pager: *Pager, writer: std.io.AnyWriter, scratch: []u8, depth: u32) !void {
                @memset(scratch[0 .. depth * 2], ' ');
                const indent = scratch[0 .. depth * 2];

                switch (self) {
                    .leaf => |leaf| {
                        for (leaf.cells[0..leaf.header.cells_num]) |cell| {
                            try writer.print("{s} ({any}, {any})\n", .{ indent, cell.key, cell.value });
                        }
                    },
                    .internal => |int| {
                        for (0..int.header.cells_num) |i| {
                            const cell = int.cells[i];

                            if (i == int.header.cells_num - 1) {
                                try writer.print("{s} k <= ∞\n", .{indent});
                            } else {
                                try writer.print("{s} k <= {any}\n", .{ indent, cell.key });
                            }

                            const child_page = try pager.pageByIdx(cell.child_idx);
                            const child_node = Node.fromPage(child_page);

                            try child_node.print(pager, writer, scratch, depth + 1);
                        }
                    },
                }
            }

            fn expectNodeEqual(self: Node, alloc: std.mem.Allocator, pager: *Pager, expTreeStr: []const u8) !void {
                var list = std.ArrayList(u8).init(alloc);
                defer list.deinit();

                var buf: [1024]u8 = undefined;
                try self.print(pager, list.writer().any(), &buf, 0);
                try std.testing.expectEqualStrings(expTreeStr, list.items);
            }
        };

        const InternalNode = struct {
            header: *InternalHeader,
            cells: *[int_cells_max]InternalCell,

            // NOTE: cells must be in the right order
            fn init(page: Page, cells: []const InternalCell) !InternalNode {
                assert(page.len >= page_size);
                assert(cells.len != 0);

                const h = newInternalHeader(@intCast(cells.len));
                assert(serialize(&h, page) > 0);
                const node = fromPage(page);
                @memcpy(node.cells[0..cells.len], cells);

                return node;
            }

            // fromPage references the page and interprets it as node,
            // thus any changes to value of the header or cells will be written to the page
            fn fromPage(page: Page) InternalNode {
                return .{
                    .header = @alignCast(std.mem.bytesAsValue(InternalHeader, page)),
                    .cells = cellPtr(NodeType.internal, int_cells_max, page),
                };
            }

            fn newInternalHeader(cells_num: PageIndex) InternalHeader {
                return .{
                    .node_type = .internal,
                    .cells_num = cells_num,
                };
            }

            fn lastKey(self: InternalNode) Key {
                return self.cells[self.header.cells_num - 1].key;
            }

            fn child(self: InternalNode, pager: *Pager, child_pos: u32) !Node {
                const page = try pager.pageByIdx(self.cells[child_pos].child_idx);
                return Node.fromPage(page);
            }

            fn rightChildSibling(self: *InternalNode, pager: *Pager, child_pos: u32) !Node {
                assert(child_pos < self.header.cells_num);
                if (child_pos + 1 >= self.header.cells_num) return error.NotFound;

                return (try self.child(pager, child_pos + 1));
            }

            fn leftChildSibling(self: *InternalNode, pager: *Pager, key_pos: u32) !Node {
                assert(key_pos < self.header.cells_num);
                if (key_pos == 0) return error.NotFound;

                return (try self.child(pager, key_pos - 1));
            }

            fn handleUnderflow(parent: *InternalNode, pager: *Pager, child_pos: u32) !void {
                // Else we either borrow a key from a sibling (transfer) or merge with a sibling
                if (!(try parent.transferFromRightSibling(pager, child_pos) or
                    try parent.transferFromLeftSibling(pager, child_pos) or
                    try parent.mergeWithRightSibling(pager, child_pos) or
                    try parent.mergeWithLeftSibling(pager, child_pos)))
                {
                    unreachable;
                }
            }

            fn transferFromRightSibling(parent: *InternalNode, pager: *Pager, child_pos: u32) !bool {
                var left_sibling = (try parent.child(pager, child_pos));
                var right_sibling = parent.rightChildSibling(pager, child_pos) catch return false;

                switch (left_sibling) {
                    .leaf => |*left| {
                        if (right_sibling.leaf.header.cells_num == leaf_cells_min)
                            return false; // Nothing to borrow

                        left.appendOne(right_sibling.leaf.cells[0]);
                    },
                    .internal => |*left| {
                        if (right_sibling.internal.header.cells_num == int_cells_min)
                            return false; // Nothing to borrow

                        left.appendOne(right_sibling.internal.cells[0]);
                    },
                }

                right_sibling.deleteAt(0);
                parent.cells[child_pos].key = left_sibling.lastKey();

                return true;
            }

            fn transferFromLeftSibling(parent: *InternalNode, pager: *Pager, child_pos: u32) !bool {
                var right_sibling = (try parent.child(pager, child_pos));
                var left_sibling = parent.leftChildSibling(pager, child_pos) catch return false;

                var left_header = left_sibling.commonHeader();
                const left_pos = left_header.cells_num - 1;

                switch (right_sibling) {
                    .leaf => |*right| {
                        if (left_sibling.leaf.header.cells_num == leaf_cells_min)
                            return false; // Nothing to borrow

                        right.insertAt(0, left_sibling.leaf.cells[left_pos]);
                    },
                    .internal => |*left| {
                        if (left_sibling.internal.header.cells_num == int_cells_min)
                            return false; // Nothing to borrow

                        left.insertAt(0, left_sibling.internal.cells[left_pos]);
                    },
                }

                left_header.cells_num -= 1; // or left_sibling.deleteAt(left_pos);
                parent.cells[child_pos - 1].key = left_sibling.lastKey();

                return true;
            }

            fn mergeWithRightSibling(parent: *InternalNode, pager: *Pager, child_pos: u32) !bool {
                var left_sibling = try parent.child(pager, child_pos);
                const right_sibling = parent.rightChildSibling(pager, child_pos) catch return false;

                switch (left_sibling) {
                    .leaf => assert(right_sibling.cellsNum() == leaf_cells_min),
                    .internal => {
                        assert(left_sibling.cellsNum() == int_cells_min);
                        assert(right_sibling.cellsNum() == int_cells_min);
                    },
                }

                // Copy cells from right sibling to left sibling
                const n = left_sibling.cellsNum();
                left_sibling.append(right_sibling);
                if (left_sibling == .internal) {
                    // The parent key becomes the right most key for the left sibling
                    left_sibling.internal.cells[n - 1].key = parent.cells[child_pos].key;
                }
                // Delete right sibling
                parent.cells[child_pos].key = left_sibling.lastKey();
                try pager.reclaimPage(parent.cells[child_pos + 1].child_idx);
                parent.deleteAt(child_pos + 1);

                return true;
            }

            fn mergeWithLeftSibling(parent: *InternalNode, pager: *Pager, child_pos: u32) !bool {
                var right_sibling = try parent.child(pager, child_pos);
                const left_sibling = parent.leftChildSibling(pager, child_pos) catch return false;

                switch (left_sibling) {
                    .leaf => assert(left_sibling.cellsNum() == leaf_cells_min),
                    .internal => {
                        assert(left_sibling.cellsNum() == int_cells_min);
                        assert(right_sibling.cellsNum() == int_cells_min);
                    },
                }

                // Copy cells from left sibling to right sibling
                right_sibling.prepend(left_sibling);

                // Delete left sibling
                try pager.reclaimPage(parent.cells[child_pos - 1].child_idx);
                parent.deleteAt(child_pos - 1);

                return true;
            }

            fn deleteAt(self: *InternalNode, key_pos: u32) void {
                assert(key_pos < self.header.cells_num);

                for (key_pos + 1..self.header.cells_num) |i| {
                    self.cells[i - 1] = self.cells[i];
                }

                self.header.cells_num -= 1;
            }

            fn insertNonFull(self: *InternalNode, pager: *Pager, key: Key, value: Value) InsertErrors!void {
                const key_pos = self.keyPos(key);
                var child_node = try self.childNode(pager, key_pos);

                if (child_node.isFull()) {
                    try self.splitChild(pager, key_pos);

                    if (keyCompare(key, self.cells[key_pos].key) == .gt) {
                        child_node = try self.childNode(pager, key_pos + 1);
                    }
                }

                try child_node.insertNonFull(pager, key, value);
            }

            // splitChild splits a child found at key_pos in cells into two by
            // creating another node and assigning the upper half of the child's cells
            //
            // Call scenario: we know that self.children[i] is at its maximum capacity, thus we need to split it
            // self is guaranteed to have enough capacity to insert another child by a key
            fn splitChild(self: *InternalNode, pager: *Pager, key_pos: u32) PageErrors!void {
                var left_child = try self.childNode(pager, key_pos);
                var left_child_header = left_child.commonHeader();

                const mid = left_child_header.cells_num / 2;

                self.cells[key_pos].key = left_child.keyAtPos(mid - 1);

                const indexed_page = try pager.nextEmptyPage();
                const right_child = switch (left_child) {
                    .leaf => |left_child_leaf| blk: {
                        const upper_cells = left_child_leaf.cells[mid..left_child_header.cells_num];

                        assert(left_child_header.cells_num == leaf_cells_max);
                        assert(upper_cells.len >= int_cells_min);

                        break :blk (try LeafNode.initWithCells(indexed_page.page, upper_cells)).asNode();
                    },

                    .internal => |left_child_int| blk: {
                        const upper_cells = left_child_int.cells[mid..left_child_header.cells_num];

                        assert(left_child_header.cells_num == int_cells_max);
                        assert(upper_cells.len >= int_cells_min);

                        break :blk (try InternalNode.init(indexed_page.page, upper_cells)).asNode();
                    },
                };

                // Shrink left child in half
                left_child_header.cells_num = mid;

                self.insertAt(key_pos + 1, InternalCell{
                    .key = right_child.lastKey(),
                    .child_idx = indexed_page.idx,
                });
            }

            fn asNode(self: InternalNode) Node {
                return .{ .internal = self };
            }

            fn keyPos(self: InternalNode, key: Key) u32 {
                assert(self.header.cells_num > 0);

                return binaryKeyPos(InternalCell, self.cells[0 .. self.header.cells_num - 1], key);
            }

            fn childNode(self: *InternalNode, pager: *Pager, key_pos: u32) !Node {
                const page = try pager.pageByIdx(self.cells[key_pos].child_idx);
                return Node.fromPage(page);
            }

            fn insertAt(self: *InternalNode, insert_pos: u32, new_cell: InternalCell) void {
                assert(self.header.cells_num != int_cells_max);

                var i = self.header.cells_num;
                while (i > insert_pos) : (i -= 1)
                    self.cells[i] = self.cells[i - 1];

                self.cells[insert_pos] = new_cell;
                self.header.cells_num += 1;
            }

            fn prependOne(self: *InternalNode, cell: InternalCell) void {
                self.insertAt(0, cell);
            }

            fn appendOne(self: *InternalNode, cell: InternalCell) void {
                self.cells[self.header.cells_num] = cell;
                self.header.cells_num += 1;
            }
        };

        const LeafNode = struct {
            header: *LeafHeader,
            cells: *[leaf_cells_max]LeafCell,

            fn init(page: Page) LeafNode {
                assert(page.len >= page_size);

                const h = newLeafHeader(0);
                assert(serialize(&h, page) > 0);

                return fromPage(page);
            }

            // initWithCells mem-copies the cells to the node.
            // NOTE: cells must be in the valid ordering.
            fn initWithCells(page: Page, cells: []const LeafCell) !LeafNode {
                var node = LeafNode.init(page);
                @memcpy(node.cells[0..cells.len], cells);
                node.header.cells_num = @intCast(cells.len);

                return node;
            }

            fn asNode(self: LeafNode) Node {
                return .{ .leaf = self };
            }

            fn lastKey(self: LeafNode) Key {
                return self.cells[self.header.cells_num - 1].key;
            }

            // fromPage references the page and interprets it as node,
            // thus any changes to value of the header or cells will be written to the page
            fn fromPage(page: Page) LeafNode {
                return .{
                    .header = @alignCast(std.mem.bytesAsValue(LeafHeader, page)),
                    .cells = cellPtr(NodeType.leaf, leaf_cells_max, page),
                };
            }

            fn insertNonFull(self: *LeafNode, key: Key, value: Value) InsertErrors!void {
                const new_cell = LeafCell{
                    .key = key,
                    .value = value,
                };
                const insert_pos = self.keyPos(new_cell.key);
                if (insert_pos < self.header.cells_num and keyCompare(key, self.cells[insert_pos].key) == .eq) {
                    return InsertErrors.DuplicateKey;
                }

                self.insertAt(insert_pos, new_cell);
            }

            fn insertAt(self: *LeafNode, insert_pos: u32, new_cell: LeafCell) void {
                assert(self.header.cells_num != leaf_cells_max);

                var i = self.header.cells_num;
                while (i > insert_pos) : (i -= 1)
                    self.cells[i] = self.cells[i - 1];

                self.cells[insert_pos] = new_cell;
                self.header.cells_num += 1;
            }

            fn appendOne(self: *LeafNode, cell: LeafCell) void {
                self.cells[self.header.cells_num] = cell;
                self.header.cells_num += 1;
            }

            fn delete(self: *LeafNode, key: Key) DeleteErrors!void {
                const key_pos = self.keyPos(key);
                if (key_pos == self.header.cells_num or keyCompare(key, self.cells[key_pos].key) != .eq)
                    return DeleteErrors.KeyNotFound;

                self.deleteAt(key_pos);
            }

            fn deleteAt(self: *LeafNode, key_pos: u32) void {
                assert(key_pos < self.header.cells_num);

                for (key_pos + 1..self.header.cells_num) |i| {
                    self.cells[i - 1] = self.cells[i];
                }

                self.header.cells_num -= 1;
            }

            fn keyPos(self: LeafNode, key: Key) u32 {
                return binaryKeyPos(LeafCell, self.cells[0..self.header.cells_num], key);
            }

            fn newLeafHeader(cells_num: PageIndex) LeafHeader {
                return .{
                    .node_type = .leaf,
                    .cells_num = cells_num,
                };
            }
        };
    };
}

test "InternalNode" {
    const alloc = std.testing.allocator;
    const TestTree = Tree(100, 4092, 4, 4);
    const InternalNode = TestTree.InternalNode;
    const LeafNode = TestTree.LeafNode;

    var temp_pager = try TestTree.TempPager.open(alloc);
    var pager_ptr = &temp_pager.pager;
    defer temp_pager.close();

    const left_child = try pager_ptr.nextEmptyPage();
    _ = try LeafNode.initWithCells(left_child.page, &[_]LeafCell{
        .{ .key = toKey(0), .value = newMockRow(5, "username", "user@mail.com") },
        .{ .key = toKey(3), .value = newMockRow(5, "username", "user@mail.com") },
        .{ .key = toKey(8), .value = newMockRow(5, "username", "user@mail.com") },
    });

    const right_child = try pager_ptr.nextEmptyPage();
    _ = try LeafNode.initWithCells(right_child.page, &[_]LeafCell{
        .{ .key = toKey(13), .value = newMockRow(5, "username", "user@mail.com") },
        .{ .key = toKey(15), .value = newMockRow(5, "username", "user@mail.com") },
        .{ .key = toKey(20), .value = newMockRow(5, "username", "user@mail.com") },
    });

    const root = try pager_ptr.nextEmptyPage();
    var root_node = try InternalNode.init(root.page, &[_]InternalCell{
        .{ .key = toKey(8), .child_idx = left_child.idx },
        .{ .key = undefined, .child_idx = right_child.idx },
    });

    try root_node.insertNonFull(pager_ptr, 10, newMockRow(5, "username", "user@mail.com"));
    try root_node.insertNonFull(pager_ptr, 26, newMockRow(5, "username", "user@mail.com"));
    try root_node.insertNonFull(pager_ptr, 12, newMockRow(5, "username", "user@mail.com"));

    try root_node.asNode().expectNodeEqual(alloc, pager_ptr,
        \\ k <= 8
        \\   (0, (5, username, user@mail.com))
        \\   (3, (5, username, user@mail.com))
        \\   (8, (5, username, user@mail.com))
        \\ k <= 13
        \\   (10, (5, username, user@mail.com))
        \\   (12, (5, username, user@mail.com))
        \\   (13, (5, username, user@mail.com))
        \\ k <= ∞
        \\   (15, (5, username, user@mail.com))
        \\   (20, (5, username, user@mail.com))
        \\   (26, (5, username, user@mail.com))
        \\
    );

    try std.testing.expectEqual(3, root_node.header.cells_num);
}

test "LeafNode" {
    const alloc = std.testing.allocator;
    const TestTree = Tree(100, 4092, 10, 10);
    const LeafNode = TestTree.LeafNode;
    const leaf_cells_max = TestTree.leaf_cells_max;

    var temp_pager = try TestTree.TempPager.open(alloc);
    defer temp_pager.close();

    const indexed_root_page = try temp_pager.pager.nextEmptyPage();

    var node = try LeafNode.initWithCells(indexed_root_page.page, &[_]LeafCell{
        .{ .key = toKey(0), .value = newMockRow(0, "user1", "person1@example.com") },
    });

    for (1..leaf_cells_max) |i| {
        const key = toKey(rand.int(u64));
        const value = newMockRow(@intCast(i), "user1", "person1@example.com");
        try node.insertNonFull(key, value);
        try std.testing.expectError(
            InsertErrors.DuplicateKey,
            node.insertNonFull(key, value),
        );
    }

    for (1..node.header.cells_num) |i| {
        try std.testing.expectEqual(.gt, keyCompare(node.cells[i].key, node.cells[i - 1].key));
    }

    try std.testing.expectEqual(leaf_cells_max, node.header.cells_num);
    try std.testing.expectEqual(node, LeafNode.fromPage(indexed_root_page.page));
}

test Tree {
    const max_pages = 100;
    const children_limit = 4;
    const TestTree = Tree(
        max_pages,
        4092,
        children_limit,
        children_limit,
    );

    const alloc = std.testing.allocator;

    var temp_pager = try TestTree.TempPager.open(alloc);
    defer temp_pager.close();

    var tree = try TestTree.new(&temp_pager.pager);
    try tree.expectTreeEqual(alloc, "(empty tree)");

    // Insertion
    {
        for (0..10) |i| {
            const key = toKey(i);
            const row = newMockRow(@intCast(i), "user", "user@mail.com");
            try tree.insert(key, row);
            try std.testing.expect(try tree.exists(key));
            try std.testing.expectEqual(try tree.getValue(key), row);
        }

        try std.testing.expect(!try tree.exists(toKey(101)));
        try tree.expectTreeEqual(alloc,
            \\ k <= 3
            \\   k <= 1
            \\     (0, (0, user, user@mail.com))
            \\     (1, (1, user, user@mail.com))
            \\   k <= ∞
            \\     (2, (2, user, user@mail.com))
            \\     (3, (3, user, user@mail.com))
            \\ k <= ∞
            \\   k <= 5
            \\     (4, (4, user, user@mail.com))
            \\     (5, (5, user, user@mail.com))
            \\   k <= ∞
            \\     (6, (6, user, user@mail.com))
            \\     (7, (7, user, user@mail.com))
            \\     (8, (8, user, user@mail.com))
            \\     (9, (9, user, user@mail.com))
            \\
        );
    }

    // Deletion
    {
        // Case 1: delete a leaf key with internal right-merge and tree height reduction preceding it
        try tree.delete(toKey(6));
        try tree.expectTreeEqual(alloc,
            \\ k <= 1
            \\   (0, (0, user, user@mail.com))
            \\   (1, (1, user, user@mail.com))
            \\ k <= 3
            \\   (2, (2, user, user@mail.com))
            \\   (3, (3, user, user@mail.com))
            \\ k <= 5
            \\   (4, (4, user, user@mail.com))
            \\   (5, (5, user, user@mail.com))
            \\ k <= ∞
            \\   (7, (7, user, user@mail.com))
            \\   (8, (8, user, user@mail.com))
            \\   (9, (9, user, user@mail.com))
            \\
        );

        // Case 2: delete a key with leaf right-merge
        try tree.delete(toKey(3));
        try tree.expectTreeEqual(alloc,
            \\ k <= 1
            \\   (0, (0, user, user@mail.com))
            \\   (1, (1, user, user@mail.com))
            \\ k <= 5
            \\   (2, (2, user, user@mail.com))
            \\   (4, (4, user, user@mail.com))
            \\   (5, (5, user, user@mail.com))
            \\ k <= ∞
            \\   (7, (7, user, user@mail.com))
            \\   (8, (8, user, user@mail.com))
            \\   (9, (9, user, user@mail.com))
            \\
        );

        // Case 3: delete a key with leaf right-transfer
        try tree.delete(toKey(0));
        try tree.expectTreeEqual(alloc,
            \\ k <= 2
            \\   (1, (1, user, user@mail.com))
            \\   (2, (2, user, user@mail.com))
            \\ k <= 5
            \\   (4, (4, user, user@mail.com))
            \\   (5, (5, user, user@mail.com))
            \\ k <= ∞
            \\   (7, (7, user, user@mail.com))
            \\   (8, (8, user, user@mail.com))
            \\   (9, (9, user, user@mail.com))
            \\
        );

        // Case 4: delete a key with leaf left-merge
        try tree.delete(toKey(7));
        try tree.delete(toKey(8));
        try tree.expectTreeEqual(alloc,
            \\ k <= 2
            \\   (1, (1, user, user@mail.com))
            \\   (2, (2, user, user@mail.com))
            \\ k <= ∞
            \\   (4, (4, user, user@mail.com))
            \\   (5, (5, user, user@mail.com))
            \\   (9, (9, user, user@mail.com))
            \\
        );

        // Case 5: delete a key with leaf left-transfer
        try tree.delete(toKey(4));
        try tree.insert(0, newMockRow(0, "user", "user@mail.com"));
        try tree.delete(toKey(5));
        try tree.expectTreeEqual(alloc,
            \\ k <= 1
            \\   (0, (0, user, user@mail.com))
            \\   (1, (1, user, user@mail.com))
            \\ k <= ∞
            \\   (2, (2, user, user@mail.com))
            \\   (9, (9, user, user@mail.com))
            \\
        );

        // Delete all
        // Case 6: root becomes a leaf node and then we empty it
        for ([_]u32{ 9, 2, 1, 0 }) |i| {
            try tree.delete(toKey(i));
        }
        try tree.expectTreeEqual(alloc, "(empty tree)");
        for (0..10) |i| try std.testing.expect(!try tree.exists(toKey(i)));
    }
}

test "Tree.random.deletes" {
    // This test case is designed to trigger all possible delete test cases
    inline for (4..10) |children_limit| {
        const max_pages = 150;
        const TestTree = Tree(
            max_pages,
            4096,
            children_limit,
            children_limit,
        );

        const alloc = std.testing.allocator;

        var temp_pager = try TestTree.TempPager.open(alloc);
        defer temp_pager.close();

        var tree = try TestTree.new(&temp_pager.pager);
        try tree.expectTreeEqual(alloc, "(empty tree)");

        var keys: [25 * children_limit]Key = undefined;
        for (0..25 * children_limit) |i| keys[i] = toKey(i);

        for (keys) |key| try tree.insert(key, Row{});

        var rand_gen = std.Random.DefaultPrng.init(children_limit);
        rand_gen.random().shuffle(Key, &keys);
        for (keys) |key| try tree.delete(key);
        try tree.expectTreeEqual(alloc, "(empty tree)");
    }
}

fn binaryKeyPos(comptime CellType: type, cells: []const CellType, key: Key) u32 {
    if (CellType != LeafCell and CellType != InternalCell)
        @compileError("unsupported CellType passed");

    if (cells.len == 0)
        return 0;

    var start: i32 = 0;
    var end: i32 = @intCast(cells.len - 1);

    while (start <= end) {
        const mid = @divFloor(start + end, 2);
        const cell = cells[@intCast(mid)];
        switch (keyCompare(key, cell.key)) {
            .eq => return @intCast(mid),
            .lt => {
                end = mid - 1;
            },
            .gt => {
                start = mid + 1;
            },
        }
    }

    return @intCast(start);
}

pub const InsertErrors = error{DuplicateKey} || PageErrors;

pub const Value = Row;
const LeafCell = struct {
    key: Key,
    value: Value,
};

const CommonHeader = extern struct {
    node_type: NodeType,
    cells_num: PageIndex = 0,
};

test CommonHeader {
    const h = CommonHeader{
        .node_type = .internal,
        .cells_num = 42,
    };

    const h_ptr = @as([*]const u8, @ptrCast(&h));
    try std.testing.expectEqual(h.node_type, @as(*const NodeType, @ptrCast(@alignCast(h_ptr))).*);
    try std.testing.expectEqual(h.cells_num, @as(*const PageIndex, @ptrCast(@alignCast(h_ptr + 4))).*);
}

// cellsMax returns how much cells (key-values) a given page size can house for a given node type
fn cellsMax(comptime node_type: NodeType, page_size: u32) u32 {
    const header_type = if (node_type == .leaf) LeafHeader else InternalHeader;
    const cell_type = if (node_type == .leaf) LeafCell else InternalCell;

    // Ensure the first Cell starts at a properly aligned offset
    const aligned_offset = std.mem.alignForward(u32, @sizeOf(header_type), @alignOf(cell_type));

    // Compute usable space after the aligned header
    const usable_space = page_size - aligned_offset;

    // Return maximum number of Cells that can fit
    return usable_space / @sizeOf(cell_type);
}

test pageSizeFromCells {
    try std.testing.expectEqual(312, pageSizeFromCells(NodeType.leaf, 1));
    try std.testing.expectEqual(3960, pageSizeFromCells(NodeType.leaf, 13));

    try std.testing.expectEqual(24, pageSizeFromCells(NodeType.internal, 1));
    try std.testing.expectEqual(216, pageSizeFromCells(NodeType.internal, 13));
}

// pageSizeFromCells returns the minimum page size required to store a given node
pub fn pageSizeFromCells(comptime node_type: NodeType, cells_num: u32) u32 {
    const header_type = if (node_type == .leaf) LeafHeader else InternalHeader;
    const cell_type = if (node_type == .leaf) LeafCell else InternalCell;
    const aligned_offset = std.mem.alignForward(u32, @sizeOf(header_type), @alignOf(cell_type));

    const page_size = cells_num * @sizeOf(cell_type) + aligned_offset;

    assert(cellsMax(node_type, page_size) == cells_num);

    return page_size;
}

test cellsMax {
    try std.testing.expectEqual(255, cellsMax(NodeType.internal, 4096));
    try std.testing.expectEqual(13, cellsMax(NodeType.leaf, 4096));
}

pub const NodeType = enum(u8) {
    internal,
    leaf,
};

const LeafHeader = CommonHeader;
const InternalHeader = CommonHeader;

pub const InternalCell = struct {
    child_idx: PageIndex,
    key: Key,
};

// pub const Key = [12]u8;
pub const Key = u64;

// const zero_key = [_]u8{0} ** @sizeOf(Key);
const zero_key = @as(Key, 0);
const native_endian = @import("builtin").target.cpu.arch.endian();

pub fn keyCompare(key_lf: Key, key_rt: Key) std.math.Order {
    return switch (@typeInfo(Key)) {
        .Array => |t| if (t.child == u8) std.mem.order(u8, &key_lf, &key_rt) else @panic("unsupported array type"),
        else => std.math.order(key_lf, key_rt),
    };
}

// toKey takes a value type and converts it to a Key
pub fn toKey(data: anytype) Key {
    // std.builtin.Type
    if (@typeInfo(Key) == .Int) {
        return @intCast(data);
    }

    // TODO: support big endian
    comptime assert(native_endian == .little);

    const data_ptr = switch (@typeInfo(@TypeOf(data))) {
        .Pointer => data,
        .ComptimeInt => &@as(u32, data), // Treat comptime_int as u32
        .ComptimeFloat => &@as(f32, data),
        else => &data,
    };

    var key = zero_key;
    const bytes = std.mem.asBytes(data_ptr);
    assert(key.len >= bytes.len);

    @memcpy(key[0..bytes.len], bytes);

    return key;
    // return key;
}

test {
    try std.testing.expectEqual(
        .lt,
        keyCompare(toKey(@as(PageIndex, 1)), toKey(@as(PageIndex, 2))),
    );

    // try std.testing.expectEqual(
    //     .lt,
    //     keyCompare(toKey("1"), toKey("2")),
    // );

    // try std.testing.expectEqual(
    //     .eq,
    //     keyCompare(toKey("meme"), toKey("meme")),
    // );

    // // Weird isn't it?
    // try std.testing.expectEqual(
    //     .gt,
    //     keyCompare(toKey(@as(f64, 99.99)), toKey(@as(f64, 100.0))),
    // );
}
