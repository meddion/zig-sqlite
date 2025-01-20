const std = @import("std");
const randomStringWithPrefix = @import("utils.zig").randomStringWithPrefix;

const assert = std.debug.assert;
const bytesToValue = std.mem.bytesToValue;

pub const PageErrors =
    error{PageNotFound} || MmapErrors;

pub const MmapErrors =
    std.fs.File.SetEndPosError ||
    std.fs.File.StatError ||
    std.posix.MMapError ||
    std.posix.MSyncError;

pub const Index = u32;

pub fn Pager(max_pages: comptime_int, page_size: comptime_int, comptime page_align: ?u29) type {
    return struct {
        pages: [max_pages]?Page = [_]?Page{null} ** max_pages,
        alloc: std.mem.Allocator,
        file: std.fs.File,

        pub const Page = []align(page_align orelse @alignOf(u8)) u8;
        pub const IndexedPage = struct {
            page: Page,
            idx: Index,
        };

        const mmapOp = enum {
            write,
            read,
        };

        pub fn open(alloc: std.mem.Allocator, file_path: []const u8) !@This() {
            const file = try (std.fs.cwd().createFile(file_path, .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => std.fs.cwd().openFile(file_path, .{ .mode = .read_write }),
                else => err,
            });

            return .{
                .alloc = alloc,
                .file = file,
            };
        }

        pub fn reclaimPage(self: *@This(), page_idx: Index) !void {
            assert(self.pages[page_idx] != null);

            @memset(self.pages[page_idx].?, 0);
            try self.flushPage(page_idx);
            self.alloc.free(self.pages[page_idx].?);
            self.pages[page_idx] = null;
        }

        pub fn nextEmptyPage(self: *@This()) PageErrors!IndexedPage {
            const page_idx = try self.emptyPageIdx();
            return .{ .page = try self.pageByIdx(page_idx), .idx = page_idx };
        }

        // TODO: store next empty page idx
        fn emptyPageIdx(self: @This()) error{PageNotFound}!Index {
            for (self.pages, 0..) |page, i| {
                if (page == null) {
                    return @intCast(i);
                }
            }

            return PageErrors.PageNotFound;
        }

        pub fn pageByIdx(self: *@This(), page_idx: Index) PageErrors!Page {
            if (page_idx >= max_pages) {
                return PageErrors.PageNotFound;
            }

            return self.pages[page_idx] orelse {
                self.pages[page_idx] = try self.alloc.alignedAlloc(u8, page_align, page_size);
                errdefer {
                    self.alloc.free(self.pages[page_idx].?);
                    self.pages[page_idx] = null;
                }
                _ = try self.pageMmap(page_idx, .read, false);

                return self.pages[page_idx].?;
            };
        }

        pub fn numPages(self: @This()) !u64 {
            return (try self.file.stat()).size / page_size;
        }

        pub fn flushPage(self: *@This(), page_idx: Index) !void {
            if (self.pages[page_idx] == null) return;
            _ = try self.pageMmap(page_idx, .write, true);
        }

        // Align the offset to the nearest lower multiple of the system's page size
        fn offsetAligned(offset: u64) u64 {
            return offset & ~@as(u64, std.mem.page_size - 1); // same as  offset - (offset % pagesize)
        }

        // mmap returns true if page was read from disk, otherwise false.
        fn pageMmap(self: *@This(), page_idx: Index, op: mmapOp, msync: bool) PageErrors!bool {
            const page = self.pages[page_idx].?;

            const file_offset = page_idx * page_size;
            if (file_offset + page_size > (try self.file.stat()).size) {
                // Increase file size so mmap has something to read
                try self.file.setEndPos(file_offset + page_size);
                // Return false as the page was not read from disk
                return false;
            }

            const offset_aligned = offsetAligned(file_offset);
            const map_size = page_size + (file_offset - offset_aligned);

            const ptr = try std.posix.mmap(
                null,
                map_size,
                if (op == .write) std.posix.PROT.WRITE else std.posix.PROT.READ,
                .{ .TYPE = if (op == .write) .SHARED else .PRIVATE },
                self.file.handle,
                offset_aligned,
            );

            defer std.posix.munmap(ptr);

            const dest = page;
            const src = ptr[file_offset - offset_aligned ..];
            if (op == .write) {
                @memcpy(src, dest);
            } else {
                @memcpy(dest, src);
            }

            if (msync and op == .write) {
                // Force synchronies writes
                try std.posix.msync(ptr, std.posix.MSF.SYNC);
            }

            return true;
        }

        pub fn close(self: *@This()) void {
            // TODO: save all of the pages to a file before closing
            for (self.pages, 0..) |page, i| {
                if (page) |non_null_page| {
                    // TODO: return error
                    self.flushPage(@intCast(i)) catch @panic("failed to flush");
                    self.alloc.free(non_null_page);
                    self.pages[i] = null;
                }
            }
            self.file.close();
        }
    };
}

test Pager {
    const alloc = std.testing.allocator;

    const file_path = try randomStringWithPrefix(alloc, "/tmp/db-pager-test-", 7);
    defer alloc.free(file_path);
    defer std.fs.cwd().deleteFile(file_path) catch @panic("could not delete file");

    const page_size = 4096;
    const TestPager = Pager(100, page_size, 8);
    const written_page = &[_]u8{42} ** page_size;
    // Store
    {
        var pager = try TestPager.open(alloc, file_path);
        defer pager.close();
        const page = try pager.pageByIdx(2);
        @memcpy(page, written_page);
        try pager.flushPage(2);
    }
    // Read stored
    {
        var pager = try TestPager.open(alloc, file_path);
        defer pager.close();
        try std.testing.expectEqualSlices(u8, written_page, try pager.pageByIdx(2));
    }
}

pub fn TempPager(PagerT: type) type {
    return struct {
        alloc: std.mem.Allocator,
        pager: PagerT,
        file_path: []const u8,

        const Self = @This();

        pub fn open(alloc: std.mem.Allocator) !Self {
            const file_path = try randomStringWithPrefix(alloc, "/tmp/temp-pager-", 7);
            errdefer alloc.free(file_path);

            return .{
                .alloc = alloc,
                .pager = try PagerT.open(alloc, file_path),
                .file_path = file_path,
            };
        }

        pub fn close(self: *Self) void {
            self.pager.close();
            std.fs.cwd().deleteFile(self.file_path) catch @panic("could not delete file");
            self.alloc.free(self.file_path);
        }
    };
}
