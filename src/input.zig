const std = @import("std");
const utils = @import("utils.zig");
const Row = @import("row.zig").Row;

pub const InputReader = struct {
    // buffer: [buff_size]u8 = undefined,
    buffer: std.io.FixedBufferStream([]u8) = undefined,
    reader: std.io.AnyReader = undefined,

    pub fn init(buf: []u8, reader: std.io.AnyReader) Self {
        return .{
            .reader = reader,
            .buffer = std.io.fixedBufferStream(buf),
        };
    }

    const Self = @This();

    // read returns a line from a reader.
    // NOTE: each call to read might overwrite the previous result, thus copy the returned buffer if you intent on storing it
    pub fn read(
        self: *Self,
    ) !?[]u8 {
        self.buffer.reset();

        self.reader.streamUntilDelimiter(self.buffer.writer(), '\n', self.buffer.buffer.len) catch |err| switch (err) {
            error.EndOfStream => if (self.buffer.getWritten().len == 0) {
                return null;
            },
            error.StreamTooLong => {
                self.exhaustStream();
                return error.StreamTooLong;
            },
            else => |e| return e,
        };

        return self.buffer.getWritten();
    }

    pub fn exhaustStream(self: *Self) void {
        _ = self.read() catch |err| {
            if (err == error.StreamTooLong) {
                self.exhaustStream();
            }
        };
    }
};

test InputReader {
    // Not enough buffer space
    var str_reader = utils.StringReader.init("he");
    var buf: [1]u8 = undefined;
    var input_reader = InputReader.init(&buf, str_reader.reader().any());
    try std.testing.expectError(error.StreamTooLong, input_reader.read());
    try std.testing.expectEqual(null, try input_reader.read());

    // Delimiter found
    str_reader = utils.StringReader.init("hello\nbye");
    var buf2: [10]u8 = undefined;
    input_reader = InputReader.init(&buf2, str_reader.reader().any());
    try std.testing.expectEqualSlices(u8, "hello", (try input_reader.read()).?);
    try std.testing.expectEqualSlices(u8, "bye", (try input_reader.read()).?);
    try std.testing.expectEqual(null, input_reader.read());

    // No delimiter found
    str_reader = utils.StringReader.init("hello");
    input_reader = InputReader.init(&buf2, str_reader.reader().any());
    try std.testing.expectEqualSlices(u8, "hello", (try input_reader.read()).?);
    try std.testing.expectEqual(null, try input_reader.read());
}
