/// A Zig client for [openfga](https://openfga.dev/)
const std = @import("std");

pub const Store = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    deleted_at: ?[]const u8 = null,
};

pub const AuthorizationModel = struct {
    id: []const u8,
};

fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,
        fn deinit(self: *@This()) void {
            const arena = self.arena;
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    };
}

pub const Client = struct {
    pub const Options = struct {
        api_url: []const u8 = "http://localhost:8080",
        store_id: ?[]const u8 = null,
    };

    client: std.http.Client,
    allocator: std.mem.Allocator,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, options: Options) @This() {
        return .{
            .allocator = allocator,
            .options = options,
            .client = .{
                .allocator = allocator,
            },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    // openapi ref https://docs.fga.dev/api/service
    fn stores(self: *@This()) !Owned([]const Store) {
        const parsed = try self.get(struct { stores: []const Store }, "/stores");
        return Owned([]const Store){
            .value = parsed.value.stores,
            .arena = parsed.arena,
        };
    }

    pub const ListStoreOptions = struct {
        store_id: []const u8,
        page_size: ?i32 = null,
        continuation_token: ?[]const u8 = null,
    };

    fn authorizationModels(self: *@This(), options: ListStoreOptions) !Owned([]const AuthorizationModel) {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/stores/{s}/authorization-models",
            .{options.store_id},
        );
        defer self.allocator.free(path);
        const parsed = try self.get(struct { authorization_models: []const AuthorizationModel }, path);
        return Owned([]const AuthorizationModel){
            .value = parsed.value.authorization_models,
            .arena = parsed.arena,
        };
    }

    fn get(self: *@This(), comptime T: type, path: []const u8) !std.json.Parsed(T) {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.options.api_url, path },
        );
        defer self.allocator.free(url);
        const result = try self.client.fetch(
            .{
                .location = .{
                    .url = url,
                },
                .response_storage = .{
                    .dynamic = &buf,
                },
            },
        );
        if (result.status.class() != .success) {
            std.log.err("request failed with HTTP status {any}", .{result.status});
            return error.RequestFailed;
        }
        const bytes = try buf.toOwnedSlice();
        defer self.allocator.free(bytes);
        return try std.json.parseFromSlice(
            T,
            self.allocator,
            bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }
};

test "listStores" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var stores = try client.stores();
    defer stores.deinit();
    for (stores.value) |store| {
        std.debug.print("store {s} {s}\n", .{ store.id, store.name });
        var models = try client.authorizationModels(.{ .store_id = store.id });
        defer models.deinit();
        for (models.value) |model| {
            std.debug.print("model {s}\n", .{model.id});
        }
    }
}
