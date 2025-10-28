const std = @import("std");
const stomp = @import("stomp_zig");

pub fn main() !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 61613);
    var consumer = stomp.Consumer.init(addr);
    defer consumer.deinit();

    std.debug.print("Connecting to STOMP server...\n", .{});
    try consumer.connect("localhost", "test-user", "password");
    std.debug.print("Connect success!!!\n", .{});

    try consumer.subscribe("0", "test", "auto");
    std.debug.print("Subscribing now...\n", .{});

    const allocator = std.heap.page_allocator;
    while (consumer.recvMessage(allocator)) |msg| {
        msg.print();
    } else |_| {
        std.debug.print("Error receiving message.\n", .{});
    }
    try consumer.disconnect();
}
