pub const maximum_entries = 64;

pub const FeatureFlags = struct {
    values: []const []const u8,
};

pub const KnownPack = struct {
    namespace: []const u8,
    id: []const u8,
    version: []const u8,
};

pub const KnownPacks = struct {
    values: []const KnownPack,
};

pub const RegistryEntry = struct {
    id: []const u8,
    nbt: ?[]const u8 = null,
};

pub const Registry = struct {
    id: []const u8,
    entries: []const RegistryEntry,
};

pub const Tags = struct {
    payload: []const u8,
};

pub const ResourcePack = struct {
    uuid: u128,
    url: []const u8,
    hash: []const u8,
    required: bool,
    prompt_nbt: ?[]const u8 = null,
};

pub const Entry = union(enum) {
    feature_flags: FeatureFlags,
    known_packs: KnownPacks,
    registry: Registry,
    tags: Tags,
    resource_pack: ResourcePack,
};

pub const Plan = struct {
    entries: []const Entry = &.{},

    pub fn valid(self: Plan) bool {
        if (self.entries.len > maximum_entries) return false;
        for (self.entries) |entry| if (!validEntry(entry)) return false;
        return true;
    }

    pub fn at(self: Plan, index: u8) ?Entry {
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }
};

fn validEntry(entry: Entry) bool {
    return switch (entry) {
        .feature_flags => |flags| validStrings(flags.values),
        .known_packs => |packs| validKnownPacks(packs.values),
        .registry => |registry| registry.id.len != 0 and validRegistryEntries(registry.entries),
        .tags => |tags| tags.payload.len != 0,
        .resource_pack => |pack| pack.url.len != 0 and pack.hash.len != 0,
    };
}

fn validStrings(values: []const []const u8) bool {
    if (values.len == 0) return false;
    for (values) |value| if (value.len == 0) return false;
    return true;
}

fn validKnownPacks(values: []const KnownPack) bool {
    if (values.len == 0) return false;
    for (values) |value| {
        if (value.namespace.len == 0 or value.id.len == 0 or value.version.len == 0) return false;
    }
    return true;
}

fn validRegistryEntries(values: []const RegistryEntry) bool {
    for (values) |value| if (value.id.len == 0) return false;
    return true;
}

test "configuration plan retains caller order" {
    const plan: Plan = .{ .entries = &.{
        .{ .feature_flags = .{ .values = &.{"minecraft:vanilla"} } },
        .{ .known_packs = .{ .values = &.{.{ .namespace = "minecraft", .id = "core", .version = "1.21.6" }} } },
        .{ .tags = .{ .payload = &.{0} } },
    } };
    try @import("std").testing.expect(plan.valid());
    try @import("std").testing.expectEqual(@as(?Entry, plan.entries[1]), plan.at(1));
}

test "configuration plan rejects a schedule beyond its fixed bound" {
    const entries = [_]Entry{.{ .tags = .{ .payload = &.{0} } }} ** (maximum_entries + 1);
    try @import("std").testing.expect(!(Plan{ .entries = &entries }).valid());
}
