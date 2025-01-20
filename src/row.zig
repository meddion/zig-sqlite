const std = @import("std");

pub fn newMockRow(id: i32, username: []const u8, email: []const u8) Row {
    var row = Row{
        .id = id,
    };

    @memcpy(row.username[0..username.len], username);
    @memcpy(row.email[0..email.len], email);

    return row;
}

pub const Row = struct {
    id: i32 = 0,
    username: [32]u8 = undefined,
    email: [256]u8 = undefined,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        // Convert to Sentient-Terminated Pointers because from fmt.zig on `s`:
        // - for pointer-to-many and C pointers of u8, print as a C-string using zero-termination
        // - for slices of u8, print the entire slice as a string without zero-termination
        const username = @as([*:0]const u8, @ptrCast(&self.username)); // or @as([*c]const u8, &self.username);
        const email = @as([*:0]const u8, @ptrCast(&self.email));

        try writer.print("({d}, {s}, {s})", .{ self.id, username, email });
    }

    pub const Size = @sizeOf(@This());
};

test "Row.format" {
    const alloc = std.testing.allocator;
    const row = newMockRow(1, "user1", "person1@example.com");

    const row_str = try std.fmt.allocPrint(alloc, "{}", .{row});
    defer alloc.free(row_str);

    try std.testing.expectEqual("(1, user1, person1@example.com)".len, row_str.len);
    try std.testing.expectEqualStrings("(1, user1, person1@example.com)", row_str);
}
