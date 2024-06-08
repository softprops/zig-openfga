/// A Zig client for [openfga](https://openfga.dev/)
const std = @import("std");
const Credentials = @import("auth.zig").Credentials;

pub const Store = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    deleted_at: ?[]const u8 = null,
};

pub const DirectUserSet = struct {
    description: ?[]const u8 = null,
};

pub const ObjectRelation = struct {
    object: []const u8,
    relation: []const u8,
};

pub const TupleToUserset = struct {
    tupleset: ObjectRelation,
    relation: ObjectRelation,
};

pub const Usersets = struct {
    child: []const Userset,
};

pub const Difference = struct {
    base: *Userset,
    subtract: *Userset,
};

pub const Userset = union(enum) {
    this: DirectUserSet,
    computedUserset: ObjectRelation,
    tupleToUserset: TupleToUserset,
    @"union": Usersets,
    intersection: Usersets,
    difference: Difference,

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();
        switch (self) {
            .this => |v| {
                try out.objectField("this");
                try out.write(v);
            },
            .computedUserset => |v| {
                try out.objectField("computedUserset");
                try out.write(v);
            },
            .tupleToUserset => |v| {
                try out.objectField("tupleToUserset");
                try out.write(v);
            },
            .@"union" => |v| {
                try out.objectField("union");
                try out.write(v);
            },
            .intersection => |v| {
                try out.objectField("intersection");
                try out.write(v);
            },
            .difference => |v| {
                try out.objectField("difference");
                try out.write(v);
            },
        }
        try out.endObject();
    }
};

pub const TypeDefinition = struct {
    pub const Relation = struct { []const u8, Userset };
    type: []const u8,
    relations: ?[]const Relation = null,

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        try out.beginObject();

        try out.objectField("type");
        try out.write(self.type);

        if (self.relations) |rels| {
            try out.objectField("relations");
            try out.beginObject();
            for (rels) |rel| {
                try out.objectField(rel.@"0");
                try out.write(rel.@"1");
            }
            try out.endObject();
        }

        try out.endObject();
    }
};

test "TypeDefinition.jsonStringify" {
    const allocator = std.testing.allocator;
    const type_def = TypeDefinition{
        .type = "document",
        .relations = &.{
            .{
                "reader", .{
                    .@"union" = .{
                        .child = &.{
                            .{ .this = .{} },
                            .{
                                .computedUserset = .{
                                    .object = "",
                                    .relation = "writer",
                                },
                            },
                        },
                    },
                },
            },
            .{
                "writer", .{
                    .this = .{},
                },
            },
        },
    };
    const json = try std.json.stringifyAlloc(
        allocator,
        type_def,
        .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        },
    );
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});
}

pub const AuthorizationModel = struct {
    id: []const u8,
    schema_version: []const u8,
    type_definitions: ?[]const TypeDefinition = null,
};

const Error = struct {
    code: []const u8,
    message: []const u8,
};

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,
        pub fn deinit(self: *@This()) void {
            const arena = self.arena;
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    };
}

pub const HttpClient = struct {
    wrapped: std.http.Client,
    credentials: Credentials,
    pub fn init(wrapped: std.http.Client, credentials: Credentials) @This() {
        return .{ .wrapped = wrapped, .credentials = credentials };
    }

    pub fn deinit(self: *@This()) void {
        self.wrapped.deinit();
    }

    pub fn fetch(self: *@This(), options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
        const authz = try self.credentials.authorization(&self.wrapped);
        defer {
            switch (authz) {
                .override => |v| self.wrapped.allocator.free(v),
                else => {},
            }
        }
        return self.wrapped.fetch(options);
    }
};

/// openapi docs https://docs.fga.dev/api/service
///
/// auth0 docs https://auth0.com/fine-grained-authorization
pub const Client = struct {
    pub const Options = struct {
        api_url: []const u8 = "http://localhost:8080",
        store_id: ?[]const u8 = null,
        credentials: Credentials = .{ .none = {} },
    };

    client: HttpClient,
    allocator: std.mem.Allocator,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, options: Options) @This() {
        return .{
            .allocator = allocator,
            .options = options,
            .client = HttpClient.init(
                .{
                    .allocator = allocator,
                },
                options.credentials,
            ),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    pub fn stores(self: *@This()) !Owned([]const Store) {
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

    pub fn authorizationModels(self: *@This(), options: ListStoreOptions) !Owned([]const AuthorizationModel) {
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

    fn post(self: @This(), comptime T: type, path: []const u8, body: anytype) !std.json.Parsed(T) {
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
                .method = .POST,
                .payload = body,
                .location = .{
                    .url = url,
                },
                .response_storage = .{
                    .dynamic = &buf,
                },
            },
        );

        const bytes = try buf.toOwnedSlice();
        defer self.allocator.free(bytes);

        if (result.status.class() != .success) {
            var err = try std.json.parseFromSlice(
                Error,
                self.allocator,
                bytes,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            );
            defer err.deinit();
            std.log.err(
                "request failed with HTTP status {any} {s} {s}",
                .{ result.status, err.value.code, err.value.message },
            );
            return error.RequestFailed;
        }

        return try std.json.parseFromSlice(
            T,
            self.allocator,
            bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
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

        const bytes = try buf.toOwnedSlice();
        defer self.allocator.free(bytes);

        if (result.status.class() != .success) {
            var err = try std.json.parseFromSlice(
                Error,
                self.allocator,
                bytes,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            );
            defer err.deinit();
            std.log.err(
                "request failed with HTTP status {any} {s} {s}",
                .{ result.status, err.value.code, err.value.message },
            );
            return error.RequestFailed;
        }

        return try std.json.parseFromSlice(
            T,
            self.allocator,
            bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }
};

test "Client.stores" {
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
