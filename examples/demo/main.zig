const std = @import("std");
const openfga = @import("openfga");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = openfga.Client.init(allocator, .{});
    defer client.deinit();

    var stores = try client.stores();
    defer stores.deinit();
    for (stores.value) |store| {
        std.debug.print("store {s}: {s}\n", .{ store.id, store.name });
    }
}
