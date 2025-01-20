const std = @import("std");

const DefaultTable = @import("table.zig").DefaultTable;
const Row = @import("row.zig").Row;
const newMockRow = @import("row.zig").newMockRow;

const randomStringWithPrefix = @import("utils.zig").randomStringWithPrefix;
const printCli = @import("utils.zig").printCli;
const printCliPrefix = @import("utils.zig").printCliPrefix;
const print = @import("utils.zig").print;

const assert = std.debug.assert;

pub const StmtErrors = error{
    NotSupported,
    Syntax,
};

const Statement = union(enum) {
    Insert: InsertStmt,
    Select: SelectStmt,
};

const InsertStmt = struct {
    row: Row = undefined,
};
const SelectStmt = struct {};

pub const CommandHandler = struct {
    alloc: std.mem.Allocator,
    table: DefaultTable,

    const Commands = enum {
        Exit,
        Undef,
    };

    pub fn init(alloc: std.mem.Allocator, db_path: []const u8) !CommandHandler {
        var cmd_handler = CommandHandler{
            .alloc = alloc,
            .table = try DefaultTable.open(alloc, db_path),
        };
        errdefer cmd_handler.table.deinit();

        return cmd_handler;
    }

    pub fn deinit(self: *CommandHandler) void {
        self.table.deinit();
    }

    pub fn handle(self: *CommandHandler, inputStr: []const u8) !void {
        if (inputStr.len > 0 and inputStr[0] == '.') {
            try self.handle_command(inputStr);
        } else {
            try self.handle_statement(inputStr);
        }
    }

    fn handle_statement(_: *CommandHandler, inputStr: []const u8) !void {
        const startsWith = std.mem.startsWith;

        const stmt = blk: {
            if (startsWith(u8, inputStr, "select")) {
                break :blk Statement{
                    .Select = .{},
                };
            }

            if (startsWith(u8, inputStr, "insert")) {
                var insert_stmt = InsertStmt{};
                try parseInsert(&insert_stmt.row, inputStr);

                break :blk Statement{ .Insert = insert_stmt };
            }

            return StmtErrors.NotSupported;
        };

        switch (stmt) {
            .Insert => |_| {
                // if (try self.table.isRowPresentById(insert_stmt.row.id))
                //     return error.DuplicateRowId;

                // try self.table.appendRow(insert_stmt.row);
                printCli("Executed.\n", .{});
            },
            .Select => |_| {
                // const rows = try self.table.allRows();
                // defer self.alloc.free(rows);

                // printCliPrefix();
                // for (rows) |row| {
                //     print("{}\n", .{row});
                // }
                print("Executed.\n", .{});
            },
        }
    }

    const SupportedCmds = std.StaticStringMap(Commands).initComptime(.{
        .{ ".exit", Commands.Exit },
    });

    fn handle_command(_: CommandHandler, cmdStr: []const u8) CmdErrors!void {
        const cmd = SupportedCmds.get(cmdStr) orelse Commands.Undef;

        switch (cmd) {
            .Exit => {
                printCliPrefix();
                // TODO: convert to enum
                return CmdErrors.Exit;
            },
            .Undef => printCli("Unrecognized command '{s}'.\nType: .help to see the list of available commands.\n", .{cmdStr}),
        }
    }
};

pub const CmdErrors = error{Exit};

test CommandHandler {
    const alloc = std.testing.allocator;

    const dp_path = try randomStringWithPrefix(alloc, "/tmp/db-cmd-handler-test-", 7);
    defer alloc.free(dp_path);

    var cmd_handler = try CommandHandler.init(alloc, dp_path);
    defer cmd_handler.deinit();
    defer std.fs.cwd().deleteFile(dp_path) catch @panic("could not delete file");

    try cmd_handler.handle("insert 1 name1 name1@mail.com");
    try cmd_handler.handle("insert 3 name2 name2@mail.com");
    try std.testing.expectError(
        StmtErrors.NotSupported,
        cmd_handler.handle("inser 3 name2 name2@mail.com"),
    );

    // const rows = try cmd_handler.table.allRows();
    // defer alloc.free(rows);

    // try std.testing.expectEqual(2, rows.len);
}

pub const InsertErrors = error{
    IdTooLong,
    NegativeId,
    InvalidId,
    UsernameTooLong,
    EmailTooLong,
    MissingField,
};

pub fn parseInsert(row: *Row, input_str: []const u8) InsertErrors!void {
    var iter = std.mem.tokenizeScalar(u8, input_str, ' ');
    _ = iter.next() orelse return InsertErrors.MissingField; // Skip insert

    // Is the len of this field checked?
    row.id = try (std.fmt.parseInt(i32, iter.next() orelse return InsertErrors.MissingField, 10) catch |err| switch (err) {
        std.fmt.ParseIntError.Overflow => InsertErrors.IdTooLong,
        std.fmt.ParseIntError.InvalidCharacter => InsertErrors.InvalidId,
    });
    if (row.id < 0) return InsertErrors.NegativeId;

    const user = iter.next() orelse return InsertErrors.MissingField;
    if (user.len > row.username.len - 1) { // Account for zero terminated '0' string
        return InsertErrors.UsernameTooLong;
    }
    @memcpy(
        row.username[0..user.len],
        user,
    );
    row.username[user.len] = 0;

    const email = iter.next() orelse return InsertErrors.MissingField;
    if (email.len > row.email.len - 1) { // Account for zero terminated '0' string
        return InsertErrors.EmailTooLong;
    }
    @memcpy(
        row.email[0..email.len],
        email,
    );
    row.email[email.len] = 0;
}

test parseInsert {
    // Populate with sscanf
    var row = Row{};
    const exp_row = newMockRow(1, "user1", "person1@example.com");
    const input_str = "insert 1 user1 person1@example.com";
    try parseInsert(&row, input_str);
    try std.testing.expectEqual(exp_row, row);

    try std.testing.expectError(error.UsernameTooLong, parseInsert(&row, "insert 2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    row = Row{};
    var b: [1024]u8 = undefined;
    const input = try std.fmt.bufPrint(&b, "insert 1 user1 {s:_<256}", .{"a"});
    try std.testing.expectError(error.EmailTooLong, parseInsert(&row, input));

    row = Row{};
    const id_too_long = try std.fmt.bufPrint(&b, "insert 2{d:0<11}", .{0});
    try std.testing.expectError(error.IdTooLong, parseInsert(&row, id_too_long));
}
