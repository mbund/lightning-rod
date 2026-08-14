const std = @import("std");
const mcc = @import("minecraft_conformance");
const t = mcc.testing;

pub const Scenario = struct {
    name: []const u8,
    fixture_id: []const u8,
    vanilla: bool = true,
    run: *const fn (mcc.Adapter, std.mem.Allocator) anyerror!void,
};

pub const all = [_]Scenario{
    .{ .name = "item spawn motion and landing", .fixture_id = "item-motion", .run = itemSpawnMotionAndLanding },
    .{ .name = "compatible item stacks merge", .fixture_id = "item-merge", .run = compatibleItemStacksMerge },
    .{ .name = "item pickup delay and collection", .fixture_id = "item-pickup", .run = itemPickupDelayAndCollection },
    .{ .name = "item despawns at 6000 ticks", .fixture_id = "item-despawn", .run = itemDespawnsAtSixThousandTicks },
    .{ .name = "lighting foundation packets", .fixture_id = "lighting-foundation", .run = lightingFoundationPackets },
    .{ .name = "lighting removal packets", .fixture_id = "lighting-foundation", .run = lightingRemovalPackets },
    .{ .name = "lighting removal preserves overlapping sources", .fixture_id = "lighting-overlap", .run = lightingRemovalPreservesOverlap },
    .{ .name = "two client movement", .fixture_id = "movement-arena", .run = movement },
    .{ .name = "player rotation head and body", .fixture_id = "movement-arena", .run = playerRotation },
    .{ .name = "sneaking synchronization", .fixture_id = "movement-arena", .run = sneakingSynchronization },
    .{ .name = "sprinting synchronization", .fixture_id = "movement-arena", .run = sprintingSynchronization },
    .{ .name = "coalesced survival sprint jump", .fixture_id = "movement-arena", .run = coalescedSurvivalSprintJump },
    .{ .name = "survival mining with correct tool", .fixture_id = "mining-correct-tool", .run = survivalMiningCorrectTool },
    .{ .name = "survival mining with wrong tool", .fixture_id = "mining-wrong-tool", .run = survivalMiningWrongTool },
    .{ .name = "survival mining with empty hand", .fixture_id = "mining-empty-hand", .run = survivalMiningEmptyHand },
    .{ .name = "creative instant mining", .fixture_id = "mining-creative", .run = creativeInstantMining },
    .{ .name = "representative block loot tables", .fixture_id = "block-loot-families", .run = representativeBlockLootTables },
    .{ .name = "mining start and abort", .fixture_id = "mining-correct-tool", .run = miningAbortResetsProgress },
    .{ .name = "craft all", .fixture_id = "craft-all", .run = craftAll },
    .{ .name = "crafting close clears grid", .fixture_id = "crafting-close", .run = craftingClose },
    .{ .name = "two block placement", .fixture_id = "placement-arena", .run = placement },
    .{ .name = "restart persists world and player", .fixture_id = "storage-restart", .vanilla = false, .run = restartPersistsWorldAndPlayer },
    .{ .name = "restart persists item and living entities", .fixture_id = "storage-restart", .vanilla = false, .run = restartPersistsEntities },
    .{ .name = "shared chest inventory", .fixture_id = "chest-arena", .run = sharedChestInventory },
    .{ .name = "restart persists chest inventory", .fixture_id = "chest-arena", .vanilla = false, .run = restartPersistsChestInventory },
    .{ .name = "furnace smelting", .fixture_id = "furnace-arena", .run = furnaceSmelting },
    .{ .name = "restart persists furnace progress", .fixture_id = "furnace-arena", .vanilla = false, .run = restartPersistsFurnaceProgress },
    .{ .name = "chest placement facings", .fixture_id = "chest-placement", .run = chestPlacementFacings },
    .{ .name = "furnace placement facings", .fixture_id = "furnace-placement", .run = furnacePlacementFacings },
    .{ .name = "survival pick block selects matching hotbar stack", .fixture_id = "pick-block", .run = survivalPickBlock },
    .{ .name = "creative pick block creates and selects stack", .fixture_id = "creative-pick-block", .run = creativePickBlock },
    .{ .name = "creative slot changes preserve packet order", .fixture_id = "creative-inventory", .run = creativeSlotChangesPreserveOrder },
    .{ .name = "trapdoor placement and flipping", .fixture_id = "trapdoors", .run = trapdoorPlacementAndFlipping },
    .{ .name = "door placement and flipping", .fixture_id = "doors", .run = doorPlacementAndFlipping },
    .{ .name = "adjacent doors choose opposite hinges", .fixture_id = "doors", .run = adjacentDoorHinges },
    .{ .name = "door placement rejects leaves support", .fixture_id = "doors", .run = doorRejectsLeavesSupport },
    .{ .name = "slab placement and merging", .fixture_id = "slabs", .run = slabPlacementAndMerging },
    .{ .name = "doors require a slab top support face", .fixture_id = "slabs", .run = doorsRequireSlabTopSupport },
    .{ .name = "player disconnect", .fixture_id = "movement-arena", .run = disconnect },
    .{ .name = "login held item", .fixture_id = "login-held", .run = loginHeldItem },
    .{ .name = "gamemode persists across reconnect and restart", .fixture_id = "movement-arena", .vanilla = false, .run = gamemodePersists },
    .{ .name = "player inventory click modes", .fixture_id = "player-inventory-clicks", .run = playerInventoryClickModes },
    .{ .name = "player collision and one block step", .fixture_id = "player-collision", .run = playerCollisionAndStep },
    .{ .name = "zombie knockback", .fixture_id = "combat-arena", .run = zombieKnockback },
    .{ .name = "entity lifecycle replication", .fixture_id = "entity-lifecycle", .run = entityLifecycleReplication },
    .{ .name = "player attacks mob", .fixture_id = "entity-lifecycle", .run = playerAttacksMob },
    .{ .name = "player melee combat", .fixture_id = "player-combat", .run = playerMeleeCombat },
    .{ .name = "player melee death", .fixture_id = "player-combat-death", .run = playerMeleeDeath },
    .{ .name = "mob death and removal", .fixture_id = "mob-death", .run = mobDeathAndRemoval },
    .{ .name = "falling living entities damage die and drop loot", .fixture_id = "falling-cows", .run = fallingLivingEntities },
    .{ .name = "player fall motion and landing", .fixture_id = "player-fall-lanes", .run = playerFallMotionAndLanding },
    .{ .name = "mob attacks player and respawn", .fixture_id = "player-death", .run = mobAttacksPlayerAndRespawn },
    .{ .name = "cow follows wheat", .fixture_id = "cow-temptation", .run = cowFollowsWheat },
    .{ .name = "creative wheat is authoritative", .fixture_id = "creative-wheat", .vanilla = false, .run = creativeWheatIsAuthoritative },
    .{ .name = "cow breeding", .fixture_id = "cow-breeding", .run = cowBreeding },
    .{ .name = "cow panic", .fixture_id = "cow-panic", .run = cowPanic },
    .{ .name = "cow ambient sound", .fixture_id = "cow-look", .run = cowAmbientSound },
    .{ .name = "calf follows parent", .fixture_id = "cow-parent", .run = calfFollowsParent },
    .{ .name = "cow swimming", .fixture_id = "cow-swim", .run = cowSwimming },
    .{ .name = "cow milking", .fixture_id = "cow-milking", .run = cowMilking },
    .{ .name = "calves cannot be milked", .fixture_id = "calf-milking", .run = calfCannotBeMilked },
    .{ .name = "cow idle wandering", .fixture_id = "cow-wandering", .run = cowIdleWandering },
    .{ .name = "cow looks at nearby players", .fixture_id = "cow-look", .run = cowLooksAtPlayer },
    .{ .name = "time command lifecycle", .fixture_id = "time-lifecycle", .run = timeCommandLifecycle },
    .{ .name = "daylight cycle progression", .fixture_id = "time-lifecycle", .run = daylightCycleProgression },
    .{ .name = "disabled daylight cycle", .fixture_id = "frozen-daylight-cycle", .run = disabledDaylightCycle },
    .{ .name = "zombie daylight burning", .fixture_id = "zombie-daylight", .run = zombieDaylightBurning },
    .{ .name = "daytime natural spawning", .fixture_id = "natural-spawning-day", .run = daytimeNaturalSpawning },
    .{ .name = "nighttime natural spawning", .fixture_id = "natural-spawning-night", .run = nighttimeNaturalSpawning },
    .{ .name = "broken oak sapling drops itself", .fixture_id = "oak-sapling-break", .run = brokenOakSaplingDropsItself },
    .{ .name = "oak leaf drop distribution", .fixture_id = "oak-leaf-drops", .run = oakLeafDropDistribution },
    .{ .name = "zombie open trapdoor", .fixture_id = "zombie-open-trapdoor", .run = zombieOpenTrapdoor },
    .{ .name = "campfire smoke is client-side", .fixture_id = "campfire", .run = campfireSmokeIsClientSide },
    .{ .name = "survival flight rejected", .fixture_id = "movement-arena", .vanilla = false, .run = flightRejected },
    .{ .name = "survival hover rejected", .fixture_id = "flight-arena", .vanilla = false, .run = hoverRejected },
    .{ .name = "remote mining rejected", .fixture_id = "reach-arena", .vanilla = false, .run = remoteMiningRejected },
    .{ .name = "inventory claim rejected", .fixture_id = "flat-world", .vanilla = false, .run = inventoryClaimRejected },
    .{ .name = "random tick mechanics", .fixture_id = "random-mechanics", .run = randomTickMechanics },
};

const LightObservation = struct {
    roof_open: bool = false,
    roof_blocked: bool = false,
    source: bool = false,
    opaque_blocked: bool = false,
    boundary: bool = false,

    fn complete(self: LightObservation) bool {
        return self.roof_open and self.roof_blocked and self.source and self.opaque_blocked and self.boundary;
    }
};

fn lightingFoundationPackets(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "lighting-foundation", &clients);
    defer target.deinit();

    var alice = LightObservation{};
    var bob = LightObservation{};
    for (clients) |client| {
        try target.control(client.name, .disconnect);
        var disconnected = try target.tick();
        disconnected.deinit();
        try target.control(client.name, .reconnect);
        for (0..16) |_| {
            var batch = try target.tick();
            defer batch.deinit();
            const observation = if (std.mem.eql(u8, client.name, "alice")) &alice else &bob;
            try observeInitialLight(&batch, client.name, allocator, observation);
            if (observation.complete()) break;
        }
    }
    if (!alice.complete() or !bob.complete()) std.debug.print(
        "incomplete initial lighting observations: alice={any} bob={any}\n",
        .{ alice, bob },
    );
    try expect(alice.complete());
    try expect(bob.complete());
}

fn lightingRemovalPackets(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "lighting-foundation", &clients);
    defer target.deinit();
    try target.send("alice", .{ .move = .{
        .position = .{ .x = 15.5, .y = 81, .z = 3.5 },
        .on_ground = true,
    } });
    var grounded = try target.tick();
    grounded.deinit();
    try target.send("alice", .{ .player_action = .{
        .action = .start_destroy_block,
        .position = .{ .x = 15, .y = 81, .z = 0 },
    } });
    var removal_observed = [_]bool{false} ** clients.len;
    for (0..16) |_| {
        var removed = try target.tick();
        defer removed.deinit();
        for (clients, 0..) |client, client_index| {
            removal_observed[client_index] = removal_observed[client_index] or
                removed.first(.{
                    .recipient = client.name,
                    .name = "block_changed",
                    .field_name = "state",
                    .field_value = "minecraft:air",
                }) != null;
        }
        if (removal_observed[0] and removal_observed[1]) break;
    }
    for (removal_observed) |observed| if (!observed) return error.TorchWasNotRemoved;

    for (clients) |client| {
        try target.control(client.name, .disconnect);
        var disconnected = try target.tick();
        disconnected.deinit();
        try target.control(client.name, .reconnect);
        var source_zero = false;
        var boundary_zero = false;
        for (0..16) |_| {
            var batch = try target.tick();
            defer batch.deinit();
            var packets = batch.iterator(.{ .recipient = client.name, .name = "wire/map_chunk" });
            while (packets.next()) |packet| {
                const chunk_x = try wireInteger(packet, i32, "x");
                if (try wireInteger(packet, i32, "z") != 0) continue;
                if (chunk_x == 0) {
                    try expectLight(packet, allocator, .block, 15, 81, 0, 0);
                    source_zero = true;
                } else if (chunk_x == 1) {
                    try expectLight(packet, allocator, .block, 16, 81, 0, 0);
                    boundary_zero = true;
                }
            }
            if (source_zero and boundary_zero) break;
        }
        try expect(source_zero and boundary_zero);
    }
}

fn lightingRemovalPreservesOverlap(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "lighting-overlap", &clients);
    defer target.deinit();
    try target.send("alice", .{ .player_action = .{
        .action = .start_destroy_block,
        .position = .{ .x = 0, .y = 81, .z = 0 },
    } });
    var removed = false;
    for (0..8) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        removed = removed or batch.first(.{
            .recipient = "alice",
            .name = "block_changed",
            .field_name = "state",
            .field_value = "minecraft:air",
        }) != null;
        if (removed) break;
    }
    try expect(removed);

    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var observed = false;
    for (0..16) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var packets = batch.iterator(.{
            .recipient = "alice",
            .name = "wire/map_chunk",
        });
        while (packets.next()) |packet| {
            if (try wireInteger(packet, i32, "x") != 0 or
                try wireInteger(packet, i32, "z") != 0)
                continue;
            try expectLight(packet, allocator, .block, 0, 81, 0, 10);
            try expectLight(packet, allocator, .block, 4, 81, 0, 14);
            observed = true;
        }
        if (observed) break;
    }
    try expect(observed);

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 80, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var added = false;
    for (0..8) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        const changed = batch.first(.{
            .recipient = "alice",
            .name = "block_changed",
            .field_name = "position",
            .field_value = "0,81,0",
        });
        if (changed) |packet| {
            try expectText("minecraft:torch", packet.field("state"));
            added = true;
            break;
        }
    }
    try expect(added);

    try target.control("alice", .disconnect);
    var disconnected_again = try target.tick();
    disconnected_again.deinit();
    try target.control("alice", .reconnect);
    var addition_observed = false;
    for (0..16) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var packets = batch.iterator(.{
            .recipient = "alice",
            .name = "wire/map_chunk",
        });
        while (packets.next()) |packet| {
            if (try wireInteger(packet, i32, "x") != 0 or
                try wireInteger(packet, i32, "z") != 0)
                continue;
            try expectLight(packet, allocator, .block, 0, 81, 0, 14);
            addition_observed = true;
        }
        if (addition_observed) break;
    }
    try expect(addition_observed);
}

fn observeInitialLight(
    batch: *const t.Batch,
    recipient: []const u8,
    allocator: std.mem.Allocator,
    observation: *LightObservation,
) !void {
    var packets = batch.iterator(.{ .recipient = recipient, .name = "wire/map_chunk" });
    while (packets.next()) |packet| {
        const chunk_x = try wireInteger(packet, i32, "x");
        const chunk_z = try wireInteger(packet, i32, "z");
        if (chunk_z != 0) continue;
        if (chunk_x == 0) {
            try expectLight(packet, allocator, .sky, 7, 81, 7, 15);
            observation.roof_open = true;
            try expectLight(packet, allocator, .sky, 7, 79, 7, 0);
            observation.roof_blocked = true;
            try expectLight(packet, allocator, .block, 15, 81, 0, 14);
            observation.source = true;
            try expectLight(packet, allocator, .block, 14, 81, 0, 0);
            observation.opaque_blocked = true;
        } else if (chunk_x == 1) {
            try expectLight(packet, allocator, .block, 16, 81, 0, 13);
            observation.boundary = true;
        }
    }
}

const LightKind = enum { sky, block };

fn expectLight(
    packet: *const t.Packet,
    allocator: std.mem.Allocator,
    kind: LightKind,
    x: i32,
    y: i16,
    z: i32,
    expected: u8,
) !void {
    const actual = try packetLight(packet, allocator, kind, x, y, z);
    if (actual != expected) {
        std.debug.print(
            "light mismatch packet={s} kind={s} position={d},{d},{d}: expected {d}, got {d}\n",
            .{ packet.name, @tagName(kind), x, y, z, expected, actual },
        );
        return error.ConformanceAssertionFailed;
    }
}

fn packetLight(
    packet: *const t.Packet,
    allocator: std.mem.Allocator,
    kind: LightKind,
    x: i32,
    y: i16,
    z: i32,
) !u8 {
    const mask_name = if (kind == .sky) "skyLightMask" else "blockLightMask";
    const empty_name = if (kind == .sky) "emptySkyLightMask" else "emptyBlockLightMask";
    const arrays_name = if (kind == .sky) "skyLight" else "blockLight";
    const mask = try wireMask(packet, allocator, mask_name);
    const empty_mask = try wireMask(packet, allocator, empty_name);
    const protocol_section: usize = @intCast(@divFloor(@as(i32, y) + 64, 16) + 1);
    const section_bit = @as(u32, 1) << @intCast(protocol_section);
    if (mask & section_bit == 0) {
        if (empty_mask & section_bit != 0) return 0;
        std.debug.print(
            "missing light section packet={s} kind={s} position={d},{d},{d} mask=0x{x} empty=0x{x} wanted=0x{x}\n",
            .{ packet.name, @tagName(kind), x, y, z, mask, empty_mask, section_bit },
        );
        return error.LightSectionNotPresent;
    }

    const encoded = try packet.wireBytes(allocator, arrays_name);
    defer allocator.free(encoded);
    var rest: []const u8 = encoded;
    const count = try readVarInt(&rest);
    if (count < 0) return error.InvalidLightArrayCount;
    const array_count: usize = @intCast(count);
    const wanted_array = @popCount(mask & (section_bit - 1));
    if (wanted_array >= array_count) return error.InvalidLightArrayCount;
    for (0..array_count) |array_index| {
        const length = try readVarInt(&rest);
        if (length < 0 or @as(usize, @intCast(length)) > rest.len) return error.InvalidLightArray;
        const bytes = rest[0..@intCast(length)];
        rest = rest[@intCast(length)..];
        if (array_index != wanted_array) continue;
        if (bytes.len != 2048) return error.InvalidLightArray;
        const local_index: usize = @as(usize, @intCast(x & 15)) |
            (@as(usize, @intCast(z & 15)) << 4) |
            (@as(usize, @intCast((@as(i32, y) + 64) & 15)) << 8);
        const byte = bytes[local_index >> 1];
        return if (local_index & 1 == 0) byte & 15 else byte >> 4;
    }
    return error.LightSectionNotPresent;
}

fn wireMask(packet: *const t.Packet, allocator: std.mem.Allocator, name: []const u8) !u32 {
    const encoded = try packet.wireBytes(allocator, name);
    defer allocator.free(encoded);
    var rest: []const u8 = encoded;
    const count = try readVarInt(&rest);
    if (count == 0) return 0;
    if (count != 1 or rest.len != 8) return error.InvalidLightMask;
    return @truncate(std.mem.readInt(u64, rest[0..8], .big));
}

fn wireInteger(packet: *const t.Packet, comptime T: type, name: []const u8) !T {
    return std.fmt.parseInt(T, packet.wireField(name) orelse return error.MissingCanonicalField, 10) catch
        error.InvalidCanonicalInteger;
}

fn readVarInt(rest: *[]const u8) !i32 {
    var value: u32 = 0;
    for (0..5) |index| {
        if (rest.len == 0) return error.InvalidVarInt;
        const byte = rest.*[0];
        rest.* = rest.*[1..];
        value |= @as(u32, byte & 0x7f) << @intCast(index * 7);
        if (byte & 0x80 == 0) return @bitCast(value);
    }
    return error.InvalidVarInt;
}

pub fn find(name: []const u8) ?*const Scenario {
    for (&all) |*scenario| if (std.mem.eql(u8, scenario.name, name)) return scenario;
    return null;
}

fn harness(allocator: std.mem.Allocator, adapter: mcc.Adapter, fixture_id: []const u8, clients: []const t.Client) !t.Harness {
    return t.Harness.init(allocator, adapter, mcc.fixture.builtin(fixture_id) orelse return error.UnknownFixture, clients);
}

fn expect(condition: bool) !void {
    if (!condition) return error.ConformanceAssertionFailed;
}

fn expectText(expected: []const u8, actual: ?[]const u8) !void {
    const value = actual orelse return error.MissingCanonicalField;
    if (!std.mem.eql(u8, expected, value)) {
        std.debug.print("canonical value mismatch: expected '{s}', got '{s}'\n", .{ expected, value });
        return error.ConformanceAssertionFailed;
    }
}

fn expectSlot(packet: *const t.Packet, slot: []const u8, stack: []const u8) !void {
    try expectText(stack, packet.inventorySlot(slot));
}

fn expectSlotUpdates(batch: *const t.Batch, recipient: []const u8, slot: []const u8, stack: []const u8) !void {
    var updates = batch.iterator(.{
        .recipient = recipient,
        .name = "inventory_slot",
        .field_name = "slot",
        .field_value = slot,
    });
    var count: usize = 0;
    while (updates.next()) |update| {
        try expectText(stack, update.field("stack"));
        count += 1;
    }
    if (count == 0) return error.MissingInventorySlotUpdate;
}

fn itemSpawnMotionAndLanding(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "item-motion", &clients);
    defer target.deinit();

    var spawn_seen = [_]bool{false} ** clients.len;
    var stack_seen = [_]bool{false} ** clients.len;
    var movement_seen = [_]bool{false} ** clients.len;
    var fell = [_]bool{false} ** clients.len;
    var landed = [_]bool{false} ** clients.len;
    var last_position = [_]t.Vec3{.{ .x = 0, .y = 0, .z = 0 }} ** clients.len;

    for (0..80) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        for (clients, 0..) |client, recipient_index| {
            if (batch.first(.{
                .recipient = client.name,
                .name = "entity_spawned",
                .field_name = "subject",
                .field_value = "falling-stack",
            })) |spawn| {
                try expectText("minecraft:item", spawn.field("type"));
                const x = try spawn.fieldFloat("x");
                const y = try spawn.fieldFloat("y");
                const z = try spawn.fieldFloat("z");
                if (@abs(x - 0.5) > 1.0 / 4096.0 or
                    @abs(y - 67) > 1.0 / 4096.0 or
                    @abs(z - 0.5) > 1.0 / 4096.0)
                    return error.InvalidInitialItemPosition;
                if (@abs((try spawn.fieldFloat("velocity_x")) - 0.1) > 1.0 / 8000.0 or
                    @abs((try spawn.fieldFloat("velocity_y")) - 0.2) > 1.0 / 8000.0 or
                    @abs(try spawn.fieldFloat("velocity_z")) > 1.0 / 8000.0)
                    return error.InvalidInitialItemVelocity;
                spawn_seen[recipient_index] = true;
            }
            if (batch.first(.{
                .recipient = client.name,
                .name = "item_spawned",
                .field_name = "subject",
                .field_value = "falling-stack",
            })) |metadata| {
                try expectText("minecraft:oak_log*3", metadata.field("stack"));
                stack_seen[recipient_index] = true;
            }
            var movements = batch.iterator(.{
                .recipient = client.name,
                .name = "entity_moved",
                .field_name = "subject",
                .field_value = "falling-stack",
            });
            while (movements.next()) |packet| {
                const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
                if (movement_seen[recipient_index]) {
                    if (position.y < last_position[recipient_index].y) fell[recipient_index] = true;
                }
                movement_seen[recipient_index] = true;
                last_position[recipient_index] = position;
                if (@abs(position.y - 65) <= 1.0 / 4096.0) landed[recipient_index] = true;
            }
        }
        if (spawn_seen[0] and spawn_seen[1] and stack_seen[0] and stack_seen[1] and landed[0] and landed[1]) break;
    }

    for (0..clients.len) |index| {
        if (!spawn_seen[index]) return error.MissingItemSpawn;
        if (!stack_seen[index]) return error.MissingInitialItemStack;
        if (!movement_seen[index]) return error.MissingItemMovement;
        if (!fell[index]) return error.ItemDidNotFall;
        if (!landed[index]) return error.ItemDidNotLand;
        if (last_position[index].x <= 0.5) return error.ItemDidNotMoveHorizontally;
        if (@abs(last_position[index].z - 0.5) > 1.0 / 4096.0) return error.ItemDriftedAcrossAxis;
    }
    if (@abs(last_position[0].x - last_position[1].x) > 1.0 / 4096.0 or
        @abs(last_position[0].y - last_position[1].y) > 1.0 / 4096.0 or
        @abs(last_position[0].z - last_position[1].z) > 1.0 / 4096.0)
        return error.InconsistentItemProjection;
}

fn compatibleItemStacksMerge(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "item-merge", &clients);
    defer target.deinit();

    var left_seen = [_]bool{false} ** clients.len;
    var right_seen = [_]bool{false} ** clients.len;
    var updated = [_]bool{false} ** clients.len;
    var removed = [_]bool{false} ** clients.len;
    var merge_tick: ?usize = null;
    var removal_tick: ?usize = null;

    for (0..45) |tick_index| {
        var batch = try target.tick();
        defer batch.deinit();
        for (clients, 0..) |client, recipient_index| {
            if (batch.first(.{ .recipient = client.name, .name = "item_spawned", .field_name = "subject", .field_value = "merge-left" })) |packet| {
                try expectText("minecraft:oak_log*10", packet.field("stack"));
                left_seen[recipient_index] = true;
            }
            if (batch.first(.{ .recipient = client.name, .name = "item_spawned", .field_name = "subject", .field_value = "merge-right" })) |packet| {
                try expectText("minecraft:oak_log*20", packet.field("stack"));
                right_seen[recipient_index] = true;
            }

            var changes = batch.iterator(.{ .recipient = client.name, .name = "item_stack_changed" });
            while (changes.next()) |packet| {
                try expectText("minecraft:oak_log*30", packet.field("stack"));
                try expectText("merge-right", packet.field("subject"));
                updated[recipient_index] = true;
                if (merge_tick) |expected_tick| {
                    try expect(expected_tick == tick_index);
                } else {
                    merge_tick = tick_index;
                }
            }

            if (batch.first(.{ .recipient = client.name, .name = "entity_destroy" })) |packet| {
                try expectText("merge-left", packet.field("subjects"));
                removed[recipient_index] = true;
                if (removal_tick) |expected_tick| try expect(expected_tick == tick_index) else removal_tick = tick_index;
            }
        }
        if (updated[0] and updated[1] and removed[0] and removed[1]) break;
    }

    for (0..clients.len) |index| {
        if (!left_seen[index]) return error.MissingLeftItemSpawn;
        if (!right_seen[index]) return error.MissingRightItemSpawn;
        if (!updated[index]) return error.MissingMergedItemMetadata;
        if (!removed[index]) return error.MissingMergedItemRemoval;
    }
    try expect(removal_tick == 39);
    try expect(merge_tick == 40);
}

fn itemPickupDelayAndCollection(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "item-pickup", &clients);
    defer target.deinit();

    var delayed = try target.tick();
    defer delayed.deinit();
    try expect(delayed.count(.{ .name = "item_collected", .field_name = "subject", .field_value = "delayed-stack" }) == 0);
    try expect(delayed.count(.{ .name = "entity_destroy", .field_name = "subjects", .field_value = "delayed-stack" }) == 0);

    var collected = try target.tick();
    defer collected.deinit();
    for (clients) |client| {
        const packet = try collected.one(.{
            .recipient = client.name,
            .name = "item_collected",
            .field_name = "subject",
            .field_value = "delayed-stack",
        });
        try expectText("alice", packet.field("collector"));
        if (try packet.fieldInt(u8, "count") != 3) return error.InvalidCollectedItemCount;
        _ = try collected.one(.{
            .recipient = client.name,
            .name = "entity_destroy",
            .field_name = "subjects",
            .field_value = "delayed-stack",
        });
    }
    if (!batchHasInventoryStack(&collected, "alice", "h0", "minecraft:oak_log*3"))
        return error.MissingPickupInventoryProjection;
    if (batchHasInventoryStack(&collected, "bob", "h0", "minecraft:oak_log*3"))
        return error.PeerReceivedCollectorInventory;

    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var rejoined = try target.tick();
    defer rejoined.deinit();
    if (!batchHasInventoryStack(&rejoined, "alice", "h0", "minecraft:oak_log*3"))
        return error.CollectedItemMissingFromAuthoritativeInventory;
}

fn itemDespawnsAtSixThousandTicks(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "item-despawn", &clients);
    defer target.deinit();

    var age_5999 = try target.tick();
    defer age_5999.deinit();
    for (clients) |client| {
        _ = age_5999.first(.{
            .recipient = client.name,
            .name = "item_spawned",
            .field_name = "subject",
            .field_value = "expiring-stack",
        }) orelse return error.MissingExpiringItemBeforeBoundary;
        try expect(age_5999.count(.{
            .recipient = client.name,
            .name = "entity_destroy",
            .field_name = "subjects",
            .field_value = "expiring-stack",
        }) == 0);
    }

    var age_6000 = try target.tick();
    defer age_6000.deinit();
    for (clients) |client| {
        _ = try age_6000.one(.{
            .recipient = client.name,
            .name = "entity_destroy",
            .field_name = "subjects",
            .field_value = "expiring-stack",
        });
    }
}

fn batchHasInventoryStack(batch: *const t.Batch, recipient: []const u8, slot: []const u8, stack: []const u8) bool {
    var inventories = batch.iterator(.{ .recipient = recipient, .name = "inventory" });
    while (inventories.next()) |packet|
        if (packet.inventorySlot(slot)) |actual| if (std.mem.eql(u8, actual, stack)) return true;
    var slots = batch.iterator(.{ .recipient = recipient, .name = "inventory_slot", .field_name = "slot", .field_value = slot });
    while (slots.next()) |packet|
        if (packet.field("stack")) |actual| if (std.mem.eql(u8, actual, stack)) return true;
    return false;
}

fn playerInventoryClickModes(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{
        .{ .name = "alice" },
        .{ .name = "bob" },
        .{ .name = "carol" },
        .{ .name = "dave" },
        .{ .name = "erin" },
    };
    var target = try harness(allocator, adapter, "player-inventory-clicks", &clients);
    defer target.deinit();

    try target.send("alice", .{ .container_click = .{ .slot = 36, .button = 0, .mode = 0 } });
    try target.send("bob", .{ .container_click = .{ .slot = 36, .button = 1, .mode = 0 } });
    try target.send("carol", .{ .container_click = .{ .slot = 9, .button = 0, .mode = 1 } });
    try target.send("dave", .{ .container_click = .{ .slot = 9, .button = 2, .mode = 2 } });
    try target.send("erin", .{ .container_click = .{ .slot = 36, .button = 0, .mode = 4 } });

    var batch = try target.tick();
    defer batch.deinit();
    if (!batchHasInventoryStack(&batch, "alice", "h0", "empty") or
        !batchHasInventoryStack(&batch, "alice", "c", "minecraft:oak_log*9"))
        return error.LeftClickDidNotPickUpStack;
    if (!batchHasInventoryStack(&batch, "bob", "h0", "minecraft:oak_log*4") or
        !batchHasInventoryStack(&batch, "bob", "c", "minecraft:oak_log*5"))
        return error.RightClickDidNotSplitStack;
    if (!batchHasInventoryStack(&batch, "carol", "m0", "empty") or
        !batchHasInventoryStack(&batch, "carol", "h0", "minecraft:oak_log*62"))
        return error.ShiftClickDidNotMergeStack;
    if (!batchHasInventoryStack(&batch, "dave", "m0", "minecraft:stone*3") or
        !batchHasInventoryStack(&batch, "dave", "h2", "minecraft:dirt*4"))
        return error.NumberKeyDidNotSwapStack;
    if (!batchHasInventoryStack(&batch, "erin", "h0", "minecraft:oak_log*2"))
        return error.ThrowClickDidNotRemoveOneItem;
    for (clients) |client| {
        const item = batch.first(.{ .recipient = client.name, .name = "item_spawned" }) orelse
            return error.ThrowClickDidNotSpawnItem;
        try expectText("minecraft:oak_log*1", item.field("stack"));
    }
}

fn playerCollisionAndStep(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" }, .{ .name = "observer" } };
    var target = try harness(allocator, adapter, "player-collision", &clients);
    defer target.deinit();

    try target.send("alice", .{ .move = .{
        .position = .{ .x = 1.5, .y = 65, .z = 0.5 },
        .on_ground = true,
    } });
    try target.send("bob", .{ .move = .{
        .position = .{ .x = 5.5, .y = 66, .z = 0.5 },
        .on_ground = true,
    } });
    var batch = try target.tick();
    defer batch.deinit();

    const correction = batch.first(.{ .recipient = "alice", .name = "player_position" }) orelse
        return error.MissingCollisionCorrection;
    try expectText("0.5", correction.field("x"));
    try expectText("65", correction.field("y"));
    if (batch.count(.{ .recipient = "observer", .name = "entity_moved", .field_name = "subject", .field_value = "alice" }) != 0)
        return error.CollidingMovementWasReplicated;
    if (batch.count(.{ .recipient = "bob", .name = "player_position" }) != 0)
        return error.ValidStepWasRejected;
    const stepped = batch.first(.{
        .recipient = "observer",
        .name = "entity_moved",
        .field_name = "subject",
        .field_value = "bob",
    }) orelse return error.ValidStepWasNotReplicated;
    const position = try parseCanonicalVec3(stepped.field("position") orelse return error.MissingCanonicalField);
    if (@abs(position.x - 5.5) > 1.0 / 4096.0 or
        @abs(position.y - 66) > 1.0 / 4096.0 or
        @abs(position.z - 0.5) > 1.0 / 4096.0)
        return error.InvalidSteppedPosition;
}

fn expectTimeUpdate(batch: *const t.Batch, recipient: []const u8, game_time: i64, day_time: i64, daylight_cycle: bool) !void {
    const packet = try batch.one(.{ .recipient = recipient, .name = "time_update" });
    try expect(game_time == try packet.fieldInt(i64, "game_time"));
    try expect(day_time == try packet.fieldInt(i64, "day_time"));
    try expect(daylight_cycle == ((try packet.fieldInt(u1, "daylight_cycle")) != 0));
}

fn expectSystemMessage(batch: *const t.Batch, expected: []const u8) !void {
    try expectText(expected, (try batch.one(.{ .recipient = "alice", .name = "system_chat" })).field("message"));
}

fn timeCommandLifecycle(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "time-lifecycle", &clients);
    defer target.deinit();

    var initial = try target.tick();
    defer initial.deinit();
    try expectTimeUpdate(&initial, "alice", 0, 11_999, true);
    try expectTimeUpdate(&initial, "bob", 0, 11_999, true);

    try target.send("alice", .{ .command = "time set night" });
    var set = try target.tick();
    defer set.deinit();
    try expectTimeUpdate(&set, "alice", 1, 13_000, true);
    try expectTimeUpdate(&set, "bob", 1, 13_000, true);
    try expectSystemMessage(&set, "Set%20the%20time%20to%2013000");

    try target.send("alice", .{ .command = "time add 250" });
    var add = try target.tick();
    defer add.deinit();
    try expectTimeUpdate(&add, "alice", 2, 13_251, true);
    try expectTimeUpdate(&add, "bob", 2, 13_251, true);
    try expectSystemMessage(&add, "Added%20250%20to%20the%20time");

    try target.send("alice", .{ .command = "time query daytime" });
    var query_daytime = try target.tick();
    defer query_daytime.deinit();
    try expectSystemMessage(&query_daytime, "The%20time%20is%2013252");

    try target.send("alice", .{ .command = "time query gametime" });
    var query_gametime = try target.tick();
    defer query_gametime.deinit();
    try expectSystemMessage(&query_gametime, "The%20time%20is%204");

    try target.send("alice", .{ .command = "time set 49000" });
    var set_numeric = try target.tick();
    defer set_numeric.deinit();
    try expectTimeUpdate(&set_numeric, "alice", 5, 49_000, true);

    try target.send("alice", .{ .command = "time query day" });
    var query_day = try target.tick();
    defer query_day.deinit();
    try expectSystemMessage(&query_day, "The%20time%20is%202");
}

fn daylightCycleProgression(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "time-lifecycle", &clients);
    defer target.deinit();

    var initial = try target.tick();
    defer initial.deinit();
    try expectTimeUpdate(&initial, "alice", 0, 11_999, true);
    for (0..19) |_| {
        var quiet = try target.tick();
        defer quiet.deinit();
        try expect(quiet.count(.{ .recipient = "alice", .name = "time_update" }) == 0);
    }
    var periodic = try target.tick();
    defer periodic.deinit();
    try expectTimeUpdate(&periodic, "alice", 20, 12_019, true);
}

fn disabledDaylightCycle(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "frozen-daylight-cycle", &clients);
    defer target.deinit();

    var initial = try target.tick();
    defer initial.deinit();
    try expectTimeUpdate(&initial, "alice", 0, 6_000, false);
    for (0..19) |_| {
        var quiet = try target.tick();
        defer quiet.deinit();
    }
    var periodic = try target.tick();
    defer periodic.deinit();
    try expectTimeUpdate(&periodic, "alice", 20, 6_000, false);
}

fn zombieDaylightBurning(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "zombie-daylight", &clients);
    defer target.deinit();

    var ignited = false;
    var damaged = false;
    var died = false;
    var removed = false;
    var rotten_flesh_stacks: usize = 0;
    for (0..600) |_| {
        var day = try target.tick();
        defer day.deinit();
        if (day.first(.{ .recipient = "alice", .name = "entity_state", .field_name = "on_fire", .field_value = "1" })) |packet| {
            try expectText("zombie", packet.field("subject"));
            ignited = true;
        }
        damaged = damaged or day.first(.{
            .recipient = "alice",
            .name = "entity_damaged",
            .field_name = "subject",
            .field_value = "zombie",
        }) != null;
        if (day.first(.{
            .recipient = "alice",
            .name = "entity_status",
            .field_name = "subject",
            .field_value = "zombie",
        })) |status| {
            died = died or std.mem.eql(u8, status.field("status") orelse "", "3");
        }
        if (day.first(.{ .recipient = "alice", .name = "entity_destroy" })) |destroyed|
            removed = removed or std.mem.eql(u8, destroyed.field("subjects") orelse "", "zombie");
        var spawns = day.iterator(.{ .recipient = "alice", .name = "item_spawned" });
        while (spawns.next()) |spawn| {
            const stack = spawn.field("stack") orelse continue;
            if (!std.mem.startsWith(u8, stack, "minecraft:rotten_flesh*")) continue;
            rotten_flesh_stacks += 1;
            const count = try std.fmt.parseInt(u8, stack["minecraft:rotten_flesh*".len..], 10);
            try expect(count >= 1 and count <= 2);
        }
        if (removed) break;
    }
    if (!ignited) return error.MissingZombieDaylightIgnition;
    if (!damaged) return error.MissingZombieDaylightDamage;
    if (!died) return error.MissingZombieDaylightDeath;
    if (!removed) return error.MissingZombieDaylightRemoval;
    if (rotten_flesh_stacks > 1) return error.RepeatedZombieDaylightLoot;
}

fn observeNaturalSpawns(batch: *const t.Batch, saw_passive: *bool, saw_zombie: *bool) void {
    var spawns = batch.iterator(.{ .recipient = "alice", .name = "entity_spawned" });
    while (spawns.next()) |packet| {
        const entity_type = packet.field("type") orelse continue;
        saw_passive.* = saw_passive.* or std.mem.eql(u8, entity_type, "minecraft:cow") or std.mem.eql(u8, entity_type, "minecraft:pig");
        saw_zombie.* = saw_zombie.* or std.mem.eql(u8, entity_type, "minecraft:zombie");
    }
}

fn daytimeNaturalSpawning(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "natural-spawning-day", &clients);
    defer target.deinit();
    var saw_passive = false;
    var saw_zombie = false;
    var saw_exposed_zombie = false;
    for (0..401) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        observeNaturalSpawns(&batch, &saw_passive, &saw_zombie);
        var spawns = batch.iterator(.{
            .recipient = "alice",
            .name = "entity_spawned",
            .field_name = "type",
            .field_value = "minecraft:zombie",
        });
        while (spawns.next()) |spawn| {
            const x = try spawn.fieldFloat("x");
            const y = try spawn.fieldFloat("y");
            const z = try spawn.fieldFloat("z");
            saw_exposed_zombie = saw_exposed_zombie or
                (x >= -40 and x <= 41 and z >= -40 and z <= 41 and y >= 65);
        }
    }
    if (!saw_passive) return error.MissingPassiveNaturalSpawn;
    if (saw_exposed_zombie) return error.ExposedDaytimeZombieSpawn;
}

fn nighttimeNaturalSpawning(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "natural-spawning-night", &clients);
    defer target.deinit();
    var saw_passive = false;
    var saw_zombie = false;
    for (0..401) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        observeNaturalSpawns(&batch, &saw_passive, &saw_zombie);
        if (saw_passive and saw_zombie) return;
    }
    try expect(saw_passive);
    try expect(saw_zombie);
}

const RandomTickExpectation = struct {
    name: []const u8,
    state_prefix: []const u8,
    min_y: i16,
    max_y: i16,
    found: bool = false,
};

fn randomTickMechanics(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "random-mechanics", &clients);
    defer target.deinit();

    var expected = [_]RandomTickExpectation{
        .{ .name = "crop growth", .state_prefix = "minecraft:wheat[age=1", .min_y = 80, .max_y = 80 },
        .{ .name = "oak sapling grows a tree", .state_prefix = "minecraft:oak_log[", .min_y = 65, .max_y = 72 },
        .{ .name = "crop uproot", .state_prefix = "minecraft:air", .min_y = 84, .max_y = 84 },
        .{ .name = "mushroom spread", .state_prefix = "minecraft:brown_mushroom", .min_y = 87, .max_y = 91 },
        .{ .name = "mushroom uproot", .state_prefix = "minecraft:air", .min_y = 92, .max_y = 92 },
        .{ .name = "vine spread", .state_prefix = "minecraft:vine[", .min_y = 94, .max_y = 94 },
        .{ .name = "ice melt", .state_prefix = "minecraft:water[", .min_y = 112, .max_y = 112 },
        .{ .name = "snow melt", .state_prefix = "minecraft:air", .min_y = 116, .max_y = 116 },
        .{ .name = "farmland hydration", .state_prefix = "minecraft:farmland[moisture=7", .min_y = 118, .max_y = 118 },
        .{ .name = "farmland drying", .state_prefix = "minecraft:farmland[moisture=6", .min_y = 120, .max_y = 120 },
        .{ .name = "cactus growth", .state_prefix = "minecraft:cactus[", .min_y = 125, .max_y = 125 },
        .{ .name = "sugar cane growth", .state_prefix = "minecraft:sugar_cane[", .min_y = 129, .max_y = 129 },
        .{ .name = "kelp growth", .state_prefix = "minecraft:kelp[", .min_y = 133, .max_y = 133 },
        .{ .name = "bamboo sapling growth", .state_prefix = "minecraft:bamboo[", .min_y = 137, .max_y = 137 },
        .{ .name = "bamboo growth", .state_prefix = "minecraft:bamboo[", .min_y = 141, .max_y = 141 },
        .{ .name = "chorus flower growth", .state_prefix = "minecraft:chorus_flower[", .min_y = 145, .max_y = 145 },
        .{ .name = "mangrove propagule growth", .state_prefix = "minecraft:mangrove_propagule[age=1", .min_y = 146, .max_y = 146 },
        .{ .name = "sweet berry growth", .state_prefix = "minecraft:sweet_berry_bush[age=1", .min_y = 152, .max_y = 152 },
        .{ .name = "mycelium decay", .state_prefix = "minecraft:dirt", .min_y = 149, .max_y = 149 },
        .{ .name = "grass decay", .state_prefix = "minecraft:dirt", .min_y = 155, .max_y = 155 },
        .{ .name = "mycelium spread", .state_prefix = "minecraft:mycelium[", .min_y = 157, .max_y = 157 },
        .{ .name = "grass spread", .state_prefix = "minecraft:grass_block[", .min_y = 159, .max_y = 159 },
        .{ .name = "nylium decay", .state_prefix = "minecraft:netherrack", .min_y = 163, .max_y = 163 },
        .{ .name = "sapling growth", .state_prefix = "minecraft:oak_sapling[stage=1", .min_y = 168, .max_y = 168 },
        .{ .name = "fire spread", .state_prefix = "minecraft:fire[", .min_y = 75, .max_y = 75 },
        .{ .name = "lava ignition", .state_prefix = "minecraft:fire[", .min_y = 173, .max_y = 176 },
        .{ .name = "lit redstone ore turns off", .state_prefix = "minecraft:redstone_ore[lit=false", .min_y = 175, .max_y = 175 },
        .{ .name = "turtle egg cracks", .state_prefix = "minecraft:turtle_egg[eggs=1,hatch=1", .min_y = 198, .max_y = 198 },
        .{ .name = "turtle egg block hatches", .state_prefix = "minecraft:air", .min_y = 201, .max_y = 201 },
        .{ .name = "budding amethyst growth", .state_prefix = "minecraft:small_amethyst_bud[", .min_y = 202, .max_y = 204 },
        .{ .name = "copper oxidation", .state_prefix = "minecraft:exposed_copper", .min_y = 207, .max_y = 207 },
        .{ .name = "mud dries into clay", .state_prefix = "minecraft:clay", .min_y = 211, .max_y = 211 },
        .{ .name = "pointed dripstone growth", .state_prefix = "minecraft:pointed_dripstone[", .min_y = 214, .max_y = 214 },
        .{ .name = "pointed dripstone fills cauldron", .state_prefix = "minecraft:water_cauldron[level=1", .min_y = 218, .max_y = 218 },
    };
    var saw_portal_piglin = false;
    var saw_turtle = false;
    var saw_grass_decay_control = false;

    for (0..2000) |_| {
        var batch = try target.tick();
        defer batch.deinit();

        var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed" });
        while (changes.next()) |packet| {
            const state = packet.field("state") orelse continue;
            const position = packet.field("position") orelse continue;
            try validateRandomTickInvariant(state, position, &saw_grass_decay_control);
            const y = canonicalPositionY(position) orelse continue;
            observeRandomTickTransition(&expected, state, y);
        }
        var groups = batch.iterator(.{ .recipient = "alice", .name = "blocks_changed" });
        while (groups.next()) |packet| {
            var entries = std.mem.splitScalar(u8, packet.field("changes") orelse continue, ';');
            while (entries.next()) |entry| {
                const first = std.mem.indexOfScalar(u8, entry, ',') orelse continue;
                const second_relative = std.mem.indexOfScalar(u8, entry[first + 1 ..], ',') orelse continue;
                const second = first + 1 + second_relative;
                const equal_relative = std.mem.indexOfScalar(u8, entry[second + 1 ..], '=') orelse continue;
                const split = second + 1 + equal_relative;
                const y = std.fmt.parseInt(i16, entry[first + 1 .. second], 10) catch continue;
                const state = entry[split + 1 ..];
                try validateRandomTickInvariant(state, entry[0..split], &saw_grass_decay_control);
                observeRandomTickTransition(&expected, state, y);
            }
        }
        var spawns = batch.iterator(.{ .recipient = "alice", .name = "entity_spawned" });
        while (spawns.next()) |packet| {
            if (std.mem.eql(u8, packet.field("type") orelse "", "minecraft:zombified_piglin"))
                saw_portal_piglin = true;
            if (std.mem.eql(u8, packet.field("type") orelse "", "minecraft:turtle"))
                saw_turtle = true;
        }
        if (saw_portal_piglin and saw_turtle and saw_grass_decay_control and allRandomTickTransitionsFound(&expected)) return;
    }

    if (!saw_portal_piglin) std.debug.print("missing random tick assertion: portal piglin spawning\n", .{});
    if (!saw_turtle) std.debug.print("missing random tick assertion: turtle egg hatches\n", .{});
    if (!saw_grass_decay_control) std.debug.print("missing random tick assertion: grass decay control\n", .{});
    for (expected) |item| {
        if (!item.found) std.debug.print("missing random tick assertion: {s}\n", .{item.name});
    }
    return error.MissingRandomTickBehavior;
}

fn validateRandomTickInvariant(state: []const u8, position: []const u8, saw_grass_decay_control: *bool) !void {
    if (std.mem.eql(u8, state, "minecraft:air") and isSharedConnectedLeafPosition(position))
        return error.ConnectedLeafDecayed;
    if (!std.mem.eql(u8, state, "minecraft:dirt")) return;
    if ((canonicalPositionY(position) orelse return) != 228) return;
    const x = canonicalPositionX(position) orelse return;
    const z = canonicalPositionZ(position) orelse return;
    if (@mod(x, 4) == 0 and @mod(z, 4) == 0) return error.ChestKilledGrass;
    if (@mod(x, 4) == 2 and @mod(z, 4) == 0) return error.LeavesKilledGrass;
    saw_grass_decay_control.* = true;
}

fn isSharedConnectedLeafPosition(position: []const u8) bool {
    inline for (.{ "7,233,24", "9,233,24", "8,232,24", "8,234,24", "8,233,23", "8,233,25" }) |leaf| {
        if (std.mem.eql(u8, position, leaf)) return true;
    }
    return false;
}

fn canonicalPositionX(position: []const u8) ?i32 {
    const first = std.mem.indexOfScalar(u8, position, ',') orelse return null;
    return std.fmt.parseInt(i32, position[0..first], 10) catch null;
}

fn observeRandomTickTransition(expected: []RandomTickExpectation, state: []const u8, y: i16) void {
    for (expected) |*item| {
        if (!item.found and y >= item.min_y and y <= item.max_y and std.mem.startsWith(u8, state, item.state_prefix))
            item.found = true;
    }
}

fn allRandomTickTransitionsFound(expected: []const RandomTickExpectation) bool {
    for (expected) |item| if (!item.found) return false;
    return true;
}

fn blockTransition(comptime state_prefix: []const u8, comptime min_y: i16, comptime max_y: i16, comptime maximum_ticks: usize) type {
    return fixtureBlockTransition("random-mechanics", state_prefix, min_y, max_y, maximum_ticks);
}

fn fixtureBlockTransition(comptime fixture_id: []const u8, comptime state_prefix: []const u8, comptime min_y: i16, comptime max_y: i16, comptime maximum_ticks: usize) type {
    return struct {
        fn run(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
            const clients = [_]t.Client{.{ .name = "alice" }};
            var target = try harness(allocator, adapter, fixture_id, &clients);
            defer target.deinit();
            var matching_height_changes: usize = 0;
            var last_state_buffer: [128]u8 = undefined;
            var last_state_length: usize = 0;
            for (0..maximum_ticks) |_| {
                var batch = try target.tick();
                defer batch.deinit();
                var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed" });
                while (changes.next()) |packet| {
                    const state = packet.field("state") orelse continue;
                    const y = canonicalPositionY(packet.field("position") orelse continue) orelse continue;
                    if (y < min_y or y > max_y) continue;
                    matching_height_changes += 1;
                    last_state_length = @min(state.len, last_state_buffer.len);
                    @memcpy(last_state_buffer[0..last_state_length], state[0..last_state_length]);
                    if (std.mem.startsWith(u8, state, state_prefix)) return;
                }
                var groups = batch.iterator(.{ .recipient = "alice", .name = "blocks_changed" });
                while (groups.next()) |packet| {
                    var entries = std.mem.splitScalar(u8, packet.field("changes") orelse continue, ';');
                    while (entries.next()) |entry| {
                        const first = std.mem.indexOfScalar(u8, entry, ',') orelse continue;
                        const second_relative = std.mem.indexOfScalar(u8, entry[first + 1 ..], ',') orelse continue;
                        const second = first + 1 + second_relative;
                        const equal = std.mem.indexOfScalar(u8, entry[second + 1 ..], '=') orelse continue;
                        const split = second + 1 + equal;
                        const y = std.fmt.parseInt(i16, entry[first + 1 .. second], 10) catch continue;
                        if (y >= min_y and y <= max_y and std.mem.startsWith(u8, entry[split + 1 ..], state_prefix)) return;
                    }
                }
            }
            std.debug.print("no {s} transition in y={d}..{d} after {d} ticks; observed {d} changes, last state {s}\n", .{ state_prefix, min_y, max_y, maximum_ticks, matching_height_changes, if (last_state_length == 0) "none" else last_state_buffer[0..last_state_length] });
            return error.MissingCanonicalPacket;
        }
    };
}

fn fixtureBlockTransitionAt(comptime fixture_id: []const u8, comptime state_prefix: []const u8, comptime x: i32, comptime y: i16, comptime z: i32, comptime maximum_ticks: usize) type {
    return struct {
        fn run(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
            const clients = [_]t.Client{.{ .name = "alice" }};
            var target = try harness(allocator, adapter, fixture_id, &clients);
            defer target.deinit();
            const position = std.fmt.comptimePrint("{d},{d},{d}", .{ x, y, z });
            for (0..maximum_ticks) |_| {
                var batch = try target.tick();
                defer batch.deinit();
                var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed", .field_name = "position", .field_value = position });
                while (changes.next()) |packet| {
                    if (std.mem.startsWith(u8, packet.field("state") orelse continue, state_prefix)) return;
                }
                var groups = batch.iterator(.{ .recipient = "alice", .name = "blocks_changed" });
                while (groups.next()) |packet| {
                    var entries = std.mem.splitScalar(u8, packet.field("changes") orelse continue, ';');
                    while (entries.next()) |entry| {
                        if (entry.len <= position.len or entry[position.len] != '=' or !std.mem.eql(u8, entry[0..position.len], position)) continue;
                        if (std.mem.startsWith(u8, entry[position.len + 1 ..], state_prefix)) return;
                    }
                }
            }
            std.debug.print("no {s} transition at {s} after {d} ticks\n", .{ state_prefix, position, maximum_ticks });
            return error.MissingCanonicalPacket;
        }
    };
}

fn entityTransition(comptime entity_type: []const u8, comptime maximum_ticks: usize) type {
    return fixtureEntityTransition("random-mechanics", entity_type, maximum_ticks);
}

fn fixtureEntityTransition(comptime fixture_id: []const u8, comptime entity_type: []const u8, comptime maximum_ticks: usize) type {
    return struct {
        fn run(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
            const clients = [_]t.Client{.{ .name = "alice" }};
            var target = try harness(allocator, adapter, fixture_id, &clients);
            defer target.deinit();
            var spawn_packets: usize = 0;
            var last_data_buffer: [512]u8 = undefined;
            var last_data_length: usize = 0;
            for (0..maximum_ticks) |_| {
                var batch = try target.tick();
                defer batch.deinit();
                var packets = batch.iterator(.{ .recipient = "alice", .name = "entity_spawned" });
                while (packets.next()) |packet| {
                    const data = packet.field("type") orelse "";
                    spawn_packets += 1;
                    last_data_length = @min(data.len, last_data_buffer.len);
                    @memcpy(last_data_buffer[0..last_data_length], data[0..last_data_length]);
                    if (std.mem.eql(u8, data, entity_type)) return;
                }
            }
            std.debug.print("no spawn for {s} after {d} ticks; observed {d} spawn packets, last data {s}\n", .{ entity_type, maximum_ticks, spawn_packets, if (last_data_length == 0) "none" else last_data_buffer[0..last_data_length] });
            return error.MissingCanonicalPacket;
        }
    };
}

fn campfireSmokeIsClientSide(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "campfire", &clients);
    defer target.deinit();
    var batch = try target.tick();
    defer batch.deinit();
    {
        var particles = batch.iterator(.{ .recipient = "alice", .name = "wire/world_particles" });
        if (particles.next() != null) return error.UnexpectedServerParticle;
    }
}

fn canonicalPositionY(position: []const u8) ?i16 {
    const first = std.mem.indexOfScalar(u8, position, ',') orelse return null;
    const second_relative = std.mem.indexOfScalar(u8, position[first + 1 ..], ',') orelse return null;
    return std.fmt.parseInt(i16, position[first + 1 .. first + 1 + second_relative], 10) catch null;
}

fn movement(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();
    try target.send("alice", .{ .move = .{ .position = .{ .x = 12.5, .y = 70, .z = 1.25 }, .on_ground = true } });
    var batch = try target.tick();
    defer batch.deinit();
    const packet = try batch.one(.{ .recipient = "bob", .name = "entity_moved", .field_name = "subject", .field_value = "alice" });
    try expectText("12.5,70,1.25", packet.field("position"));
}

fn playerRotation(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .look = .{ .yaw = 90 } });
    try expectHeadRotationWithin(&target, "64", 5);

    try target.send("alice", .{ .look = .{ .yaw = -90 } });
    try expectHeadRotationWithin(&target, "-64", 5);
}

fn expectHeadRotationWithin(target: *t.Harness, yaw: []const u8, maximum_ticks: usize) !void {
    for (0..maximum_ticks) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        if (batch.first(.{
            .recipient = "bob",
            .name = "entity_head_rotation",
            .field_name = "subject",
            .field_value = "alice",
        })) |packet| {
            try expectText(yaw, packet.field("yaw"));
            return;
        }
    }
    return error.MissingCanonicalPacket;
}

fn sneakingSynchronization(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();
    for (0..5) |_| {
        var warm = try target.tick();
        warm.deinit();
    }
    try target.send("alice", .{ .player_input = .{ .shift = true } });
    try expectPlayerPoseWithin(&target, "crouching", 3);

    try target.send("alice", .{ .player_input = .{ .shift = false } });
    try expectPlayerPoseWithin(&target, "standing", 3);
}

fn sprintingSynchronization(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .entity_action = .start_sprinting });
    try expectPlayerFlagWithin(&target, "sprinting", "1", 3);
    try target.send("alice", .{ .entity_action = .stop_sprinting });
    try expectPlayerFlagWithin(&target, "sprinting", "0", 3);
}

fn coalescedSurvivalSprintJump(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .entity_action = .start_sprinting });
    var started = try target.tick();
    started.deinit();

    const samples = [_]struct { position: t.Vec3, on_ground: bool }{
        .{ .position = .{ .x = 12.9, .y = 71.00133597911214, .z = 1 }, .on_ground = false },
        .{ .position = .{ .x = 13.45, .y = 70.75, .z = 1 }, .on_ground = false },
        .{ .position = .{ .x = 14.0, .y = 70, .z = 1 }, .on_ground = true },
    };
    for (samples) |sample| {
        try target.send("alice", .{ .move = .{ .position = sample.position, .on_ground = sample.on_ground } });
        var moved = try target.tick();
        defer moved.deinit();
        if (moved.count(.{ .recipient = "alice", .name = "player_position" }) != 0)
            return error.LegalSprintJumpRejected;
        _ = moved.first(.{
            .recipient = "bob",
            .name = "entity_moved",
            .field_name = "subject",
            .field_value = "alice",
        }) orelse return error.LegalSprintJumpNotReplicated;
    }
}

fn expectPlayerFlagWithin(target: *t.Harness, field: []const u8, value: []const u8, maximum_ticks: usize) !void {
    for (0..maximum_ticks) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        if (batch.first(.{
            .recipient = "bob",
            .name = "entity_state",
            .field_name = field,
            .field_value = value,
        })) |packet| {
            try expectText("alice", packet.field("subject"));
            return;
        }
    }
    return error.MissingCanonicalPacket;
}

fn expectPlayerPoseWithin(target: *t.Harness, pose: []const u8, maximum_ticks: usize) !void {
    for (0..maximum_ticks) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        if (batch.first(.{ .recipient = "bob", .name = "entity_pose", .field_name = "subject", .field_value = "alice" })) |packet| {
            try expectText(pose, packet.field("pose"));
            return;
        }
    }
    return error.MissingCanonicalPacket;
}

fn survivalMiningCorrectTool(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mining-correct-tool", &clients);
    defer target.deinit();
    try groundMiningPlayer(&target);
    const position = t.BlockPos{ .x = 0, .y = 64, .z = 0 };
    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = position } });
    var start = try target.tick();
    defer start.deinit();
    try expectMiningStages(&start, &.{ 1, 3 });
    inline for (.{ 5, 7, 8 }) |stage| {
        var progress = try target.tick();
        defer progress.deinit();
        try expectMiningStages(&progress, &.{stage});
        try expectNoCompletedMining(&progress);
    }

    try target.send("alice", .{ .player_action = .{ .action = .stop_destroy_block, .position = position } });
    var completed = try target.tick();
    defer completed.deinit();
    try expectMiningStages(&completed, &.{-1});
    try expectMinedStone(&completed, true);
    const equipment = completed.first(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) orelse
        return error.MissingMinedToolUpdate;
    try expectText("minecraft:diamond_pickaxe*1{minecraft:damage=1}", equipment.field("stack"));
    try expectPlayerInventoryAfterReconnect(&target, "minecraft:diamond_pickaxe*1{minecraft:damage=1}");
}

fn survivalMiningWrongTool(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mining-wrong-tool", &clients);
    defer target.deinit();
    try mineStoneAtVanillaHandSpeed(&target);
    try expectPlayerInventoryAfterReconnect(&target, "minecraft:diamond_shovel*1{minecraft:damage=1}");
}

fn survivalMiningEmptyHand(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mining-empty-hand", &clients);
    defer target.deinit();
    try mineStoneAtVanillaHandSpeed(&target);
    try expectPlayerInventoryAfterReconnect(&target, "empty");
}

fn representativeBlockLootTables(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{
        .{ .name = "self-breaker" },
        .{ .name = "stone-breaker" },
        .{ .name = "tier-breaker" },
        .{ .name = "glass-breaker" },
        .{ .name = "clay-breaker" },
        .{ .name = "observer" },
    };
    const breakers = [_]struct { name: []const u8, position: t.BlockPos }{
        .{ .name = "self-breaker", .position = .{ .x = 0, .y = 100, .z = 0 } },
        .{ .name = "stone-breaker", .position = .{ .x = 8, .y = 100, .z = 0 } },
        .{ .name = "tier-breaker", .position = .{ .x = 16, .y = 100, .z = 0 } },
        .{ .name = "glass-breaker", .position = .{ .x = 24, .y = 100, .z = 0 } },
        .{ .name = "clay-breaker", .position = .{ .x = 32, .y = 100, .z = 0 } },
    };
    var target = try harness(allocator, adapter, "block-loot-families", &clients);
    defer target.deinit();

    for (breakers) |breaker|
        try target.send(breaker.name, .{ .move = .{
            .position = .{
                .x = @as(f64, @floatFromInt(breaker.position.x)) + 0.5,
                .y = breaker.position.y,
                .z = 2.5,
            },
            .on_ground = true,
        } });
    var grounded = try target.tick();
    grounded.deinit();
    for (breakers) |breaker|
        try target.send(breaker.name, .{ .player_action = .{ .action = .start_destroy_block, .position = breaker.position } });
    var started = try target.tick();
    started.deinit();
    var changed = [_]bool{false} ** breakers.len;
    var item_count: usize = 0;
    var dirt = false;
    var cobblestone = false;
    var clay_balls = false;
    for (0..155) |relative_tick| {
        switch (relative_tick) {
            1 => try target.send(breakers[0].name, .{ .player_action = .{ .action = .stop_destroy_block, .position = breakers[0].position } }),
            2 => try target.send(breakers[4].name, .{ .player_action = .{ .action = .stop_destroy_block, .position = breakers[4].position } }),
            5 => try target.send(breakers[1].name, .{ .player_action = .{ .action = .stop_destroy_block, .position = breakers[1].position } }),
            8 => try target.send(breakers[3].name, .{ .player_action = .{ .action = .stop_destroy_block, .position = breakers[3].position } }),
            149 => try target.send(breakers[2].name, .{ .player_action = .{ .action = .stop_destroy_block, .position = breakers[2].position } }),
            else => {},
        }
        var completed = try target.tick();
        defer completed.deinit();
        for (breakers, 0..) |breaker, index| {
            var position_buffer: [48]u8 = undefined;
            const position = try std.fmt.bufPrint(&position_buffer, "{d},{d},{d}", .{
                breaker.position.x,
                breaker.position.y,
                breaker.position.z,
            });
            if (completed.first(.{
                .recipient = "observer",
                .name = "block_changed",
                .field_name = "position",
                .field_value = position,
            })) |packet| {
                try expectText("minecraft:air", packet.field("state"));
                changed[index] = true;
            }
        }
        var drops = completed.iterator(.{ .recipient = "observer", .name = "item_spawned" });
        while (drops.next()) |packet| {
            item_count += 1;
            const stack = packet.field("stack") orelse return error.MissingCanonicalField;
            if (std.mem.eql(u8, stack, "minecraft:dirt*1")) dirt = true else if (std.mem.eql(u8, stack, "minecraft:cobblestone*1")) cobblestone = true else if (std.mem.eql(u8, stack, "minecraft:clay_ball*4")) clay_balls = true else return error.UnexpectedRepresentativeBlockDrop;
        }
    }
    if (!changed[0]) return error.MissingSelfDropBlockBreak;
    if (!changed[1]) return error.MissingTransformedDropBlockBreak;
    if (!changed[2]) return error.MissingTierRejectedBlockBreak;
    if (!changed[3]) return error.MissingNoDropBlockBreak;
    if (!changed[4]) return error.MissingFixedMultiDropBlockBreak;
    if (item_count != 3) return error.UnexpectedRepresentativeBlockDropCount;
    if (!dirt) return error.MissingSelfDrop;
    if (!cobblestone) return error.MissingTransformedDrop;
    if (!clay_balls) return error.MissingFixedMultiDrop;
}

fn mineStoneAtVanillaHandSpeed(target: *t.Harness) !void {
    try groundMiningPlayer(target);
    const position = t.BlockPos{ .x = 0, .y = 64, .z = 0 };
    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = position } });
    var started = try target.tick();
    defer started.deinit();
    try expectMiningStages(&started, &.{0});
    try expectNoCompletedMining(&started);

    var next_stage: i8 = 1;
    for (1..149) |relative_tick| {
        var progress = try target.tick();
        defer progress.deinit();
        try expectNoCompletedMining(&progress);
        const transition_tick: usize = @as(usize, @intCast(next_stage)) * 15 - 2;
        if (relative_tick == transition_tick) {
            try expectMiningStages(&progress, &.{next_stage});
            next_stage += 1;
        } else {
            try expectMiningStages(&progress, &.{});
        }
    }
    try expect(next_stage == 11);

    try target.send("alice", .{ .player_action = .{ .action = .stop_destroy_block, .position = position } });
    var completed = try target.tick();
    defer completed.deinit();
    try expectMiningStages(&completed, &.{-1});
    try expectMinedStone(&completed, false);
}

fn creativeInstantMining(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mining-creative", &clients);
    defer target.deinit();
    try groundMiningPlayer(&target);

    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = .{ .x = 0, .y = 64, .z = 0 } } });
    var mined = try target.tick();
    defer mined.deinit();
    try expectMiningStages(&mined, &.{});
    try expectMinedStone(&mined, false);
    try expectPlayerInventoryAfterReconnect(&target, "minecraft:diamond_pickaxe*1");
}

fn miningAbortResetsProgress(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mining-correct-tool", &clients);
    defer target.deinit();
    try groundMiningPlayer(&target);
    const position = t.BlockPos{ .x = 0, .y = 64, .z = 0 };

    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = position } });
    var started = try target.tick();
    defer started.deinit();
    try expectMiningStages(&started, &.{ 1, 3 });

    try target.send("alice", .{ .player_action = .{ .action = .abort_destroy_block, .position = position } });
    var aborted = try target.tick();
    defer aborted.deinit();
    try expectMiningStages(&aborted, &.{-1});
    try expectNoCompletedMining(&aborted);
    for (0..3) |_| {
        var quiet = try target.tick();
        defer quiet.deinit();
        try expectMiningStages(&quiet, &.{});
    }

    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = position } });
    var restarted = try target.tick();
    defer restarted.deinit();
    try expectMiningStages(&restarted, &.{ 1, 3 });
    try expectNoCompletedMining(&restarted);
}

fn groundMiningPlayer(target: *t.Harness) !void {
    try target.send("alice", .{ .move = .{
        .position = .{ .x = 0.5, .y = 65, .z = 2.5 },
        .on_ground = true,
    } });
    var grounded = try target.tick();
    grounded.deinit();
}

fn expectMiningStages(batch: *const t.Batch, expected: []const i8) !void {
    var packets = batch.iterator(.{
        .recipient = "bob",
        .name = "block_break_animation",
        .field_name = "subject",
        .field_value = "alice",
    });
    var index: usize = 0;
    while (packets.next()) |packet| : (index += 1) {
        if (index == expected.len) {
            std.debug.print("unexpected mining stage {s}\n", .{packet.field("stage") orelse "missing"});
            return error.UnexpectedMiningProgressPacket;
        }
        try expectText("0,64,0", packet.field("position"));
        const actual = try packet.fieldInt(i8, "stage");
        if (actual != expected[index]) {
            std.debug.print("mining stage mismatch at {}: expected {}, got {}\n", .{ index, expected[index], actual });
            return error.ConformanceAssertionFailed;
        }
    }
    if (index != expected.len) return error.MissingMiningProgressPacket;
}

fn expectNoCompletedMining(batch: *const t.Batch) !void {
    try expect(batch.count(.{ .name = "block_changed", .field_name = "state", .field_value = "minecraft:air" }) == 0);
    try expect(batch.count(.{ .name = "item_spawned" }) == 0);
}

fn expectMinedStone(batch: *const t.Batch, should_drop: bool) !void {
    for ([_][]const u8{ "alice", "bob" }) |recipient| {
        _ = batch.first(.{ .recipient = recipient, .name = "block_changed", .field_name = "state", .field_value = "minecraft:air" }) orelse
            return error.MissingMinedBlockChange;
        const drop = batch.first(.{ .recipient = recipient, .name = "item_spawned" });
        if (should_drop) {
            try expectText("minecraft:cobblestone*1", (drop orelse return error.MissingMinedBlockDrop).field("stack"));
        } else if (drop != null) {
            return error.UnexpectedMinedBlockDrop;
        }
    }
}

fn expectPlayerInventoryAfterReconnect(target: *t.Harness, expected_stack: []const u8) !void {
    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var joined = try target.tick();
    defer joined.deinit();
    const inventory = joined.first(.{ .recipient = "alice", .name = "inventory" }) orelse
        return error.MissingPostMiningInventory;
    try expectSlot(inventory, "h0", expected_stack);
}

fn craftAll(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "craft-all", &clients);
    defer target.deinit();
    try target.send("alice", .{ .container_click = .{ .slot = 0, .button = 0, .mode = 1 } });
    var batch = try target.tick();
    defer batch.deinit();
    const inventory = try batch.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h8", "minecraft:crafting_table*4");
    inline for (.{ "g0", "g1", "g2", "g3" }) |slot| try expectSlot(inventory, slot, "empty");
    // Vanilla emits intermediate recipe previews, but their precise count and
    // ordering is not the behavior this scenario is asserting.
    try expect(batch.count(.{ .recipient = "alice", .name = "inventory_slot", .field_name = "slot", .field_value = "r" }) > 0);
}

fn craftingClose(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "crafting-close", &clients);
    defer target.deinit();
    try target.send("alice", .close_player_screen);
    var closed = try target.tick();
    defer closed.deinit();
    try expectSlotUpdates(&closed, "alice", "h3", "minecraft:oak_planks*16");
    try expectSlotUpdates(&closed, "alice", "r", "empty");

    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var rejoined = try target.tick();
    defer rejoined.deinit();
    const inventory = try rejoined.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h3", "minecraft:oak_planks*16");
    inline for (.{ "g0", "g1", "g2", "g3" }) |slot| try expectSlot(inventory, slot, "empty");
}

fn placement(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "placement-arena", &clients);
    defer target.deinit();
    try placeAndCheck(&target, .{ .x = 0, .y = 64, .z = 0 }, 0, "0,65,0", "minecraft:dirt*1");
    for (0..20) |_| {
        var quiet = try target.tick();
        quiet.deinit();
    }
    try placeAndCheck(&target, .{ .x = 1, .y = 64, .z = 0 }, 1, "1,65,0", "empty");
}

fn restartPersistsWorldAndPlayer(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "storage-restart", &clients);
    defer target.deinit();

    try target.send("alice", .{ .move = .{
        .position = .{ .x = 1.5, .y = 65, .z = 2.5 },
        .on_ground = true,
    } });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var mutated = try target.tick();
    defer mutated.deinit();
    const placed = mutated.first(.{ .recipient = "bob", .name = "block_changed", .field_name = "position", .field_value = "0,65,0" }) orelse
        return error.MissingPreRestartBlockMutation;
    try expectText("minecraft:dirt", placed.field("state"));
    const consumed = mutated.first(.{ .recipient = "alice", .name = "inventory_slot", .field_name = "slot", .field_value = "h4" }) orelse
        return error.MissingPreRestartInventoryMutation;
    try expectText("minecraft:dirt*1", consumed.field("stack"));

    try target.restart();
    var joined = try target.tick();
    defer joined.deinit();
    const inventory = joined.first(.{ .recipient = "alice", .name = "inventory", .field_name = "screen", .field_value = "player" }) orelse
        return error.MissingRestartInventory;
    try expectSlot(inventory, "h4", "minecraft:dirt*1");
    const selected = joined.first(.{ .recipient = "alice", .name = "selected_hotbar_slot" }) orelse
        return error.MissingRestartSelectedSlot;
    try expectText("4", selected.field("slot"));
    const health = joined.first(.{ .recipient = "alice", .name = "health_update" }) orelse
        return error.MissingRestartHealth;
    try expect(@abs((try health.fieldFloat("health")) - 13) < 0.0001);
    const position = joined.first(.{ .recipient = "alice", .name = "player_position" }) orelse
        return error.MissingRestartPosition;
    try expect(@abs((try position.fieldFloat("x")) - 1.5) < 0.0001);
    try expect(@abs((try position.fieldFloat("y")) - 65) < 0.0001);
    try expect(@abs((try position.fieldFloat("z")) - 2.5) < 0.0001);
    const equipment = joined.first(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) orelse
        return error.MissingRestartEquipment;
    try expectText("minecraft:dirt*1", equipment.field("stack"));

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 2,
    } });
    var observed = try target.tick();
    defer observed.deinit();
    const persisted = observed.first(.{ .recipient = "alice", .name = "block_changed", .field_name = "position", .field_value = "0,65,0" }) orelse
        return error.MissingRestartBlockObservation;
    try expectText("minecraft:dirt", persisted.field("state"));
}

fn restartPersistsEntities(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "storage-restart", &clients);
    defer target.deinit();

    const sapling = t.BlockPos{ .x = 4, .y = 65, .z = 0 };
    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = sapling } });
    try target.send("alice", .{ .player_action = .{ .action = .stop_destroy_block, .position = sapling } });
    var broken = try target.tick();
    defer broken.deinit();
    const dropped = broken.first(.{ .recipient = "alice", .name = "item_spawned" }) orelse
        return error.MissingPreRestartItemEntity;
    try expectText("minecraft:oak_sapling*1", dropped.field("stack"));

    try target.restart();
    var joined = try target.tick();
    defer joined.deinit();
    const item = joined.first(.{ .recipient = "alice", .name = "item_spawned" }) orelse
        return error.MissingRestartItemEntity;
    try expectText("minecraft:oak_sapling*1", item.field("stack"));
    _ = joined.first(.{ .recipient = "alice", .name = "entity_spawned", .field_name = "type", .field_value = "minecraft:zombie" }) orelse
        return error.MissingRestartLivingEntity;

    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var attacked = try target.tick();
    defer attacked.deinit();
    _ = attacked.first(.{ .recipient = "alice", .name = "entity_damaged", .field_name = "subject", .field_value = "zombie" }) orelse
        return error.RestartLivingIdentityWasNotUsable;
}

fn sharedChestInventory(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "chest-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var opened = try target.tick();
    defer opened.deinit();
    const initial = opened.first(.{ .recipient = "alice", .name = "inventory", .field_name = "screen", .field_value = "chest" }) orelse
        return error.MissingCanonicalPacket;
    try expectSlot(initial, "s0", "empty");
    try expectSlot(initial, "h0", "minecraft:oak_log*12");

    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 54,
        .button = 0,
        .mode = 1,
    } });
    var stored = try target.tick();
    defer stored.deinit();
    try expectInventorySlots(&stored, "alice", "chest", "s0", "minecraft:oak_log*12", "h0", "empty");
    const equipment = stored.first(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) orelse
        return error.MissingCanonicalPacket;
    try expectText("empty", equipment.field("stack"));

    try target.send("bob", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var observed = try target.tick();
    defer observed.deinit();
    try expectInventorySlots(&observed, "bob", "chest", "s0", "minecraft:oak_log*12", "h0", "empty");
}

fn restartPersistsChestInventory(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "chest-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var opened = try target.tick();
    opened.deinit();
    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 54,
        .button = 0,
        .mode = 1,
    } });
    var stored = try target.tick();
    defer stored.deinit();
    try expectInventoryContains(&stored, "alice", "chest", "s0", "minecraft:oak_log*12");

    try target.restart();
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 2,
    } });
    var reopened = try target.tick();
    defer reopened.deinit();
    try expectInventoryContains(&reopened, "alice", "chest", "s0", "minecraft:oak_log*12");
}

fn furnaceSmelting(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "furnace-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var opened = try target.tick();
    defer opened.deinit();
    _ = opened.first(.{ .recipient = "alice", .name = "inventory", .field_name = "screen", .field_value = "furnace" }) orelse
        return error.MissingCanonicalPacket;

    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 30,
        .button = 0,
        .mode = 1,
    } });
    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 31,
        .button = 0,
        .mode = 1,
    } });
    var started = try target.tick();
    defer started.deinit();
    try expectInventoryContains(&started, "alice", "furnace", "s0", "minecraft:raw_iron*1");

    for (0..205) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var inventories = batch.iterator(.{ .recipient = "alice", .name = "inventory", .field_name = "screen", .field_value = "furnace" });
        while (inventories.next()) |inventory| {
            if (std.mem.eql(u8, inventory.inventorySlot("s2") orelse "", "minecraft:iron_ingot*1")) {
                try expectSlot(inventory, "s0", "empty");
                return;
            }
        }
        var slots = batch.iterator(.{ .recipient = "alice", .name = "inventory_slot", .field_name = "slot", .field_value = "s2" });
        while (slots.next()) |slot| if (std.mem.eql(u8, slot.field("stack") orelse "", "minecraft:iron_ingot*1")) return;
    }
    return error.FurnaceDidNotSmelt;
}

fn restartPersistsFurnaceProgress(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "furnace-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var opened = try target.tick();
    opened.deinit();
    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 30,
        .button = 0,
        .mode = 1,
    } });
    try target.send("alice", .{ .container_click = .{
        .window_id = 1,
        .slot = 31,
        .button = 0,
        .mode = 1,
    } });
    var started = try target.tick();
    started.deinit();
    for (0..60) |_| {
        var cooking = try target.tick();
        cooking.deinit();
    }

    try target.restart();
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 2,
    } });
    var reopened = try target.tick();
    defer reopened.deinit();
    try expectInventoryContains(&reopened, "alice", "furnace", "s0", "minecraft:raw_iron*1");

    for (0..150) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var inventories = batch.iterator(.{
            .recipient = "alice",
            .name = "inventory",
            .field_name = "screen",
            .field_value = "furnace",
        });
        while (inventories.next()) |inventory|
            if (std.mem.eql(u8, inventory.inventorySlot("s2") orelse "", "minecraft:iron_ingot*1")) return;
        var slots = batch.iterator(.{
            .recipient = "alice",
            .name = "inventory_slot",
            .field_name = "slot",
            .field_value = "s2",
        });
        while (slots.next()) |slot|
            if (std.mem.eql(u8, slot.field("stack") orelse "", "minecraft:iron_ingot*1")) return;
    }
    return error.FurnaceProgressDidNotSurviveRestart;
}

fn chestPlacementFacings(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    try directionalPlacementFacings(adapter, allocator, "chest-placement", "minecraft:chest[facing={s},type=single,waterlogged=false]");
}

fn furnacePlacementFacings(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    try directionalPlacementFacings(adapter, allocator, "furnace-placement", "minecraft:furnace[facing={s},lit=false]");
}

fn survivalPickBlock(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "pick-block", &clients);
    defer target.deinit();

    // In survival, pick block is client-side inventory lookup followed by the
    // normal held-item packet. The server must authoritatively select the
    // existing matching stack and replicate it to observers.
    try target.send("alice", .{ .select_hotbar_slot = 5 });
    var batch = try target.tick();
    defer batch.deinit();
    const equipment = try batch.one(.{
        .recipient = "bob",
        .name = "entity_equipment",
        .field_name = "subject",
        .field_value = "alice",
    });
    try expectText("minecraft:stone*17", equipment.field("stack"));
}

fn creativePickBlock(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "creative-pick-block", &clients);
    defer target.deinit();

    // Creative pick block writes the chosen stack into a protocol inventory
    // slot and then selects that hotbar slot.
    try target.send("alice", .{ .creative_slot = .{
        .slot = 41,
        .item = "minecraft:stone",
        .count = 64,
    } });
    try target.send("alice", .{ .select_hotbar_slot = 5 });
    var batch = try target.tick();
    defer batch.deinit();
    var equipment = batch.iterator(.{
        .recipient = "bob",
        .name = "entity_equipment",
        .field_name = "subject",
        .field_value = "alice",
    });
    while (equipment.next()) |update|
        if (std.mem.eql(u8, update.field("stack") orelse "", "minecraft:stone*64")) return;
    return error.MissingCanonicalPacket;
}

fn creativeSlotChangesPreserveOrder(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "creative-inventory", &clients);
    defer target.deinit();

    try target.send("alice", .{ .creative_slot = .{ .slot = 36, .item = "minecraft:stone", .count = 64 } });
    try target.send("alice", .{ .creative_slot = .{ .slot = 37, .item = "minecraft:dirt", .count = 32 } });
    var acquired = try target.tick();
    acquired.deinit();

    try target.send("alice", .{ .select_hotbar_slot = 0 });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 0, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 1,
    } });
    var first = try target.tick();
    defer first.deinit();
    try expectBlockState(&first, "alice", "0,65,0", "minecraft:stone");

    try target.send("alice", .{ .select_hotbar_slot = 1 });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 2, .y = 64, .z = 0 },
        .face = .up,
        .sequence = 2,
    } });
    var second = try target.tick();
    defer second.deinit();
    try expectBlockState(&second, "alice", "2,65,0", "minecraft:dirt");
}

fn expectBlockState(batch: *const t.Batch, recipient: []const u8, position: []const u8, state: []const u8) !void {
    if (hasBlockState(batch, recipient, position, state)) return;
    std.debug.print("missing block state at {s}: {s}\n", .{ position, state });
    for (batch.packets) |packet| {
        std.debug.print("  observed packet: {s} -> {s}", .{ packet.recipient, packet.name });
        for (packet.fields) |field| std.debug.print(" {s}={s}", .{ field.name, field.value.literal });
        std.debug.print("\n", .{});
    }
    return error.MissingCanonicalPacket;
}

fn hasBlockState(batch: *const t.Batch, recipient: []const u8, position: []const u8, state: []const u8) bool {
    for (batch.packets) |packet| {
        if (!std.mem.eql(u8, packet.recipient, recipient)) continue;
        if (std.mem.eql(u8, packet.name, "block_changed")) {
            if (std.mem.eql(u8, packet.field("position") orelse "", position) and
                std.mem.eql(u8, packet.field("state") orelse "", state))
                return true;
            continue;
        }
        if (!std.mem.eql(u8, packet.name, "blocks_changed")) continue;
        var entries = std.mem.splitScalar(u8, packet.field("changes") orelse "", ';');
        while (entries.next()) |entry| {
            const equal = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..equal], position) and
                std.mem.eql(u8, entry[equal + 1 ..], state))
                return true;
        }
    }
    return false;
}

fn expectDoorState(
    batch: *const t.Batch,
    recipient: []const u8,
    lower_position: []const u8,
    upper_position: []const u8,
    facing: []const u8,
    hinge: []const u8,
    open: bool,
) !void {
    var lower_buffer: [160]u8 = undefined;
    const lower_state = try std.fmt.bufPrint(
        &lower_buffer,
        "minecraft:oak_door[facing={s},half=lower,hinge={s},open={},powered=false]",
        .{ facing, hinge, open },
    );
    var upper_buffer: [160]u8 = undefined;
    const upper_state = try std.fmt.bufPrint(
        &upper_buffer,
        "minecraft:oak_door[facing={s},half=upper,hinge={s},open={},powered=false]",
        .{ facing, hinge, open },
    );
    if (hasBlockState(batch, recipient, lower_position, lower_state) and
        hasBlockState(batch, recipient, upper_position, upper_state))
        return;
    std.debug.print(
        "missing door state lower={s} upper={s} facing={s} hinge={s} open={}\n",
        .{ lower_position, upper_position, facing, hinge, open },
    );
    return error.MissingCanonicalPacket;
}

fn trapdoorPlacementAndFlipping(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "trapdoors", &clients);
    defer target.deinit();

    try target.send("alice", .{ .look = .{ .yaw = 0 } });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 64, .z = 4 },
        .face = .up,
        .sequence = 1,
    } });
    var floor_placed = try target.tick();
    defer floor_placed.deinit();
    try expectBlockState(
        &floor_placed,
        "alice",
        "4,65,4",
        "minecraft:oak_trapdoor[facing=north,half=bottom,open=false,powered=false,waterlogged=false]",
    );

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 65, .z = 4 },
        .face = .up,
        .sequence = 2,
    } });
    var opened = try target.tick();
    defer opened.deinit();
    try expectBlockState(
        &opened,
        "alice",
        "4,65,4",
        "minecraft:oak_trapdoor[facing=north,half=bottom,open=true,powered=false,waterlogged=false]",
    );

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 65, .z = 4 },
        .face = .up,
        .sequence = 3,
    } });
    var closed = try target.tick();
    defer closed.deinit();
    try expectBlockState(
        &closed,
        "alice",
        "4,65,4",
        "minecraft:oak_trapdoor[facing=north,half=bottom,open=false,powered=false,waterlogged=false]",
    );

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 6, .y = 65, .z = 4 },
        .face = .east,
        .cursor_y = 0.75,
        .sequence = 4,
    } });
    var wall_placed = try target.tick();
    defer wall_placed.deinit();
    try expectBlockState(
        &wall_placed,
        "alice",
        "7,65,4",
        "minecraft:oak_trapdoor[facing=east,half=top,open=false,powered=false,waterlogged=false]",
    );
}

fn doorPlacementAndFlipping(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "doors", &clients);
    defer target.deinit();
    const cases = [_]struct {
        x: i32,
        z: i32,
        yaw: f32,
        facing: []const u8,
    }{
        .{ .x = 4, .z = 4, .yaw = 0, .facing = "south" },
        .{ .x = 6, .z = 4, .yaw = 90, .facing = "west" },
        .{ .x = 8, .z = 4, .yaw = 180, .facing = "north" },
        .{ .x = 4, .z = 6, .yaw = -90, .facing = "east" },
    };
    for (cases, 0..) |case, index| {
        try target.send("alice", .{ .look = .{ .yaw = case.yaw } });
        try target.send("alice", .{ .use_item_on = .{
            .against = .{ .x = case.x, .y = 64, .z = case.z },
            .face = .up,
            .sequence = @intCast(index + 1),
        } });
        var placed = try target.tick();
        defer placed.deinit();
        var position_buffer: [32]u8 = undefined;
        const lower_position = try std.fmt.bufPrint(&position_buffer, "{d},65,{d}", .{ case.x, case.z });
        var upper_position_buffer: [32]u8 = undefined;
        const upper_position = try std.fmt.bufPrint(&upper_position_buffer, "{d},66,{d}", .{ case.x, case.z });
        try expectDoorState(&placed, "alice", lower_position, upper_position, case.facing, "left", false);
    }

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 65, .z = 4 },
        .face = .south,
        .sequence = 5,
    } });
    var opened = try target.tick();
    defer opened.deinit();
    try expectDoorState(&opened, "alice", "4,65,4", "4,66,4", "south", "left", true);

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 66, .z = 4 },
        .face = .south,
        .sequence = 6,
    } });
    var closed = try target.tick();
    defer closed.deinit();
    try expectDoorState(&closed, "alice", "4,65,4", "4,66,4", "south", "left", false);
}

fn adjacentDoorHinges(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "doors", &clients);
    defer target.deinit();

    try target.send("alice", .{ .look = .{ .yaw = 0 } });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 5, .y = 64, .z = 6 },
        .face = .up,
        .sequence = 1,
    } });
    var first = try target.tick();
    defer first.deinit();
    try expectDoorState(&first, "alice", "5,65,6", "5,66,6", "south", "left", false);

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 64, .z = 6 },
        .face = .up,
        .sequence = 2,
    } });
    var second = try target.tick();
    defer second.deinit();
    try expectDoorState(&second, "alice", "4,65,6", "4,66,6", "south", "right", false);
}

fn doorRejectsLeavesSupport(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "doors", &clients);
    defer target.deinit();

    try target.send("alice", .{ .look = .{ .yaw = 0 } });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 8, .y = 64, .z = 6 },
        .face = .up,
        .sequence = 1,
    } });
    var rejected = try target.tick();
    defer rejected.deinit();
    if (hasBlockStateFragment(&rejected, "8,65,6", "_door["))
        return error.DoorPlacedOnLeaves;
}

fn slabPlacementAndMerging(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "slabs", &clients);
    defer target.deinit();

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 64, .z = 4 },
        .face = .up,
        .sequence = 1,
    } });
    var bottom = try target.tick();
    defer bottom.deinit();
    try expectBlockState(&bottom, "bob", "4,65,4", "minecraft:oak_slab[type=bottom,waterlogged=false]");

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 6, .y = 66, .z = 4 },
        .face = .down,
        .sequence = 2,
    } });
    var top = try target.tick();
    defer top.deinit();
    try expectBlockState(&top, "bob", "6,65,4", "minecraft:oak_slab[type=top,waterlogged=false]");

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 4, .y = 65, .z = 4 },
        .face = .up,
        .sequence = 3,
    } });
    var bottom_merged = try target.tick();
    defer bottom_merged.deinit();
    try expectBlockState(&bottom_merged, "bob", "4,65,4", "minecraft:oak_slab[type=double,waterlogged=false]");

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 6, .y = 65, .z = 4 },
        .face = .down,
        .sequence = 4,
    } });
    var top_merged = try target.tick();
    defer top_merged.deinit();
    try expectBlockState(&top_merged, "bob", "6,65,4", "minecraft:oak_slab[type=double,waterlogged=false]");
}

fn doorsRequireSlabTopSupport(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "slabs", &clients);
    defer target.deinit();

    try target.send("alice", .{ .select_hotbar_slot = 1 });
    try target.send("alice", .{ .look = .{ .yaw = 0 } });
    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 8, .y = 64, .z = 6 },
        .face = .up,
        .sequence = 1,
    } });
    var supported = try target.tick();
    defer supported.deinit();
    try expectDoorState(&supported, "bob", "8,65,6", "8,66,6", "south", "left", false);

    try target.send("alice", .{ .use_item_on = .{
        .against = .{ .x = 9, .y = 64, .z = 6 },
        .face = .up,
        .sequence = 2,
    } });
    var rejected = try target.tick();
    defer rejected.deinit();
    if (hasBlockStateFragment(&rejected, "9,65,6", "_door["))
        return error.DoorPlacedWithoutFullTopSupport;
}

fn hasBlockStateFragment(batch: *const t.Batch, position: []const u8, fragment: []const u8) bool {
    for (batch.packets) |packet| {
        if (std.mem.eql(u8, packet.name, "block_changed")) {
            if (std.mem.eql(u8, packet.field("position") orelse "", position) and
                std.mem.indexOf(u8, packet.field("state") orelse "", fragment) != null)
                return true;
            continue;
        }
        if (!std.mem.eql(u8, packet.name, "blocks_changed")) continue;
        var entries = std.mem.splitScalar(u8, packet.field("changes") orelse "", ';');
        while (entries.next()) |entry| {
            const equal = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..equal], position) and
                std.mem.indexOf(u8, entry[equal + 1 ..], fragment) != null)
                return true;
        }
    }
    return false;
}

fn directionalPlacementFacings(
    adapter: mcc.Adapter,
    allocator: std.mem.Allocator,
    fixture_id: []const u8,
    comptime expected_state: []const u8,
) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, fixture_id, &clients);
    defer target.deinit();
    const cases = [_]struct {
        yaw: f32,
        facing: []const u8,
        against: t.BlockPos,
        placed: []const u8,
    }{
        .{ .yaw = 0, .facing = "north", .against = .{ .x = 4, .y = 64, .z = 4 }, .placed = "4,65,4" },
        .{ .yaw = 90, .facing = "east", .against = .{ .x = 6, .y = 64, .z = 4 }, .placed = "6,65,4" },
        .{ .yaw = 180, .facing = "south", .against = .{ .x = 4, .y = 64, .z = 6 }, .placed = "4,65,6" },
        .{ .yaw = -90, .facing = "west", .against = .{ .x = 6, .y = 64, .z = 6 }, .placed = "6,65,6" },
    };
    for (cases, 0..) |case, sequence| {
        try target.send("alice", .{ .look = .{ .yaw = case.yaw } });
        try target.send("alice", .{ .use_item_on = .{
            .against = case.against,
            .face = .up,
            .sequence = @intCast(sequence),
        } });
        var batch = try target.tick();
        defer batch.deinit();
        var changes = batch.iterator(.{
            .recipient = "alice",
            .name = "block_changed",
            .field_name = "position",
            .field_value = case.placed,
        });
        var state_buffer: [128]u8 = undefined;
        const state = try std.fmt.bufPrint(&state_buffer, expected_state, .{case.facing});
        var matched = false;
        while (changes.next()) |changed| {
            if (std.mem.eql(u8, changed.field("state") orelse "", state)) matched = true;
        }
        try expect(matched);
    }
}

fn expectInventorySlots(
    batch: *const t.Batch,
    recipient: []const u8,
    screen: []const u8,
    first_slot: []const u8,
    first_stack: []const u8,
    second_slot: []const u8,
    second_stack: []const u8,
) !void {
    var inventories = batch.iterator(.{ .recipient = recipient, .name = "inventory", .field_name = "screen", .field_value = screen });
    while (inventories.next()) |inventory| {
        if (std.mem.eql(u8, inventory.inventorySlot(first_slot) orelse "", first_stack) and
            std.mem.eql(u8, inventory.inventorySlot(second_slot) orelse "", second_stack)) return;
    }
    return error.MissingCanonicalPacket;
}

fn expectInventoryContains(
    batch: *const t.Batch,
    recipient: []const u8,
    screen: []const u8,
    slot: []const u8,
    stack: []const u8,
) !void {
    var inventories = batch.iterator(.{ .recipient = recipient, .name = "inventory", .field_name = "screen", .field_value = screen });
    while (inventories.next()) |inventory|
        if (std.mem.eql(u8, inventory.inventorySlot(slot) orelse "", stack)) return;
    return error.MissingCanonicalPacket;
}

fn placeAndCheck(target: *t.Harness, against: t.BlockPos, sequence: i32, placed: []const u8, remaining: []const u8) !void {
    try target.send("alice", .{ .use_item_on = .{ .against = against, .face = .up, .sequence = sequence } });
    var batch = try target.tick();
    defer batch.deinit();
    const block_selector: t.Selector = .{ .recipient = "bob", .name = "block_changed", .field_name = "position", .field_value = placed };
    const equipment_selector: t.Selector = .{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" };
    const block = batch.first(block_selector) orelse return error.MissingCanonicalPacket;
    try expectText("minecraft:dirt", block.field("state"));
    const equipment = batch.first(equipment_selector) orelse return error.MissingCanonicalPacket;
    try expectText(remaining, equipment.field("stack"));
    // This scenario explicitly cares about observer order.
    try expect(batch.indexOf(block_selector).? < batch.indexOf(equipment_selector).?);
}

fn disconnect(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();
    try target.control("alice", .disconnect);
    var batch = try target.tick();
    defer batch.deinit();
    try expectText("alice%20left%20the%20game", (try batch.one(.{ .recipient = "bob", .name = "system_chat" })).field("message"));
    try expectText("alice", (try batch.one(.{ .recipient = "bob", .name = "entity_destroy" })).field("subjects"));
    try expectText("alice", (try batch.one(.{ .recipient = "bob", .name = "player_remove" })).field("players"));
}

fn loginHeldItem(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "login-held", &clients);
    defer target.deinit();
    try target.control("alice", .disconnect);
    var left = try target.tick();
    left.deinit();
    try target.control("alice", .reconnect);
    var joined = try target.tick();
    defer joined.deinit();
    const inventory = try joined.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h5", "minecraft:dirt*2");
    const selected = try joined.one(.{ .recipient = "alice", .name = "selected_hotbar_slot" });
    try expectText("5", selected.field("slot"));
    const joining_equipment = joined.first(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) orelse return error.MissingCanonicalPacket;
    try expectText("minecraft:dirt*2", joining_equipment.field("stack"));
    const existing_selector: t.Selector = .{ .recipient = "alice", .name = "entity_equipment", .field_name = "subject", .field_value = "bob" };
    var saw_existing_equipment = false;
    if (joined.first(existing_selector)) |existing_equipment| {
        try expectText("minecraft:diamond_shovel*1", existing_equipment.field("stack"));
        saw_existing_equipment = true;
    }
    // Vanilla may begin tracking an already-present entity on a subsequent
    // tick after its own inventory/login bootstrap. The contract is that the
    // joining player receives the equipment during this bounded join window.
    for (0..5) |_| {
        if (saw_existing_equipment) break;
        var tracking = try target.tick();
        defer tracking.deinit();
        if (tracking.first(existing_selector)) |existing_equipment| {
            try expectText("minecraft:diamond_shovel*1", existing_equipment.field("stack"));
            saw_existing_equipment = true;
        }
    }
    try expect(saw_existing_equipment);
}

fn zombieKnockback(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "combat-arena", &clients);
    defer target.deinit();
    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var batch = try target.tick();
    defer batch.deinit();
    for ([_][]const u8{ "alice", "bob" }) |recipient| {
        const velocity = batch.first(.{ .recipient = recipient, .name = "entity_velocity", .field_name = "subject", .field_value = "zombie" }) orelse return error.MissingCanonicalPacket;
        try expectText("3200", velocity.field("x"));
        try expectText("3200", velocity.field("y"));
        try expectText("0", velocity.field("z"));
        _ = batch.first(.{ .recipient = recipient, .name = "entity_moved", .field_name = "subject", .field_value = "zombie" }) orelse return error.MissingCanonicalPacket;
    }
    const equipment = try batch.one(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" });
    try expectText("minecraft:diamond_shovel*1{minecraft:damage=2}", equipment.field("stack"));
}

fn establishLivingVisibility(target: *t.Harness, clients: []const t.Client, entity_type: []const u8) !void {
    for (clients) |client| {
        try target.control(client.name, .disconnect);
        var disconnected = try target.tick();
        disconnected.deinit();
        try target.control(client.name, .reconnect);
        var joined = try target.tick();
        defer joined.deinit();
        _ = joined.first(.{ .recipient = client.name, .name = "entity_spawned", .field_name = "type", .field_value = entity_type }) orelse
            return error.MissingLivingSpawn;
    }
}

fn entityLifecycleReplication(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "entity-lifecycle", &clients);
    defer target.deinit();

    for ([_][]const u8{ "alice", "bob" }) |recipient| {
        try target.control(recipient, .disconnect);
        var disconnected = try target.tick();
        disconnected.deinit();
        try target.control(recipient, .reconnect);
        var joined = try target.tick();
        defer joined.deinit();
        _ = joined.first(.{ .recipient = recipient, .name = "entity_spawned", .field_name = "type", .field_value = "minecraft:zombie" }) orelse
            return error.MissingLivingSpawn;
        const metadata = joined.first(.{ .recipient = recipient, .name = "entity_state", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MissingLivingMetadata;
        try expect(try metadata.fieldFloat("health") == 19);
        if (std.mem.eql(u8, recipient, "bob")) {
            const equipment = joined.first(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) orelse
                return error.MissingPlayerEquipment;
            try expectText("minecraft:diamond_axe*1", equipment.field("stack"));
        }
    }

    var alice_moved = false;
    var bob_moved = false;
    for (0..80) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        alice_moved = alice_moved or batch.first(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "zombie" }) != null;
        bob_moved = bob_moved or batch.first(.{ .recipient = "bob", .name = "entity_moved", .field_name = "subject", .field_value = "zombie" }) != null;
        if (alice_moved and bob_moved) return;
    }
    return error.MissingReplicatedLivingMovement;
}

fn expectMobDamagePackets(batch: *const t.Batch) !void {
    for ([_][]const u8{ "alice", "bob" }) |recipient| {
        _ = batch.first(.{ .recipient = recipient, .name = "entity_damaged", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MissingMobDamageEvent;
        try expect(batch.count(.{ .recipient = recipient, .name = "hurt_animation" }) == 0);
        try expect(batch.count(.{ .recipient = recipient, .name = "entity_status", .field_name = "status", .field_value = "2" }) == 0);
        _ = batch.first(.{ .recipient = recipient, .name = "entity_velocity", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MissingMobKnockback;
        const state = batch.first(.{ .recipient = recipient, .name = "entity_state", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MissingLivingMetadata;
        try expect((try state.fieldFloat("health")) < 20);
    }
}

fn playerAttacksMob(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "entity-lifecycle", &clients);
    defer target.deinit();
    try establishLivingVisibility(&target, &clients, "minecraft:zombie");

    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var first = try target.tick();
    defer first.deinit();
    try expectMobDamagePackets(&first);

    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var invulnerable = try target.tick();
    defer invulnerable.deinit();
    for ([_][]const u8{ "alice", "bob" }) |recipient|
        try expect(invulnerable.count(.{ .recipient = recipient, .name = "entity_damaged", .field_name = "subject", .field_value = "zombie" }) == 0);

    for (0..8) |_| {
        var cooldown = try target.tick();
        defer cooldown.deinit();
    }
    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var recovered = try target.tick();
    defer recovered.deinit();
    for ([_][]const u8{ "alice", "bob" }) |recipient|
        _ = recovered.first(.{ .recipient = recipient, .name = "entity_damaged", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MobInvulnerabilityDidNotExpire;
}

fn expectPlayerDamageProjection(batch: *const t.Batch, recipients: []const t.Client, victim: []const u8) !void {
    for (recipients) |recipient| {
        const damage = batch.first(.{
            .recipient = recipient.name,
            .name = "entity_damaged",
            .field_name = "subject",
            .field_value = victim,
        }) orelse return error.MissingPlayerDamageEvent;
        try expect(try damage.fieldInt(i32, "damage_type") == 34);
        if (std.mem.eql(u8, recipient.name, victim)) {
            const hurt = batch.first(.{
                .recipient = victim,
                .name = "hurt_animation",
                .field_name = "subject",
                .field_value = victim,
            }) orelse return error.MissingPlayerHurtAnimation;
            _ = try hurt.fieldFloat("yaw");
        } else if (batch.count(.{ .recipient = recipient.name, .name = "hurt_animation" }) != 0) {
            return error.UnexpectedPeerPlayerHurtAnimation;
        }
        try expect(batch.count(.{
            .recipient = recipient.name,
            .name = "entity_status",
            .field_name = "status",
            .field_value = "2",
        }) == 0);
    }
}

fn playerMeleeCombat(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{
        .{ .name = "alice" },
        .{ .name = "bob" },
        .{ .name = "observer" },
        .{ .name = "distant" },
    };
    var target = try harness(allocator, adapter, "player-combat", &clients);
    defer target.deinit();

    for (0..20) |_| {
        var cooldown = try target.tick();
        cooldown.deinit();
    }

    try target.send("alice", .{ .attack_entity = .{ .target = "distant" } });
    var rejected = try target.tick();
    defer rejected.deinit();
    try expect(rejected.count(.{ .name = "entity_damaged", .field_name = "subject", .field_value = "distant" }) == 0);
    try expect(rejected.count(.{ .name = "entity_velocity", .field_name = "subject", .field_value = "distant" }) == 0);
    try expect(rejected.count(.{ .recipient = "distant", .name = "health_update" }) == 0);

    try target.send("alice", .{ .attack_entity = .{ .target = "bob" } });
    var full = try target.tick();
    defer full.deinit();
    try expectPlayerDamageProjection(&full, &clients, "bob");
    const full_health = full.first(.{ .recipient = "bob", .name = "health_update" }) orelse
        return error.MissingPlayerHealthUpdate;
    try expect(try full_health.fieldFloat("health") == 11);
    const full_velocity = full.first(.{
        .recipient = "bob",
        .name = "entity_velocity",
        .field_name = "subject",
        .field_value = "bob",
    }) orelse return error.MissingPlayerKnockback;
    try expect(try full_velocity.fieldInt(i32, "x") > 0);
    try expect(try full_velocity.fieldInt(i32, "y") > 0);

    try target.send("alice", .{ .attack_entity = .{ .target = "bob" } });
    var invulnerable = try target.tick();
    defer invulnerable.deinit();
    try expect(invulnerable.count(.{ .name = "entity_damaged", .field_name = "subject", .field_value = "bob" }) == 0);
    try expect(invulnerable.count(.{ .name = "entity_velocity", .field_name = "subject", .field_value = "bob" }) == 0);
    try expect(invulnerable.count(.{ .recipient = "bob", .name = "health_update" }) == 0);

    for (0..10) |_| {
        var cooldown = try target.tick();
        cooldown.deinit();
    }
    try target.send("alice", .{ .attack_entity = .{ .target = "bob" } });
    var partial = try target.tick();
    defer partial.deinit();
    try expectPlayerDamageProjection(&partial, &clients, "bob");
    const partial_health = partial.first(.{ .recipient = "bob", .name = "health_update" }) orelse
        return error.MissingPlayerHealthUpdate;
    try expect(@abs(try partial_health.fieldFloat("health") - 7.652833) < 0.00001);
    _ = partial.first(.{
        .recipient = "bob",
        .name = "entity_velocity",
        .field_name = "subject",
        .field_value = "bob",
    }) orelse return error.MissingPlayerKnockback;
}

fn playerMeleeDeath(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" }, .{ .name = "observer" } };
    var target = try harness(allocator, adapter, "player-combat-death", &clients);
    defer target.deinit();
    for (0..20) |_| {
        var cooldown = try target.tick();
        cooldown.deinit();
    }
    try target.send("alice", .{ .attack_entity = .{ .target = "bob" } });
    var death = try target.tick();
    defer death.deinit();
    try expectPlayerDamageProjection(&death, &clients, "bob");
    const health = death.first(.{ .recipient = "bob", .name = "health_update" }) orelse
        return error.MissingPlayerHealthUpdate;
    try expect(try health.fieldFloat("health") == 0);
    _ = death.first(.{
        .recipient = "bob",
        .name = "entity_velocity",
        .field_name = "subject",
        .field_value = "bob",
    }) orelse return error.MissingPlayerKnockback;
    for (clients) |recipient| {
        const status = death.first(.{
            .recipient = recipient.name,
            .name = "entity_status",
            .field_name = "subject",
            .field_value = "bob",
        }) orelse return error.MissingPlayerDeathStatus;
        try expect(try status.fieldInt(i8, "status") == 3);
        try expectText(
            "bob%20was%20slain%20by%20alice",
            (death.first(.{ .recipient = recipient.name, .name = "system_chat" }) orelse
                return error.MissingPlayerDeathMessage).field("message"),
        );
    }
    _ = death.first(.{ .recipient = "bob", .name = "wire/death_combat_event" }) orelse
        return error.MissingPlayerDeathScreen;
}

fn mobDeathAndRemoval(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "mob-death", &clients);
    defer target.deinit();
    try establishLivingVisibility(&target, &clients, "minecraft:zombie");

    try target.send("alice", .{ .attack_entity = .{ .target = "zombie" } });
    var death = try target.tick();
    defer death.deinit();
    for ([_][]const u8{ "alice", "bob" }) |recipient| {
        _ = death.first(.{ .recipient = recipient, .name = "entity_damaged", .field_name = "subject", .field_value = "zombie" }) orelse
            return error.MissingMobDamageEvent;
        const status = death.first(.{ .recipient = recipient, .name = "entity_status", .field_name = "status", .field_value = "3" }) orelse
            return error.MissingMobDeathStatus;
        try expectText("zombie", status.field("subject"));
        try expect(try status.fieldInt(i8, "status") == 3);
    }

    var removed_alice = false;
    var removed_bob = false;
    for (0..25) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        if (batch.first(.{ .recipient = "alice", .name = "entity_destroy" })) |packet|
            removed_alice = removed_alice or std.mem.eql(u8, packet.field("subjects") orelse "", "zombie");
        if (batch.first(.{ .recipient = "bob", .name = "entity_destroy" })) |packet|
            removed_bob = removed_bob or std.mem.eql(u8, packet.field("subjects") orelse "", "zombie");
        if (removed_alice and removed_bob) return;
    }
    return error.MissingMobRemoval;
}

fn fallingLivingEntities(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "falling-cows", &clients);
    defer target.deinit();

    var descended = [_][2]bool{.{ false, false }} ** 2;
    var landed = [_][2]bool{.{ false, false }} ** 2;
    var damaged = [_][2]bool{.{ false, false }} ** 2;
    var healthy_health = [_]bool{false} ** 2;
    var fatal_died = [_]bool{false} ** 2;
    var fatal_removed = [_]bool{false} ** 2;
    var loot_position = [_]bool{false} ** 2;
    var beef_count = [_]u8{0} ** 2;

    for (0..80) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        for (batch.packets) |packet| {
            const recipient: usize = if (std.mem.eql(u8, packet.recipient, "alice"))
                0
            else if (std.mem.eql(u8, packet.recipient, "bob"))
                1
            else
                continue;
            if (std.mem.eql(u8, packet.name, "entity_moved")) {
                const subject = packet.field("subject") orelse continue;
                const entity: usize = if (std.mem.eql(u8, subject, "healthy-cow"))
                    0
                else if (std.mem.eql(u8, subject, "fatal-cow"))
                    1
                else
                    continue;
                const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
                if (position.y < 76.5) descended[recipient][entity] = true;
                if (@abs(position.y - 65) < 0.001) landed[recipient][entity] = true;
            } else if (std.mem.eql(u8, packet.name, "entity_damaged")) {
                if (try packet.fieldInt(i32, "damage_type") != 10) continue;
                const subject = packet.field("subject") orelse continue;
                if (std.mem.eql(u8, subject, "healthy-cow")) damaged[recipient][0] = true;
                if (std.mem.eql(u8, subject, "fatal-cow")) damaged[recipient][1] = true;
            } else if (std.mem.eql(u8, packet.name, "entity_state") and
                std.mem.eql(u8, packet.field("subject") orelse "", "healthy-cow"))
            {
                if (@abs((try packet.fieldFloat("health")) - 1) < 0.001) healthy_health[recipient] = true;
            } else if (std.mem.eql(u8, packet.name, "entity_status") and
                std.mem.eql(u8, packet.field("subject") orelse "", "fatal-cow") and
                try packet.fieldInt(i8, "status") == 3)
            {
                fatal_died[recipient] = true;
            } else if (std.mem.eql(u8, packet.name, "entity_status") and
                std.mem.eql(u8, packet.field("subject") orelse "", "healthy-cow") and
                try packet.fieldInt(i8, "status") == 3)
            {
                return error.HealthyCowDied;
            } else if (std.mem.eql(u8, packet.name, "entity_destroy") and
                std.mem.eql(u8, packet.field("subjects") orelse "", "fatal-cow"))
            {
                fatal_removed[recipient] = true;
            } else if (std.mem.eql(u8, packet.name, "entity_spawned") and
                std.mem.eql(u8, packet.field("type") orelse "", "minecraft:item"))
            {
                const x = try packet.fieldFloat("x");
                const y = try packet.fieldFloat("y");
                const z = try packet.fieldFloat("z");
                if (@abs(x - 3.5) > 0.001 or @abs(y - 65) > 0.001 or @abs(z - 0.5) > 0.001)
                    return error.LootSpawnedAwayFromDeadCow;
                loot_position[recipient] = true;
            } else if (std.mem.eql(u8, packet.name, "item_spawned")) {
                const stack = packet.field("stack") orelse continue;
                const prefix = "minecraft:beef*";
                if (!std.mem.startsWith(u8, stack, prefix)) continue;
                beef_count[recipient] = std.fmt.parseInt(u8, stack[prefix.len..], 10) catch
                    return error.InvalidBeefDropCount;
            }
        }
    }

    for (0..2) |recipient| {
        if (!descended[recipient][0] or !descended[recipient][1]) return error.MissingCowDescent;
        if (!landed[recipient][0] or !landed[recipient][1]) return error.MissingCowLanding;
        if (!damaged[recipient][0] or !damaged[recipient][1]) return error.MissingCowFallDamage;
        if (!healthy_health[recipient]) return error.MissingHealthyCowHealth;
        if (!fatal_died[recipient]) return error.MissingFatalCowDeath;
        if (!fatal_removed[recipient]) return error.MissingFatalCowRemoval;
        if (!loot_position[recipient]) return error.MissingFatalCowLootPosition;
        if (beef_count[recipient] < 1 or beef_count[recipient] > 3) return error.MissingFatalCowBeef;
    }
    if (beef_count[0] != beef_count[1]) return error.RecipientsSawDifferentCowLoot;
}

fn playerFallMotionAndLanding(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{
        .{ .name = "safe-faller" },
        .{ .name = "threshold-faller" },
        .{ .name = "fatal-faller" },
        .{ .name = "observer" },
    };
    var target = try harness(allocator, adapter, "player-fall-lanes", &clients);
    defer target.deinit();

    var actors = [_]struct {
        name: []const u8,
        x: f64,
        y: f64,
        velocity_y: f64 = 0,
        landed: bool = false,
    }{
        .{ .name = "safe-faller", .x = 0.5, .y = 68 },
        .{ .name = "threshold-faller", .x = 3.5, .y = 69 },
        .{ .name = "fatal-faller", .x = 6.5, .y = 89 },
    };

    for (&actors) |*actor|
        try target.send(actor.name, .{ .move = .{
            .position = .{ .x = actor.x, .y = actor.y, .z = 0.5 },
            .on_ground = false,
        } });
    var initialized = try target.tick();
    initialized.deinit();

    var descended = [_]bool{false} ** actors.len;
    var landed = [_]bool{false} ** actors.len;
    var threshold_health = false;
    var fatal_health = false;
    var threshold_damage = [_]bool{false} ** 2;
    var fatal_damage = [_]bool{false} ** 2;
    var fatal_status = [_]bool{false} ** 2;
    var fatal_chat = [_]bool{false} ** 2;
    var fatal_screen = false;

    for (0..48) |_| {
        for (&actors) |*actor| {
            if (actor.landed) continue;
            actor.velocity_y = (actor.velocity_y - 0.08) * 0.98;
            actor.y += actor.velocity_y;
            if (actor.y <= 65) {
                actor.y = 65;
                actor.velocity_y = 0;
                actor.landed = true;
            }
            try target.send(actor.name, .{ .move = .{
                .position = .{ .x = actor.x, .y = actor.y, .z = 0.5 },
                .on_ground = actor.landed,
            } });
        }

        var batch = try target.tick();
        defer batch.deinit();
        for (batch.packets) |packet| {
            if (std.mem.eql(u8, packet.name, "entity_moved") and std.mem.eql(u8, packet.recipient, "observer")) {
                const subject = packet.field("subject") orelse continue;
                for (actors, 0..) |actor, index| {
                    if (!std.mem.eql(u8, subject, actor.name)) continue;
                    const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
                    if (position.y < actor.y or position.y < 67.9) descended[index] = true;
                    if (@abs(position.y - 65) < 0.001) landed[index] = true;
                }
            } else if (std.mem.eql(u8, packet.name, "health_update")) {
                const health = try packet.fieldFloat("health");
                if (std.mem.eql(u8, packet.recipient, "safe-faller") and health < 20)
                    return error.SafeFallDamagedPlayer;
                if (std.mem.eql(u8, packet.recipient, "threshold-faller") and @abs(health - 19) < 0.001)
                    threshold_health = true;
                if (std.mem.eql(u8, packet.recipient, "fatal-faller") and health == 0)
                    fatal_health = true;
            } else if (std.mem.eql(u8, packet.name, "entity_damaged")) {
                const subject = packet.field("subject") orelse continue;
                if (std.mem.eql(u8, subject, "safe-faller")) return error.SafeFallProjectedDamage;
                if (try packet.fieldInt(i32, "damage_type") != 10) continue;
                const recipient: ?usize = if (std.mem.eql(u8, packet.recipient, subject))
                    0
                else if (std.mem.eql(u8, packet.recipient, "observer"))
                    1
                else
                    null;
                if (recipient) |index| {
                    if (std.mem.eql(u8, subject, "threshold-faller")) threshold_damage[index] = true;
                    if (std.mem.eql(u8, subject, "fatal-faller")) fatal_damage[index] = true;
                }
            } else if (std.mem.eql(u8, packet.name, "hurt_animation")) {
                const subject = packet.field("subject") orelse continue;
                if (std.mem.eql(u8, packet.recipient, "threshold-faller") and std.mem.eql(u8, subject, "threshold-faller"))
                    return error.UnexpectedThresholdFallHurtAnimation;
                if (std.mem.eql(u8, packet.recipient, "fatal-faller") and std.mem.eql(u8, subject, "fatal-faller"))
                    return error.UnexpectedFatalFallHurtAnimation;
            } else if (std.mem.eql(u8, packet.name, "entity_status") and
                std.mem.eql(u8, packet.field("subject") orelse "", "threshold-faller") and
                try packet.fieldInt(i8, "status") == 3)
            {
                return error.ThresholdFallKilledPlayer;
            } else if (std.mem.eql(u8, packet.name, "entity_status") and
                std.mem.eql(u8, packet.field("subject") orelse "", "fatal-faller") and
                try packet.fieldInt(i8, "status") == 3)
            {
                if (std.mem.eql(u8, packet.recipient, "fatal-faller")) fatal_status[0] = true;
                if (std.mem.eql(u8, packet.recipient, "observer")) fatal_status[1] = true;
            } else if (std.mem.eql(u8, packet.name, "system_chat")) {
                if (std.mem.eql(u8, packet.recipient, "fatal-faller")) fatal_chat[0] = true;
                if (std.mem.eql(u8, packet.recipient, "observer")) fatal_chat[1] = true;
            } else if (std.mem.eql(u8, packet.recipient, "fatal-faller") and
                std.mem.eql(u8, packet.name, "wire/death_combat_event"))
            {
                fatal_screen = true;
            }
        }
        if (actors[0].landed and actors[1].landed and actors[2].landed and
            fatal_health and fatal_status[0] and fatal_status[1]) break;
    }

    for (descended) |value| if (!value) return error.MissingPlayerFallDescent;
    for (landed) |value| if (!value) return error.MissingPlayerFallLanding;
    if (!threshold_health) return error.MissingThresholdFallHealth;
    if (!threshold_damage[0] or !threshold_damage[1]) return error.MissingThresholdFallDamageProjection;
    if (!fatal_health) return error.MissingFatalFallHealth;
    if (!fatal_damage[0] or !fatal_damage[1]) return error.MissingFatalFallDamageProjection;
    if (!fatal_status[0] or !fatal_status[1]) return error.MissingFatalFallDeathStatus;
    if (!fatal_chat[0] or !fatal_chat[1]) return error.MissingFatalFallDeathMessage;
    if (!fatal_screen) return error.MissingFatalFallDeathScreen;
}

fn mobAttacksPlayerAndRespawn(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "player-death", &clients);
    defer target.deinit();

    var died = false;
    for (0..80) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        const health = batch.first(.{ .recipient = "alice", .name = "health_update" }) orelse continue;
        if (try health.fieldFloat("health") != 0) continue;
        for ([_][]const u8{ "alice", "bob" }) |recipient| {
            _ = batch.first(.{ .recipient = recipient, .name = "entity_damaged", .field_name = "subject", .field_value = "alice" }) orelse
                return error.MissingPlayerDamageEvent;
            if (std.mem.eql(u8, recipient, "alice")) {
                const hurt = batch.first(.{ .recipient = "alice", .name = "hurt_animation" }) orelse
                    return error.MissingPlayerHurtAnimation;
                try expectText("alice", hurt.field("subject"));
            } else if (batch.count(.{ .recipient = recipient, .name = "hurt_animation" }) != 0) {
                return error.UnexpectedPeerPlayerHurtAnimation;
            }
            if (batch.count(.{ .recipient = recipient, .name = "entity_status", .field_name = "status", .field_value = "2" }) != 0)
                return error.UnexpectedPlayerHurtStatus;
            const status = batch.first(.{ .recipient = recipient, .name = "entity_status", .field_name = "status", .field_value = "3" }) orelse
                return error.MissingPlayerDeathStatus;
            try expectText("alice", status.field("subject"));
            if (try status.fieldInt(i8, "status") != 3) return error.InvalidPlayerDeathStatus;
            _ = batch.first(.{ .recipient = recipient, .name = "system_chat" }) orelse return error.MissingPlayerDeathMessage;
        }
        _ = batch.first(.{ .recipient = "alice", .name = "wire/death_combat_event" }) orelse
            return error.MissingPlayerDeathScreen;
        died = true;
        break;
    }
    if (!died) return error.PlayerDidNotDieWithinTickWindow;

    try target.send("alice", .respawn);
    var respawn = try target.tick();
    defer respawn.deinit();
    _ = respawn.first(.{ .recipient = "alice", .name = "wire/respawn" }) orelse return error.MissingRespawnPacket;
    const health = respawn.first(.{ .recipient = "alice", .name = "health_update" }) orelse return error.MissingRespawnHealth;
    if (try health.fieldFloat("health") != 20) return error.RespawnHealthWasNotRestored;
    _ = respawn.first(.{ .recipient = "alice", .name = "inventory" }) orelse return error.MissingRespawnInventory;
    _ = respawn.first(.{ .recipient = "alice", .name = "player_position" }) orelse return error.MissingRespawnPosition;

    const destroyed = respawn.first(.{ .recipient = "bob", .name = "entity_destroy" }) orelse return error.MissingRespawnPeerRemoval;
    try expectText("alice", destroyed.field("subjects"));
    _ = respawn.first(.{ .recipient = "bob", .name = "entity_spawned", .field_name = "type", .field_value = "minecraft:player" }) orelse
        return error.MissingRespawnPeerSpawn;
    if (respawn.count(.{ .recipient = "bob", .name = "entity_equipment", .field_name = "subject", .field_value = "alice" }) != 0)
        return error.UnexpectedEmptyRespawnPeerEquipment;
    _ = respawn.first(.{ .recipient = "bob", .name = "entity_moved", .field_name = "subject", .field_value = "alice" }) orelse
        return error.MissingRespawnPeerPosition;
}

fn parseCanonicalVec3(text: []const u8) !t.Vec3 {
    var values = std.mem.splitScalar(u8, text, ',');
    return .{
        .x = std.fmt.parseFloat(f64, values.next() orelse return error.InvalidCanonicalPosition) catch return error.InvalidCanonicalPosition,
        .y = std.fmt.parseFloat(f64, values.next() orelse return error.InvalidCanonicalPosition) catch return error.InvalidCanonicalPosition,
        .z = std.fmt.parseFloat(f64, values.next() orelse return error.InvalidCanonicalPosition) catch return error.InvalidCanonicalPosition,
    };
}

fn cowFollowsWheat(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-temptation", &clients);
    defer target.deinit();
    var furthest_x: f64 = 0.5;
    for (0..120) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var moves = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "cow" });
        while (moves.next()) |packet| {
            const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
            furthest_x = @max(furthest_x, position.x);
        }
    }
    try expect(furthest_x > 4.0);
    try expect(furthest_x < 7.0);
}

fn creativeWheatIsAuthoritative(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "creative-wheat", &clients);
    defer target.deinit();
    try target.send("alice", .{ .command = "gamemode creative" });
    var mode = try target.tick();
    mode.deinit();
    try target.send("alice", .{ .creative_slot = .{ .slot = 36, .item = "minecraft:wheat", .count = 64 } });
    var acquired = try target.tick();
    defer acquired.deinit();
    const inventory = try acquired.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h0", "minecraft:wheat*64");

    try target.send("alice", .{ .interact_entity = .{ .target = "cow" } });
    var fed = try target.tick();
    defer fed.deinit();
    const hearts = fed.first(.{ .recipient = "alice", .name = "entity_status", .field_name = "subject", .field_value = "cow" }) orelse
        return error.MissingCanonicalPacket;
    const status = hearts.field("status");
    if (status == null or !std.mem.eql(u8, status.?, "18")) {
        std.debug.print("creative wheat cow status: {s}\n", .{status orelse "missing"});
        return error.UnexpectedCowBreedingStatus;
    }
}

fn gamemodePersists(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();

    try target.send("alice", .{ .command = "gamemode creative" });
    var changed = try target.tick();
    changed.deinit();

    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var rejoined = try target.tick();
    rejoined.deinit();

    try target.send("alice", .{ .creative_slot = .{ .slot = 36, .item = "minecraft:wheat", .count = 64 } });
    var after_reconnect = try target.tick();
    defer after_reconnect.deinit();
    const reconnect_inventory = try after_reconnect.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(reconnect_inventory, "h0", "minecraft:wheat*64");

    try target.restart();
    var restarted = try target.tick();
    restarted.deinit();
    try target.send("alice", .{ .creative_slot = .{ .slot = 37, .item = "minecraft:dirt", .count = 32 } });
    var after_restart = try target.tick();
    defer after_restart.deinit();
    const restart_inventory = try after_restart.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(restart_inventory, "h1", "minecraft:dirt*32");
}

fn cowBreeding(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-breeding", &clients);
    defer target.deinit();
    try target.send("alice", .{ .interact_entity = .{ .target = "cow-a" } });
    var first = try target.tick();
    first.deinit();
    try target.send("alice", .{ .interact_entity = .{ .target = "cow-b" } });
    var second = try target.tick();
    second.deinit();
    for (0..100) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var spawned = batch.iterator(.{ .recipient = "alice", .name = "entity_spawned" });
        while (spawned.next()) |packet| {
            if (std.mem.eql(u8, packet.field("type") orelse "", "minecraft:cow")) return;
        }
    }
    return error.MissingCowCalf;
}

fn cowPanic(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-panic", &clients);
    defer target.deinit();
    try target.send("alice", .{ .attack_entity = .{ .target = "cow" } });
    var attacked = try target.tick();
    defer attacked.deinit();
    _ = attacked.first(.{ .recipient = "alice", .name = "entity_velocity", .field_name = "subject", .field_value = "cow" }) orelse return error.MissingCanonicalPacket;
    const sound = attacked.first(.{ .recipient = "alice", .name = "sound", .field_name = "sound", .field_value = "minecraft:entity.cow.hurt" }) orelse return error.MissingCanonicalPacket;
    try expectText("minecraft:entity.cow.hurt", sound.field("sound"));
    try expectText("0.4", sound.field("volume"));
    var maximum_distance_squared: f64 = 0;
    for (0..100) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var moves = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "cow" });
        while (moves.next()) |packet| {
            const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
            const dx = position.x - 1.5;
            const dz = position.z - 0.5;
            maximum_distance_squared = @max(maximum_distance_squared, dx * dx + dz * dz);
        }
    }
    try expect(maximum_distance_squared > 4);
}

fn cowAmbientSound(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-look", &clients);
    defer target.deinit();
    for (0..1000) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var sounds = batch.iterator(.{ .recipient = "alice", .name = "sound", .field_name = "sound", .field_value = "minecraft:entity.cow.ambient" });
        while (sounds.next()) |sound| {
            if (std.mem.eql(u8, sound.field("sound") orelse "", "minecraft:entity.cow.ambient")) {
                try expectText("0.4", sound.field("volume"));
                return;
            }
        }
    }
    return error.MissingCowAmbientSound;
}

fn calfFollowsParent(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-parent", &clients);
    defer target.deinit();
    var furthest_x: f64 = 0.5;
    for (0..120) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var moves = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "calf" });
        while (moves.next()) |packet| {
            const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
            furthest_x = @max(furthest_x, position.x);
        }
    }
    try expect(furthest_x > 3.0);
    try expect(furthest_x < 6.5);
}

fn cowSwimming(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-swim", &clients);
    defer target.deinit();
    var highest_y: f64 = 64;
    for (0..100) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var moves = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "cow" });
        while (moves.next()) |packet| {
            const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
            highest_y = @max(highest_y, position.y);
        }
    }
    try expect(highest_y > 65);
}

fn cowMilking(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-milking", &clients);
    defer target.deinit();
    try target.send("alice", .{ .interact_entity = .{ .target = "cow" } });
    var milked = try target.tick();
    milked.deinit();

    // Vanilla predicts milking on the client and need not echo the changed
    // hand slot. Rejoining asks the server for an authoritative inventory
    // snapshot without adding a harness-only state oracle.
    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var rejoined = try target.tick();
    defer rejoined.deinit();
    const inventory = try rejoined.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h3", "minecraft:milk_bucket*1");
}

fn calfCannotBeMilked(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "calf-milking", &clients);
    defer target.deinit();
    try target.send("alice", .{ .interact_entity = .{ .target = "calf" } });
    var interaction = try target.tick();
    interaction.deinit();
    try target.control("alice", .disconnect);
    var disconnected = try target.tick();
    disconnected.deinit();
    try target.control("alice", .reconnect);
    var rejoined = try target.tick();
    defer rejoined.deinit();
    const inventory = try rejoined.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h3", "minecraft:bucket*1");
}

fn cowIdleWandering(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-wandering", &clients);
    defer target.deinit();
    var maximum_distance_squared: f64 = 0;
    for (0..1200) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var moves = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "cow" });
        while (moves.next()) |packet| {
            const position = try parseCanonicalVec3(packet.field("position") orelse return error.MissingCanonicalField);
            const dx = position.x - 0.5;
            const dz = position.z - 0.5;
            maximum_distance_squared = @max(maximum_distance_squared, dx * dx + dz * dz);
        }
    }
    try expect(maximum_distance_squared > 4);
}

fn cowLooksAtPlayer(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "cow-look", &clients);
    defer target.deinit();
    for (0..500) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var rotations = batch.iterator(.{ .recipient = "alice", .name = "entity_head_rotation", .field_name = "subject", .field_value = "cow" });
        while (rotations.next()) |packet| {
            const yaw = std.fmt.parseInt(i16, packet.field("yaw") orelse return error.MissingCanonicalField, 10) catch
                return error.InvalidCanonicalRotation;
            if (yaw >= -80 and yaw <= -48) return;
        }
    }
    return error.CowDidNotLookAtPlayer;
}

fn connectedLeaves(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "oak-leaf-connected", &clients);
    defer target.deinit();
    for (0..64) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed" });
        while (changes.next()) |packet| {
            const position = packet.field("position") orelse continue;
            if (isConnectedLeafPosition(position) and std.mem.eql(u8, packet.field("state") orelse "", "minecraft:air"))
                return error.ConnectedLeafDecayed;
        }
    }
}

fn grassCoverSurvival(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "grass-cover", &clients);
    defer target.deinit();
    var saw_control_decay = false;
    for (0..20) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed" });
        while (changes.next()) |packet| {
            if (!std.mem.eql(u8, packet.field("state") orelse "", "minecraft:dirt")) continue;
            const z = canonicalPositionZ(packet.field("position") orelse continue) orelse continue;
            if (z < 4) return error.ChestKilledGrass;
            if (z < 8) return error.LeavesKilledGrass;
            saw_control_decay = true;
        }
        var groups = batch.iterator(.{ .recipient = "alice", .name = "blocks_changed" });
        while (groups.next()) |packet| {
            var entries = std.mem.splitScalar(u8, packet.field("changes") orelse continue, ';');
            while (entries.next()) |entry| {
                if (!std.mem.endsWith(u8, entry, "=minecraft:dirt")) continue;
                const equal = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                const z = canonicalPositionZ(entry[0..equal]) orelse continue;
                if (z < 4) return error.ChestKilledGrass;
                if (z < 8) return error.LeavesKilledGrass;
                saw_control_decay = true;
            }
        }
    }
    if (!saw_control_decay) return error.GrassDecayControlDidNotRun;
}

fn canonicalPositionZ(position: []const u8) ?i32 {
    const first = std.mem.indexOfScalar(u8, position, ',') orelse return null;
    const second_relative = std.mem.indexOfScalar(u8, position[first + 1 ..], ',') orelse return null;
    const second = first + 1 + second_relative;
    return std.fmt.parseInt(i32, position[second + 1 ..], 10) catch null;
}

fn isConnectedLeafPosition(position: []const u8) bool {
    inline for (.{ "-1,100,0", "1,100,0", "0,99,0", "0,101,0", "0,100,-1", "0,100,1" }) |leaf| {
        if (std.mem.eql(u8, position, leaf)) return true;
    }
    return false;
}

fn brokenOakSaplingDropsItself(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "oak-sapling-break", &clients);
    defer target.deinit();
    const position = t.BlockPos{ .x = 0, .y = 65, .z = 0 };
    // Zero-hardness blocks are started and finished in one network batch by
    // the client. Stage both packets before advancing the exact server tick.
    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = position } });
    try target.send("alice", .{ .player_action = .{ .action = .stop_destroy_block, .position = position } });
    var batch = try target.tick();
    defer batch.deinit();
    const changed = try batch.one(.{ .recipient = "alice", .name = "block_changed", .field_name = "position", .field_value = "0,65,0" });
    try expectText("minecraft:air", changed.field("state"));
    const dropped = try batch.one(.{ .recipient = "alice", .name = "item_spawned" });
    try expectText("minecraft:oak_sapling*1", dropped.field("stack"));
}

fn oakLeafDropDistribution(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "oak-leaf-drops", &clients);
    defer target.deinit();
    // Vanilla's ticketed 4x4 fixture yields a little over 6,000 observable
    // decays in the bounded run. At n=6,000 even the rare apple pool has
    // E[X]=30, making the normal 4-sigma assertion meaningful.
    const minimum_trials = 6_000;
    var trials: usize = 0;
    var saplings: usize = 0;
    var sticks: usize = 0;
    var apples: usize = 0;
    var ticks: usize = 0;
    while (trials < minimum_trials and ticks < 1000) : (ticks += 1) {
        var batch = try target.tick();
        defer batch.deinit();
        var changes = batch.iterator(.{ .recipient = "alice", .name = "block_changed", .field_name = "state", .field_value = "minecraft:air" });
        while (changes.next()) |_| trials += 1;
        var drops = batch.iterator(.{ .recipient = "alice", .name = "item_spawned" });
        while (drops.next()) |packet| {
            const stack = packet.field("stack") orelse return error.MissingCanonicalField;
            if (canonicalStackCount(stack, "minecraft:oak_sapling")) |count| {
                saplings += count;
            } else if (canonicalStackCount(stack, "minecraft:stick")) |count| {
                sticks += count;
            } else if (canonicalStackCount(stack, "minecraft:apple")) |count| {
                apples += count;
            } else {
                std.debug.print("unexpected oak leaf drop stack: {s}\n", .{stack});
                return error.UnexpectedOakLeafDrop;
            }
        }
    }
    if (trials < minimum_trials) {
        std.debug.print("oak leaf distribution collected only {} trials in {} ticks (saplings={}, sticks={}, apples={})\n", .{ trials, ticks, saplings, sticks, apples });
        return error.InsufficientOakLeafTrials;
    }
    try expectBinomialFourSigma("oak saplings", saplings, trials, 1.0 / 20.0);
    // Each leaf independently enters the stick pool with p=1/50, then drops
    // one or two sticks uniformly. Item entities may merge before their
    // metadata is observed, so assert the resulting compound distribution:
    // E[X]=0.03 and Var(X)=0.02*E[U^2]-E[X]^2=0.0491.
    try expectSumFourSigma("oak sticks", sticks, trials, 0.03, 0.0491);
    try expectBinomialFourSigma("apples", apples, trials, 1.0 / 200.0);
}

fn canonicalStackCount(stack: []const u8, item: []const u8) ?usize {
    if (!std.mem.startsWith(u8, stack, item) or stack.len <= item.len or stack[item.len] != '*') return null;
    return std.fmt.parseUnsigned(usize, stack[item.len + 1 ..], 10) catch null;
}

fn expectBinomialFourSigma(label: []const u8, successes: usize, trials: usize, probability: f64) !void {
    if (trials == 0 or probability <= 0 or probability >= 1) return error.InvalidBinomialAssertion;
    const n: f64 = @floatFromInt(trials);
    const observed: f64 = @floatFromInt(successes);
    const mean = n * probability;
    const sigma = @sqrt(n * probability * (1.0 - probability));
    const deviations = @abs(observed - mean) / sigma;
    if (deviations > 4.0) {
        std.debug.print("{s} outside 4 sigma: successes={} trials={} p={d} mean={d} sigma={d} deviations={d}\n", .{ label, successes, trials, probability, mean, sigma, deviations });
        return error.BinomialDistributionOutsideFourSigma;
    }
}

fn expectSumFourSigma(label: []const u8, observed_count: usize, trials: usize, mean_per_trial: f64, variance_per_trial: f64) !void {
    if (trials == 0 or variance_per_trial <= 0) return error.InvalidStatisticalAssertion;
    const n: f64 = @floatFromInt(trials);
    const observed: f64 = @floatFromInt(observed_count);
    const mean = n * mean_per_trial;
    const sigma = @sqrt(n * variance_per_trial);
    const deviations = @abs(observed - mean) / sigma;
    if (deviations > 4.0) {
        std.debug.print("{s} outside 4 sigma: observed={} trials={} mean={d} sigma={d} deviations={d}\n", .{ label, observed_count, trials, mean, sigma, deviations });
        return error.DistributionOutsideFourSigma;
    }
}

fn zombieOpenTrapdoor(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "zombie-open-trapdoor", &clients);
    defer target.deinit();
    var saw_below_trapdoor = false;
    for (0..6) |_| {
        var batch = try target.tick();
        defer batch.deinit();
        var movements = batch.iterator(.{ .recipient = "alice", .name = "entity_moved", .field_name = "subject", .field_value = "zombie" });
        while (movements.next()) |packet| {
            const position = packet.field("position") orelse continue;
            var coordinates = std.mem.splitScalar(u8, position, ',');
            _ = coordinates.next();
            const y = std.fmt.parseFloat(f64, coordinates.next() orelse return error.InvalidCanonicalPosition) catch return error.InvalidCanonicalPosition;
            if (y < 65) saw_below_trapdoor = true;
        }
    }
    try expect(saw_below_trapdoor);
}

fn flightRejected(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "movement-arena", &clients);
    defer target.deinit();
    try target.send("alice", .{ .move = .{ .position = .{ .x = 12, .y = 80, .z = 1 }, .on_ground = false } });
    var batch = try target.tick();
    defer batch.deinit();
    const correction = try batch.one(.{ .recipient = "alice", .name = "player_position" });
    try expectText("12", correction.field("x"));
    try expectText("70", correction.field("y"));
    try expect(batch.count(.{ .recipient = "bob", .name = "entity_moved", .field_name = "subject", .field_value = "alice" }) == 0);
}

fn hoverRejected(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "flight-arena", &clients);
    defer target.deinit();
    for (0..vanilla_floating_grace_packets + 1) |index| {
        try target.send("alice", .{ .move = .{ .position = .{ .x = 12, .y = 80, .z = 1 }, .on_ground = false } });
        var batch = try target.tick();
        defer batch.deinit();
        if (index < vanilla_floating_grace_packets) {
            try expect(batch.count(.{ .recipient = "alice", .name = "player_position" }) == 0);
        } else {
            const correction = try batch.one(.{ .recipient = "alice", .name = "player_position" });
            try expectText("80", correction.field("y"));
        }
    }
}

const vanilla_floating_grace_packets = 80;

fn remoteMiningRejected(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{ .{ .name = "alice" }, .{ .name = "bob" } };
    var target = try harness(allocator, adapter, "reach-arena", &clients);
    defer target.deinit();
    try target.send("alice", .{ .player_action = .{ .action = .start_destroy_block, .position = .{ .x = 20, .y = 64, .z = 0 } } });
    var batch = try target.tick();
    defer batch.deinit();
    try expect(batch.count(.{ .recipient = "bob", .name = "block_break_animation", .field_name = "subject", .field_value = "alice" }) == 0);
}

fn inventoryClaimRejected(adapter: mcc.Adapter, allocator: std.mem.Allocator) !void {
    const clients = [_]t.Client{.{ .name = "alice" }};
    var target = try harness(allocator, adapter, "flat-world", &clients);
    defer target.deinit();
    try target.send("alice", .{ .container_click = .{
        .slot = -999,
        .button = 0,
        .mode = 0,
        .claimed = .{ .slot = 36, .item_id = 1, .count = 64 },
    } });
    var batch = try target.tick();
    defer batch.deinit();
    const inventory = try batch.one(.{ .recipient = "alice", .name = "inventory" });
    try expectSlot(inventory, "h0", "empty");
    for (inventory.fields) |field| try expect(std.mem.indexOf(u8, field.value.literal, "*64") == null);
}
