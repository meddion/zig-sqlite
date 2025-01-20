const std = @import("std");
const builtin = @import("builtin");

pub inline fn assert(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        return;
    }
    std.debug.print(fmt ++ "\n", args);
    std.debug.assert(ok);
}

const stdout = std.io.getStdOut().writer();
pub fn print(comptime fmt: []const u8, args: anytype) void {
    // See: https://github.com/ziglang/zig/issues/18111
    if (builtin.is_test) {
        std.log.info(fmt, args);
        return;
    }
    nosuspend stdout.print(fmt, args) catch return;
}

// const print = std.debug.print;
pub const CliPrefix = "db > ";

pub fn printCliPrefix() void {
    print(CliPrefix, .{});
}

pub fn printCli(comptime fmt: []const u8, args: anytype) void {
    print(CliPrefix ++ fmt, args);
}

pub const StringReader = struct {
    str: []const u8,
    pos: usize = 0,

    pub fn init(str: []const u8) @This() {
        return .{ .str = str };
    }

    const Reader = std.io.GenericReader(*@This(), anyerror, readFn);

    fn readFn(self: *@This(), buffer: []u8) anyerror!usize {
        const partialStr = self.str[self.pos..];
        if (partialStr.len == 0) {
            return error.EndOfStream;
        }

        const len = @min(buffer.len, partialStr.len);
        @memcpy(buffer[0..len], partialStr[0..len]);

        self.pos += len;

        return len;
    }

    pub fn reader(self: *@This()) Reader {
        return .{ .context = self };
    }
};

pub fn debugStruct(x: anytype) void {
    inline for (std.meta.fields(@TypeOf(x))) |f| {
        std.log.debug(f.name ++ " {any}", .{@as(f.type, @field(x, f.name))});
    }
}

pub fn toLowerString(str: []u8) void {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
}

// serialize expects data to be of pointer type
pub fn serialize(data: anytype, buf: []u8) usize {
    switch (@typeInfo(@TypeOf(data))) {
        .Pointer => {},
        else => @panic("serialize expects data to be a reference or pointer"),
    }

    const bytes = std.mem.asBytes(data);
    @memcpy(buf[0..bytes.len], bytes);
    return bytes.len;
}

test serialize {
    const TestData = struct {
        e: f64 = undefined,
        b: i32 = undefined,
        c: u64 = undefined,
        a: bool = undefined,
    };

    const expData = TestData{
        .a = true,
        .b = 24,
        .c = 42,
        .e = 0.2,
    };

    var buf: [1024]u8 = undefined;
    const n = serialize(&expData, &buf);
    const data = std.mem.bytesToValue(TestData, buf[0..n]);
    try std.testing.expectEqual(@sizeOf(TestData), n);
    try std.testing.expectEqual(expData, data);
}

const characters = [_]u8{
    'a', 'b', 'c', 'd', 'e', 'f', 'g',
    'h', 'i', 'j', 'k', 'l', 'm', 'n',
    'o', 'p', 'q', 'r', 's', 't', 'u',
    'v', 'w', 'x', 'y', 'z', 'A', 'B',
    'C', 'D', 'E', 'F', 'G', 'H', 'I',
    'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W',
    'X', 'Y', 'Z',
};

pub fn randomStringWithPrefix(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    n: u64,
) ![]const u8 {
    const rand = std.crypto.random;

    // Allocate a dynamic array to store the random string.
    var string = try allocator.alloc(u8, prefix.len + n);
    @memcpy(string[0..prefix.len], prefix[0..prefix.len]);

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const x = rand.intRangeAtMost(u8, 0, characters.len - 1);
        string[prefix.len + i] = characters[x];
    }

    return string;
}
