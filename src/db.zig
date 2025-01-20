const std = @import("std");
const mem = @import("std").mem;
const randomStringWithPrefix = @import("utils.zig").randomStringWithPrefix;
const serialize = @import("utils.zig").serialize;

const assert = @import("utils.zig").assert;

const Options = struct {
    page_size: u32 = mem.page_size,
    mmap_init_size: usize = mem.page_size,
    read_only: bool = false,
};

pub const Page = []u8;
pub const TxId = u64;
pub const PageIdx = u32;

fn maxPageIdx(page_size: u32) u32 {
    return (std.math.maxInt(PageIdx) / page_size) - 1;
}

const TX = struct {
    db: *DB,
    meta: Meta,
    writable: bool,
    managed: bool,
    pages: std.AutoHashMap(PageIdx, Page),

    fn init(db: *DB, writable: bool) !*TX {
        const tx = try db.alloc.create(TX);
        tx.* = TX{
            .managed = false,
            .db = db,
            .meta = db.getMeta(),
            .writable = writable,
            .pages = std.AutoHashMap(PageIdx, Page).init(db.alloc),
        };

        return tx;
    }

    fn rollback(tx: *TX) void {
        if (tx.managed) {
            @panic("managed transactions cannot be manually rolled back");
        }

        if (tx.writable) {
            // Remove transaction ref & writer lock.
            tx.db.rw_tx = null;
            tx.db.rw_lock.unlock();
        } else {
            tx.db.removeTx(tx);
        }

        tx.destroy();
    }

    fn destroy(tx: *TX) void {
        tx.db.alloc.destroy(tx);
    }

    fn commit(tx: *TX) !void {
        if (!tx.writable) {
            return error.TransactionReadOnly;
        }

        @panic("impl rollback");
    }
};

const DB = struct {
    is_open: bool,
    opts: Options,
    alloc: std.mem.Allocator,
    file: std.fs.File,

    meta_lock: std.Thread.Mutex, // Protects meta page access.
    meta: [2]Meta = undefined,

    rw_lock: std.Thread.Mutex, // Only one writer at a time
    rw_tx: ?*TX,
    txs: std.ArrayList(*TX),

    mmap_lock: std.Thread.RwLock, // Protects mmap access during remapping.
    data: []align(mem.page_size) u8 = undefined,

    pub fn open(alloc: std.mem.Allocator, file_path: []const u8, options: ?Options) !DB {
        var db = DB{
            .is_open = true,
            .opts = options orelse Options{},
            .alloc = alloc,
            .file = undefined,
            .rw_lock = .{},
            .mmap_lock = .{},
            .meta_lock = .{},
            .rw_tx = null,
            .txs = std.ArrayList(*TX).init(alloc),
        };

        if (db.opts.read_only) {
            db.file = try std.fs.cwd().openFile(file_path, std.fs.File.OpenFlags{
                .lock = .shared,
                .mode = .read_only,
            });
        } else {
            db.file = try (std.fs.cwd().createFile(file_path, .{
                .mode = 0o600,
                .read = true,
                .exclusive = true,
                .truncate = false,
                .lock = .exclusive,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => std.fs.cwd().openFile(file_path, .{ .mode = .read_write }),
                else => err,
            });
        }

        const stat = try db.file.stat();
        if (stat.size == 0) {
            try db.init();
        } else {
            const res = try db.pageSize();
            if (res[1]) {
                db.opts.page_size = res[0];
            }
        }

        try db.mmap(db.opts.mmap_init_size);

        db.meta[0] = Meta.copyFromPage(db.pageByIdx(0) orelse @panic("meta page 0 is not found"));
        db.meta[1] = Meta.copyFromPage(db.pageByIdx(1) orelse @panic("meta page 1 is not found"));

        db.meta[0].validate() catch {
            try db.meta[1].validate();
        };

        return db;
    }

    fn pageSize(db: *const DB) !struct { u32, bool } {
        // TODO: determine page size from the second metapage too
        var buf: [0x1000]u8 = undefined;
        const bytes_read = try db.file.readAll(&buf);
        if (bytes_read < @sizeOf(Meta)) {
            return error.NotEnoughSpace;
        }

        const meta1 = Meta.copyFromPage(&buf);
        meta1.validate() catch {
            return .{ 0, false };
        };

        return .{ meta1.page_size, true };
    }

    fn getMeta(db: *const DB) Meta {
        // We have to return the meta with the highest txid which does't fail
        // validation. Otherwise, we can cause errors when in fact the database is
        // in a consistent state. metaA is the one with thwe higher txid.
        var metaA = db.meta[0];
        var metaB = db.meta[1];
        if (db.meta[1].txid > db.meta[0].txid) {
            metaA = db.meta[1];
            metaB = db.meta[0];
        }

        metaA.validate() catch {
            metaB.validate() catch unreachable;
            return metaB;
        };

        return metaA;
    }

    fn pageFromBuf(db: *const DB, buf: []u8, id: PageIdx) Page {
        return buf[id * db.opts.page_size ..][0..db.opts.page_size];
    }

    pub fn init(db: *DB) !void {
        const buf = try db.alloc.alloc(u8, 4 * db.opts.page_size);
        defer db.alloc.free(buf);

        for (0..2) |i| {
            db.meta[i] = Meta{
                .page_size = db.opts.page_size,
                .freelist = 2,
                .root = 3,
                .txid = @as(TxId, i),
                .max_page = 4,
            };
            db.meta[i].check_sum = db.meta[i].checkSum();
            db.meta[i].write(db.pageFromBuf(buf, @intCast(i)));
        }

        // freelist
        // TODO: impl

        const page = db.pageFromBuf(buf, 2);

        @memset(page, 0);

        // root
        // TODO: impl
        @memset(db.pageFromBuf(buf, 3), 0);

        try db.file.pwriteAll(buf, 0);
        try db.file.sync();
    }

    pub fn pageByIdx(db: *DB, idx: PageIdx) ?Page {
        const page_size = db.opts.page_size;

        if (idx > maxPageIdx(page_size)) {
            return null;
        }

        const pos = idx * page_size;
        if (pos + page_size > db.data.len) {
            return null;
        }

        return db.data[pos..][0..page_size];
    }

    fn mmap(db: *DB, init_size: usize) !void {
        db.mmap_lock.lock();
        defer db.mmap_lock.unlock();

        // TODO: make the size a multiple of some value
        var size = (try db.file.stat()).size;
        if (size < init_size) {
            size = init_size;
        }

        db.data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            db.file.handle,
            0,
        );
    }

    // TODO: impl
    const Error = error{};

    /// Executes a function within the context of a managed read-only transaction.
    /// Any error that is returned from the function is returned from the view() method.
    ///
    /// Attempting to manually rollback within the function will cause a panic.
    pub fn view(db: *DB, func: fn (self: *TX) Error!void) Error!void {
        const tx = try db.begin(false);

        // Mark as managed tx so that the inner function cannot manually rollback.
        tx.managed = true;

        func(tx) catch |err| {
            tx.managed = false;
            tx.rollback() catch unreachable;
            tx.destroy();
            return err;
        };

        tx.managed = false;

        try tx.rollbackAndDestroy();
    }

    // Begin starts a new transaction.
    // Multiple read-only transactions can be used concurrently but only one write transaction can be used at a time. Starting multiple write transactions
    // will cause the calls to back and be serialized until the current write transaction finishes.
    //
    // Transactions should not be dependent on the one another. Opening a read
    // transaction and a write transaction in the same goroutine can cause the
    // writer to deadlock because the databases periodically needs to re-map itself
    // as it grows and it cannot do that while a read transaction is open.
    //
    // If a long running read transaction (for example, a snapshot transaction) is
    // needed, you might want to send DB.initialMmapSize to a larger enough value to avoid potential blocking of write transaction.
    //
    // *IMPORTANT*: You must close read-only transactions after you are finished or else the database will not reclaim old pages.
    pub fn begin(self: *DB, writable: bool) !*TX {
        if (writable) {
            return self.beginRWTx();
        }
        return self.beginTx();
    }

    fn beginTx(db: *DB) !*TX {
        db.meta_lock.lock();
        defer db.meta_lock.unlock();

        db.mmap_lock.lockShared();

        // Exit if the database is not open yet.
        if (!db.is_open) {
            db.mmap_lock.unlockShared();

            return error.DatabaseNotOpen;
        }

        const tx = try TX.init(db, false);
        db.txs.append(tx) catch unreachable;

        // TODO: update the transaction stats.

        return tx;
    }

    // beginRWTx starts a new read-write transaction
    fn beginRWTx(db: *DB) !*TX {
        if (db.opts.read_only) {
            return error.DatabaseReadOnly;
        }

        // Obtain writer lock. This released by the transaction when it closes.
        // This is enforces only one writer transaction at a time.
        db.rw_lock.lock();

        // Once we have the writer lock then we can lock the meta pages so that
        // we can set up the transaction.
        db.meta_lock.lock();
        defer db.meta_lock.unlock();

        if (!db.is_open) {
            db.rw_lock.unlock();
            return error.DatabaseNotOpen;
        }

        // Create a transaction associated with the database.
        const tx = try TX.init(db, true);
        db.rw_tx = tx;

        // TODO: release pending pages

        return tx;
    }

    fn removeTx(db: *DB, tx: *TX) void {
        db.mmap_lock.unlockShared();

        db.meta_lock.lock();
        defer db.meta_lock.unlock();

        for (db.txs.items, 0..) |tx2, i| {
            if (tx == tx2) {
                _ = db.txs.swapRemove(i);
            }
        }
    }

    fn close(db: *DB) void {
        db.rw_lock.lock();
        defer db.rw_lock.unlock();

        db.meta_lock.lock();
        defer db.meta_lock.unlock();

        db.mmap_lock.lock();
        defer db.mmap_lock.unlock();

        if (!db.is_open) {
            return;
        }

        assert(db.txs.items.len == 0, "all transactions must be closed before closing the database", .{});

        db.txs.deinit();
        std.posix.munmap(db.data);
        db.file.close(); // TODO: release a file lock as well?
        db.is_open = false;
    }
};

test DB {
    const alloc = std.testing.allocator;
    const file_path = try randomStringWithPrefix(alloc, "/tmp/db-test-", 7);
    defer alloc.free(file_path);
    defer std.fs.cwd().deleteFile(file_path) catch @panic("could not delete file");

    const wr_opts = Options{ .mmap_init_size = 1 << 31, .page_size = 4096, .read_only = false };
    {
        var db = try DB.open(alloc, file_path, wr_opts);
        defer db.close();

        try std.testing.expectEqual(wr_opts.mmap_init_size, db.data.len);

        try std.testing.expectEqual(wr_opts.page_size, db.pageByIdx(3).?.len);
        const max_page_idx = maxPageIdx(wr_opts.page_size);
        try std.testing.expectEqual(null, db.pageByIdx(max_page_idx));

        const tx = try db.begin(true);
        tx.rollback();

        const tx2 = try db.begin(true);
        tx2.rollback();

        const tx3 = try db.begin(false);
        tx3.rollback();
    }

    {
        const read_opts = Options{ .mmap_init_size = 1, .page_size = 1, .read_only = true };
        var db_read = try DB.open(alloc, file_path, read_opts);
        defer db_read.close();
        // Verify that page size is set from the first page on start
        try std.testing.expectEqual(wr_opts.page_size, db_read.opts.page_size);
        try std.testing.expectError(error.DatabaseReadOnly, db_read.begin(true));

        // try std.testing.expectError(error.DatabaseReadOnly, db_read.begin(false));
        // const tx3 = try db_read.begin(true);
        // tx3.rollback();

        var db_read2 = try DB.open(alloc, file_path, read_opts);
        defer db_read2.close();
    }
}

const MetaErrors = error{
    InvalidChecksum,
};

pub const Meta = struct {
    page_size: u32,
    root: PageIdx,
    freelist: PageIdx,
    max_page: PageIdx,
    txid: TxId,
    check_sum: u32 = 0,

    const Self = @This();
    // The size of the meta object.
    pub const header_size = @sizeOf(Meta);

    pub fn validate(self: *const Self) MetaErrors!void {
        if (self.check_sum != 0 and self.check_sum != self.checkSum()) {
            return MetaErrors.InvalidChecksum;
        }

        return;
    }

    pub fn copyFromPage(page: Page) Self {
        const srcMeta: *Self = @alignCast(std.mem.bytesAsValue(Self, page));

        return srcMeta.copy();
    }

    fn copy(self: *const Self) Self {
        return self.*;
    }

    fn emptyMeta() Meta {
        return .{
            .page_size = 0,
            .root = 0,
            .freelist = 0,
            .max_page = 0,
            .txid = 0,
        };
    }

    pub fn checkSum(self: *const Self) @TypeOf(self.check_sum) {
        const end_pos = @offsetOf(Self, "check_sum");
        var buf: [*]u8 = @constCast(@ptrCast(self));

        return std.hash.Crc32.hash(buf[0..end_pos]);
    }

    pub fn write(self: *Self, page: Page) void {
        assert(self.root < self.max_page, "root page id > max_page id: {}", .{self.max_page});
        assert(self.freelist < self.max_page, "freelist page id > max_page id: {}", .{self.max_page});

        self.check_sum = self.checkSum();
        const n = serialize(self, page);

        assert(n > 0, "nothing to serialize", .{});
    }
};
