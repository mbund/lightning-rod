//! World events and sounds at a place, sent to the players vanilla sends them to: world events
//! to those within 64 blocks (ServerWorld.syncWorldEvent), sounds to those within 16 blocks per
//! unit of volume but the one who made them, whose own client plays them (World.playSound).

const std = @import("std");
const chunks = @import("chunks");
const minecraft = @import("minecraft_model");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");
const wire_26_1 = @import("wire_26_1");
const wire_26_2 = @import("wire_26_2");
const Players = @import("players").players.Players;

/// SoundCategory, in vanilla's order.
pub const Category = enum(u8) { master, music, records, weather, blocks, hostile, neutral, players, ambient, voice, ui };

pub const Effects = struct {
    players: *Players,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, players: *Players) !Effects {
        return .{
            .players = players,
            .targets = try allocator.alloc(sessions.Service.Target, players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players.records.len),
        };
    }

    /// The ready players in `world` closer than `range` to `at`, but `except`.
    fn gather(self: *Effects, world: u32, at: minecraft.Position, range: f64, except: ?usize) usize {
        const players = self.players;
        var candidates = players.nearby(world, at, @intFromFloat(@ceil(range / 16) + 1));
        var count: usize = 0;
        while (candidates.next()) |index| {
            if (except == index) continue;
            const player = players.records[index];
            const recipient = player.handle orelse continue;
            if (player.world != world or player.stage != .ready) continue;
            const dx = player.position.x - at.x;
            const dy = player.position.y - at.y;
            const dz = player.position.z - at.z;
            if (dx * dx + dy * dy + dz * dz >= range * range) continue;
            self.targets[count] = .{ .handle = recipient, .protocol = player.protocol };
            count += 1;
        }
        return count;
    }

    pub fn worldEvent(self: *Effects, world: u32, position: chunks.Position, event: i32, data: i32) void {
        self.worldEventExcept(world, position, event, data, null);
    }

    /// Level.levelEvent with a player: everyone near but that player, whose client shows it.
    pub fn worldEventExcept(self: *Effects, world: u32, position: chunks.Position, event: i32, data: i32, except: ?usize) void {
        const at: minecraft.Position = .{ .x = @floatFromInt(position.x), .y = @floatFromInt(position.y), .z = @floatFromInt(position.z) };
        const count = self.gather(world, at, 64, except);
        if (count == 0) return;
        self.players.deps.packets.fanout(writeWorldEvent, self.targets[0..count], .{ position, event, data }, 64, self.deliveries[0..count]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    /// A sound at a point, for everyone near it but `except`.
    pub fn sound(self: *Effects, world: u32, at: minecraft.Position, name: []const u8, category: Category, volume: f32, pitch: f32, seed: i64, except: ?usize) void {
        const count = self.gather(world, at, if (volume > 1) 16 * @as(f64, volume) else 16, except);
        if (count == 0) return;
        self.players.deps.packets.fanout(writeSound, self.targets[0..count], .{ name, @backingInt(category), at, volume, pitch, seed }, 256, self.deliveries[0..count]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    /// A sound that follows an entity, Level.playSound with an entity, for everyone near it but
    /// `except`: those a sound at its place would reach, each client playing it where the entity
    /// is as it moves.
    pub fn entitySound(self: *Effects, world: u32, at: minecraft.Position, entity: i32, name: []const u8, category: Category, volume: f32, pitch: f32, seed: i64, except: ?usize) void {
        const count = self.gather(world, at, if (volume > 1) 16 * @as(f64, volume) else 16, except);
        if (count == 0) return;
        self.players.deps.packets.fanout(writeEntitySound, self.targets[0..count], .{ name, @backingInt(category), entity, volume, pitch, seed }, 256, self.deliveries[0..count]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    /// A sound at the middle of a block, as World.playSound with a BlockPos places it.
    pub fn blockSound(self: *Effects, world: u32, position: chunks.Position, name: []const u8, category: Category, volume: f32, pitch: f32, seed: i64, except: ?usize) void {
        const at: minecraft.Position = .{ .x = @as(f64, @floatFromInt(position.x)) + 0.5, .y = @as(f64, @floatFromInt(position.y)) + 0.5, .z = @as(f64, @floatFromInt(position.z)) + 0.5 };
        self.sound(world, at, name, category, volume, pitch, seed, except);
    }

    pub const Particles = struct {
        particle: packets.Particle,
        at: minecraft.Position,
        count: i32,
        offset: [3]f32 = @splat(0),
        speed: f32 = 0,
    };

    /// Particles for one player alone, as a debugging view shows what only it asked to see.
    pub fn particlesTo(self: *Effects, player: *const @import("players").player_state.Player, request: Particles) void {
        std.debug.assert(request.count >= 0);
        const recipient = player.handle orelse return;
        if (player.stage != .ready) return;
        self.targets[0] = .{ .handle = recipient, .protocol = player.protocol };
        self.players.deps.packets.fanout(writeParticles, self.targets[0..1], .{request}, 64, self.deliveries[0..1]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    /// ServerLevel.sendParticles without forcing: for the players within 32 blocks.
    pub fn particles(self: *Effects, world: u32, request: Particles) void {
        std.debug.assert(request.count >= 0);
        const count = self.gather(world, request.at, 32, null);
        if (count == 0) return;
        self.players.deps.packets.fanout(writeParticles, self.targets[0..count], .{request}, 64, self.deliveries[0..count]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }
};

fn writeParticles(packet: wire_1_21_5.play.toClient.packet_world_particles.Writer, mapping: packets.Registry, request: Effects.Particles) ![]u8 {
    const placed = try (try (try (try (try packet.longDistance(false)).alwaysShow(false)).x(request.at.x)).y(request.at.y)).z(request.at.z);
    const spread = try (try (try (try placed.offsetX(request.offset[0])).offsetY(request.offset[1])).offsetZ(request.offset[2])).velocityOffset(request.speed);
    var particle = try (try spread.amount(request.count)).particle();
    return (try particle.advance(try packets.nested(.{ writeParticle, writeParticlePacked, writeParticleModern, writeParticleLatest }).write(try particle.begin(), try mapping.particleId(request.particle)))).finish();
}

/// A particle with no data of its own.
fn writeParticle(packet: wire_1_21_5.Particle.Writer, id: i32) !wire_1_21_5.Particle.Writer.Done {
    var data = try (try packet.type(id)).data();
    return data.advance(try (try data.begin()).case_default());
}

/// The same from 1.21.9, whose particles carry other data.
fn writeParticlePacked(packet: wire_1_21_9.Particle.Writer, id: i32) !wire_1_21_9.Particle.Writer.Done {
    var data = try (try packet.type(id)).data();
    return data.advance(try (try data.begin()).case_default());
}

/// And from 26.1.
fn writeParticleModern(packet: wire_26_1.Particle.Writer, id: i32) !wire_26_1.Particle.Writer.Done {
    var data = try (try packet.type(id)).data();
    return data.advance(try (try data.begin()).case_default());
}

/// And from 26.2.
fn writeParticleLatest(packet: wire_26_2.Particle.Writer, id: i32) !wire_26_2.Particle.Writer.Done {
    var data = try (try packet.type(id)).data();
    return data.advance(try (try data.begin()).case_default());
}

fn writeWorldEvent(cursor: wire_1_21_5.play.toClient.packet_world_event.Writer, _: packets.Registry, position: chunks.Position, event: i32, data: i32) ![]u8 {
    const packet = try cursor.effectId(event);
    const located = try packet.location(.{ .x = @intCast(position.x), .y = @intCast(position.y), .z = @intCast(position.z) });
    return (try (try located.data(data)).global(false)).finish();
}

fn writeSound(packet: wire_1_21_5.play.toClient.packet_sound_effect.Writer, name: []const u8, category: u8, at: minecraft.Position, volume: f32, pitch: f32, seed: i64) ![]u8 {
    var holder = try packet.sound();
    const selected = try packets.nested(.{writeSoundHolder}).write(try holder.begin(), name);
    const categorised = try (try holder.advance(selected)).soundCategory(category);
    const located = try (try (try categorised.x(@intFromFloat(at.x * 8))).y(@intFromFloat(at.y * 8))).z(@intFromFloat(at.z * 8));
    return (try (try (try located.volume(volume)).pitch(pitch)).seed(seed)).finish();
}

fn writeEntitySound(packet: wire_1_21_5.play.toClient.packet_entity_sound_effect.Writer, name: []const u8, category: u8, entity: i32, volume: f32, pitch: f32, seed: i64) ![]u8 {
    var holder = try packet.sound();
    const selected = try packets.nested(.{writeSoundHolder}).write(try holder.begin(), name);
    const categorised = try (try holder.advance(selected)).soundCategory(category);
    return (try (try (try (try categorised.entityId(entity)).volume(volume)).pitch(pitch)).seed(seed)).finish();
}

fn writeSoundHolder(packet: wire_1_21_5.ItemSoundHolder.Writer, name: []const u8) !wire_1_21_5.ItemSoundHolder.Writer.Done {
    var data = try packet.data();
    return data.advance(try packets.nested(.{writeSoundEvent}).write(try data.begin(), name));
}

fn writeSoundEvent(packet: wire_1_21_5.ItemSoundEvent.Writer, name: []const u8) !wire_1_21_5.ItemSoundEvent.Writer.Done {
    var range = try (try packet.soundName(name)).fixedRange();
    return range.advance(try (try range.begin()).none());
}
