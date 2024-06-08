const std = @import("std");

/// Credentials used to authenticate fga requests
pub const Credentials = union(enum) {
    // https://docs.fga.dev/integration/getting-your-api-keys
    pub const ClientCredentials = struct {
        // todo compute expiry from expires_in and proactively refetch when stale
        const Cached = struct {
            token: []const u8,
        };
        token_issuer: []const u8, // i.e. fga.us.auth0.com
        audience: []const u8, // i.e https://api.us1.fga.dev/
        client_id: []const u8,
        client_secret: []const u8,
        scopes: ?[]const u8 = null,
        cache: ?Cached = null,
    };
    none: void,
    api_token: []const u8,
    client_credentials: ClientCredentials,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        // don't log credential info
        _ = try writer.write(@tagName(self));
    }

    /// caller owns freeing returned .override bytes
    pub fn authorization(self: @This(), client: *std.http.Client) !std.http.Client.Request.Headers.Value {
        const allocator = client.allocator;
        return switch (self) {
            .none => .default,
            .api_token => |v| .{
                .override = try std.fmt.allocPrint(
                    allocator,
                    "Bearer {s}",
                    .{v},
                ),
            },
            .client_credentials => |v| blk: {
                // todo: read from cache, refreshing when stale ect
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();
                const url = try std.fmt.allocPrint(
                    allocator,
                    "https://{s}/oauth/token",
                    .{v.token_issuer},
                );
                defer client.allocator.free(url);
                const payload = try std.json.stringifyAlloc(
                    allocator,
                    .{
                        .client_id = v.client_id,
                        .client_secret = v.client_secret,
                        .audience = v.audience,
                        .grant_type = "client_credentials",
                    },
                    .{},
                );
                defer allocator.free(payload);
                const result = try client.fetch(.{
                    .method = .POST,
                    .location = .{ .url = url },
                    .response_storage = .{ .dynamic = &buf },
                    .headers = .{
                        .content_type = .{ .override = "application/json" },
                    },
                    .payload = payload,
                });
                if (result.status.class() != .success) {
                    return error.TokenFetchError;
                }
                const bytes = try buf.toOwnedSlice();
                defer allocator.free(bytes);
                var parsed = try std.json.parseFromSlice(
                    struct { access_token: []const u8 },
                    allocator,
                    bytes,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                break :blk .{ .override = try allocator.dupe(u8, parsed.value.access_token) };
            },
        };
    }
};
