const std = @import("std");
const testing = std.testing;

pub const Client = @import("client.zig").Client;

test {
    std.testing.refAllDecls(@This());
}
