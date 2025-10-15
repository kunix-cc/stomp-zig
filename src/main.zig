const std = @import("std");
const stomp = @import("stomp_zig");

pub fn main() !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 61613);
    var consumer = stomp.Consumer.init(addr);
    defer consumer.deinit();

    std.debug.print("Connecting to STOMP server...\n", .{});
    try consumer.connect("localhost", "test-user", "password");

    try consumer.subscribe("0", "test", "auto");

    const allocator = std.heap.page_allocator;
    while (consumer.recvMessage(allocator)) |msg| {
        std.debug.print("Received message: {s}\n", .{msg.command});
    } else |_| {
        std.debug.print("Error receiving message.\n", .{});
    }
    try consumer.disconnect();
}
