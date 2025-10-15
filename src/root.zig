const std = @import("std");

test "STOMP frame init" {
    const frame = "TEST\r\nheader1:value1\r\nheader2:value2\r\n\r\nbody\x00\r\n";
    const allocator = std.testing.allocator;
    var parsed_frame = try StompFrame.init(allocator, frame);
    defer parsed_frame.deinit();

    std.debug.print("command: {s}\n", .{parsed_frame.command});
    try std.testing.expectEqualStrings("TEST", parsed_frame.command);

    var entry_count: usize = 0;
    for (parsed_frame.headers.keys()) |key| {
        std.debug.print("key: {s}, value: {s}\n", .{ key, parsed_frame.headers.get(key).? });
        switch (entry_count) {
            0 => {
                try std.testing.expectEqualStrings("header1", key);
                try std.testing.expectEqualStrings("value1", parsed_frame.headers.get(key).?);
            },
            1 => {
                try std.testing.expectEqualStrings("header2", key);
                try std.testing.expectEqualStrings("value2", parsed_frame.headers.get(key).?);
            },
            else => unreachable,
        }
        entry_count += 1;
    }

    std.debug.print("body: {s}\n", .{parsed_frame.body});
    try std.testing.expectEqualStrings("body", parsed_frame.body);
}

const StompFrame = struct {
    allocator: std.mem.Allocator,
    frame_buffer: []u8,
    command: []const u8,
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    body: []const u8,

    fn normalize(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
        const needle = "\r\n";
        const replacement = "\n";

        const buff = try allocator.alloc(u8, frame.len);

        const replace_count = std.mem.replace(u8, frame, needle, replacement, buff);
        const replaced_len = frame.len - (replace_count * (needle.len - replacement.len));
        return try allocator.realloc(buff, replaced_len);
    }

    fn init(allocator: std.mem.Allocator, frame: []const u8) !StompFrame {
        const normalized_frame = try normalize(allocator, frame);

        var reader = std.io.Reader.fixed(normalized_frame);
        const command = try reader.takeDelimiterExclusive('\n');

        var headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

        while (reader.takeDelimiterExclusive('\n')) |line| {
            if (line.len == 0) break;

            const delimiter_index = std.mem.indexOf(u8, line, ":").?;
            const key = line[0..delimiter_index];
            const value = line[delimiter_index + 1 .. line.len];
            try headers.put(allocator, key, value);
        } else |err| {
            if (err != error.EndOfStream) return err;
        }
        const body = try reader.takeDelimiterExclusive('\x00');

        return .{
            .allocator = allocator,
            .frame_buffer = normalized_frame,
            .command = command,
            .headers = headers,
            .body = body,
        };
    }

    fn deinit(self: *StompFrame) void {
        self.allocator.free(self.frame_buffer);
        self.headers.deinit(self.allocator);
    }
};

fn writeFrame(writer: *std.Io.Writer, frame: []const u8) !void {
    try writer.writeAll(frame);
    try writer.writeByte('\x00');
    try writer.flush();
}

test writeFrame {
    var buffer: [256]u8 = undefined;
    const frame = "send TEST\n\n\x00";
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFrame(&writer, frame);
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !StompFrame {
    std.debug.print("Reading frame...\n", .{});
    const frame = try reader.readAlloc(allocator, reader.end);
    defer allocator.free(frame);

    return try StompFrame.init(
        allocator,
        frame,
    );
}

test readFrame {
    const frame = "MESSAGE\nheader1:value1\nheader2:value2\n\nBody of the message\n\x00";
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(frame);
    var response = try readFrame(allocator, &reader);
    defer response.deinit();
    try std.testing.expectEqualStrings("MESSAGE", response.command);
    try std.testing.expectEqualStrings("value1", response.headers.get("header1").?);
    try std.testing.expectEqualStrings("value2", response.headers.get("header2").?);
    try std.testing.expectEqualStrings("Body of the message\n", response.body);
}

pub const Consumer = struct {
    const Self = @This();

    remote_addr: std.net.Address,
    connected_stream: std.net.Stream,

    pub fn init(addr: std.net.Address) Self {
        return Self{
            .connected_stream = undefined,
            .remote_addr = addr,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connected_stream.close();
    }

    pub fn connect(self: *Self, host: []const u8, user: []const u8, passcode: []const u8) !void {
        self.connected_stream = try std.net.tcpConnectToAddress(self.remote_addr);

        const connect_template =
            \\CONNECT
            \\accept-version:1.2
            \\host:{s}
            \\user:{s}
            \\passcode:{s}
            \\
            \\
        ;
        var frame_buffer: [128]u8 = undefined;
        const frame = try std.fmt.bufPrint(&frame_buffer, connect_template, .{
            host,
            user,
            passcode,
        });

        // CONNECTフレーム送信
        var writer = self.connected_stream.writer(&.{});
        try writeFrame(&writer.interface, frame);

        const allocator = std.heap.page_allocator;
        var r_buffer: [1024]u8 = undefined;
        var reader = self.connected_stream.reader(&r_buffer);
        const io_reader = reader.interface();
        const response = try readFrame(allocator, io_reader);
        std.debug.print("Response: {s}", .{response.command});
    }

    pub fn disconnect(self: *Self) !void {
        const disconnect_frame =
            \\DISCONNECT
            \\
            \\
        ;
        var writer = self.connected_stream.writer(&.{});
        try writeFrame(&writer.interface, disconnect_frame);
    }

    pub fn subscribe(self: *Self, id: []const u8, destination: []const u8, ack_mode: []const u8) !void {
        const subscribe_template =
            \\SUBSCRIBE
            \\id:{s}
            \\destination:{s}
            \\ack:{s}
            \\
            \\
        ;

        var frame_buffer: [256]u8 = undefined;
        const frame = try std.fmt.bufPrint(&frame_buffer, subscribe_template, .{
            id,
            destination,
            ack_mode,
        });

        var writer = self.connected_stream.writer(&.{});
        try writeFrame(&writer.interface, frame);
    }

    pub fn recvMessage(self: *Self, allocator: std.mem.Allocator) !StompFrame {
        var r_buffer: [1024]u8 = undefined;
        var reader = self.connected_stream.reader(&r_buffer);
        const io_reader = reader.interface();
        return try readFrame(allocator, io_reader);
    }
};
