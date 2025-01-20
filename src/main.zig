const std = @import("std");
const utils = @import("utils.zig");
const clap = @import("clap");

const InputReader = @import("input.zig").InputReader;
const CommandHandler = @import("cmd_handler.zig").CommandHandler;
const CmdErrors = @import("cmd_handler.zig").CmdErrors;
const InsertErrors = @import("cmd_handler.zig").InsertErrors;
const StmtErrors = @import("cmd_handler.zig").StmtErrors;

const printCli = utils.printCli;
const printCliPrefix = utils.printCliPrefix;

const BufferSize = 4092;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\<FILE>...
    );
    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const db_path: []const u8 = if (res.positionals.len > 0) res.positionals[0] else "./db";

    var buf: [BufferSize]u8 = undefined;
    var dynamic_buf: ?[]u8 = null;
    defer {
        if (dynamic_buf) |b| {
            alloc.free(b);
        }
    }

    const stdin = std.io.getStdIn();
    defer stdin.close();

    const file_stat = try stdin.stat();
    const is_pipe = file_stat.kind == .named_pipe;
    var stdin_reader = stdin.reader().any();
    if (is_pipe) {
        dynamic_buf = try stdin_reader.readAllAlloc(alloc, 1_000_000);
        var fbs = std.io.fixedBufferStream(dynamic_buf.?);
        stdin_reader = fbs.reader().any();
    }

    var input_reader = InputReader.init(&buf, stdin_reader);
    var cmd_handler = try CommandHandler.init(alloc, db_path);
    defer cmd_handler.deinit();

    while (true) {
        if (!is_pipe) printCliPrefix();

        const result = input_reader.read() catch |err| switch (err) {
            error.StreamTooLong => {
                printCli("The provided command is too long for input (max char len: {})", .{BufferSize});
                continue;
            },
            else => return err,
        };
        const input = result orelse {
            // stdin EOF
            return 0;
        };

        cmd_handler.handle(input) catch |err| switch (err) {
            InsertErrors.EmailTooLong, InsertErrors.UsernameTooLong => {
                printCli("String is too long.\n", .{});
            },
            InsertErrors.NegativeId => {
                printCli("ID must be positive.\n", .{});
            },
            StmtErrors.NotSupported => {
                printCli("The provided statement is not supported: {s}\n", .{input});
            },
            StmtErrors.Syntax => {
                printCli("The statement has a syntax error: {s}\n", .{input});
            },
            CmdErrors.Exit => {
                return 0;
            },
            else => {
                if (isErrorInSet(InsertErrors, err)) {
                    printCli("Error parsing the insert statement '{s}': {}\n", .{ input, err });
                } else {
                    return err;
                }
            },
        };
    }
}

fn isErrorInSet(ErrorSet: type, err: anyerror) bool {
    if (@typeInfo(ErrorSet).ErrorSet) |error_set| for (error_set) |err_info| {
        if (std.mem.eql(u8, @errorName(err), err_info.name)) {
            return true;
        }
    };

    return false;
}
