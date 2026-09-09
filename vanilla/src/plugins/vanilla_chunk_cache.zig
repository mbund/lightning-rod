const std = @import("std");
const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const Packets = lightning_rod.Packets;
const vanilla_persistence = @import("vanilla_persistence.zig");
const vanilla_chunk_streaming = @import("vanilla_chunk_streaming.zig");

const DeferredBlock = struct {
    request: input_store.BlockRequest,
    session: player_store.Session,
};

pub const ReleaseMaterializations = struct {
    pub const id = "minecraft:release_materializations";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *block_store.Blocks,
        streaming: *vanilla_chunk_streaming.ChunkStreaming,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*ReleaseMaterializations {
        const self = try allocator.create(ReleaseMaterializations);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *ReleaseMaterializations, _: std.mem.Allocator) void {
        _ = self.deps.blocks.releaseMaterializationsRetaining(self.deps.streaming, retainStreamingChunk);
    }

    fn retainStreamingChunk(context: *const anyopaque, world: lightning_rod.world_identity.Handle, chunk: geometry.ChunkPos) bool {
        const streaming: *const vanilla_chunk_streaming.ChunkStreaming = @ptrCast(@alignCast(context));
        return streaming.needsMaterialization(world, chunk);
    }
};

pub const ChunkCache = struct {
    pub const id = "minecraft:chunk_cache";
    pub const Configuration = struct {
        maximum_deferred_block_requests: usize = 128,
        maximum_deferred_dig_actions_per_player: usize = 8,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_deferred_block_requests == 0 or
                self.maximum_deferred_dig_actions_per_player == 0 or
                self.maximum_deferred_dig_actions_per_player > std.math.maxInt(u8))
                return error.InvalidDeferredInputCapacity;
        }
    };
    pub const Dependencies = struct {
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        materialization: *vanilla_persistence.Materializer,
        outputs: *Packets,
        runtime_metrics: ?*lightning_rod.metrics.Runtime = null,
    };

    deps: Dependencies,
    deferred_blocks: []DeferredBlock,
    deferred_block_count: usize = 0,
    deferred_digs: []input_store.DigAction,
    deferred_dig_counts: []u8,
    deferred_dig_sessions: []player_store.Session,
    deferred_dig_worlds: []lightning_rod.world_identity.Handle,
    deferred_digs_per_player: usize,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*ChunkCache {
        try configuration.validate();
        const self = try allocator.create(ChunkCache);
        self.* = .{
            .deps = deps,
            .deferred_blocks = try allocator.alloc(DeferredBlock, configuration.maximum_deferred_block_requests),
            .deferred_digs = try allocator.alloc(input_store.DigAction, deps.players.records.len * configuration.maximum_deferred_dig_actions_per_player),
            .deferred_dig_counts = try allocator.alloc(u8, deps.players.records.len),
            .deferred_dig_sessions = try allocator.alloc(player_store.Session, deps.players.records.len),
            .deferred_dig_worlds = try allocator.alloc(lightning_rod.world_identity.Handle, deps.players.records.len),
            .deferred_digs_per_player = configuration.maximum_deferred_dig_actions_per_player,
        };
        @memset(self.deferred_dig_counts, 0);
        return self;
    }

    pub fn tick(self: *ChunkCache, _: std.mem.Allocator) void {
        self.replayDeferredInputs();
        self.admitBlockInteractions();
        if (self.deps.runtime_metrics) |runtime| {
            var digs: usize = 0;
            for (self.deferred_dig_counts) |count| digs += count;
            runtime.setDeferredInputs(self.deferred_block_count, digs);
        }
    }

    fn replayDeferredInputs(self: *ChunkCache) void {
        var index = self.deferred_block_count;
        while (index != 0) {
            index -= 1;
            const deferred = self.deferred_blocks[index];
            const request = deferred.request;
            const player = &self.deps.players.records[request.slot];
            const session = self.deps.players.session(request.slot);
            if (player.state != .play or !player.world.eql(request.world) or session == null or !session.?.eql(deferred.session)) {
                self.removeDeferredBlock(index);
                continue;
            }
            if (!self.requestChunksResident(request)) continue;
            self.deps.inputs.prependBlockRequest(request) catch continue;
            self.removeDeferredBlock(index);
        }

        for (self.deferred_dig_counts, 0..) |*count, slot| {
            if (count.* == 0) continue;
            const player = &self.deps.players.records[slot];
            const session = self.deps.players.session(@intCast(slot));
            if (player.state != .play or session == null or !session.?.eql(self.deferred_dig_sessions[slot]) or
                !player.world.eql(self.deferred_dig_worlds[slot]))
            {
                count.* = 0;
                continue;
            }
            const base = slot * self.deferred_digs_per_player;
            const actions = self.deferred_digs[base..][0..count.*];
            var ready = true;
            for (actions) |action| {
                const pos = digPosition(action) orelse continue;
                const chunk = geometry.chunkForBlock(pos);
                if (self.deps.blocks.materializedChunk(player.world, chunk) != null) continue;
                _ = self.deps.materialization.requestCold(player.world, chunk);
                ready = false;
            }
            if (!ready) continue;
            self.deps.inputs.prependDigActions(@intCast(slot), actions) catch continue;
            count.* = 0;
        }
    }

    fn admitBlockInteractions(self: *ChunkCache) void {
        for (self.deps.inputs.block_requests[0..self.deps.inputs.block_request_count]) |*request| {
            if (request.handled or self.blockRequestResident(request.*)) continue;
            _ = self.deps.materialization.requestCold(request.world, geometry.chunkForBlock(request.pos));
            if (request.kind == .use_item_on)
                _ = self.deps.materialization.requestCold(request.world, geometry.chunkForBlock(request.against_pos));
            self.deferBlock(request.*);
            request.handled = true;
            self.deps.outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            self.deps.outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
            self.deps.outputs.inventory_changed(request.slot);
        }
        for (self.deps.players.activeSlots()) |slot| {
            const actions = self.deps.inputs.digActions(slot);
            if (actions.len == 0) continue;
            const world = self.deps.players.records[slot].world;
            var missing = false;
            for (actions) |action| {
                const pos = digPosition(action) orelse continue;
                const chunk = geometry.chunkForBlock(pos);
                if (self.deps.blocks.materializedChunk(world, chunk) != null) continue;
                _ = self.deps.materialization.requestCold(world, chunk);
                missing = true;
            }
            if (!missing) continue;
            const base = @as(usize, slot) * self.deferred_digs_per_player;
            const old_count: usize = self.deferred_dig_counts[slot];
            if (old_count + actions.len <= self.deferred_digs_per_player) {
                if (old_count == 0) {
                    self.deferred_dig_sessions[slot] = self.deps.players.session(slot).?;
                    self.deferred_dig_worlds[slot] = world;
                }
                @memcpy(self.deferred_digs[base + old_count ..][0..actions.len], actions);
                self.deferred_dig_counts[slot] = @intCast(old_count + actions.len);
            }
            for (actions) |action| if (digPosition(action)) |pos|
                self.deps.outputs.block_correction(.{ .slot = slot, .pos = pos });
            self.deps.inputs.clearDigActions(slot);
        }
    }

    fn requestChunksResident(self: *ChunkCache, request: input_store.BlockRequest) bool {
        var ready = self.requestChunkResident(request.world, geometry.chunkForBlock(request.pos));
        if (request.kind == .use_item_on)
            ready = self.requestChunkResident(request.world, geometry.chunkForBlock(request.against_pos)) and ready;
        return ready;
    }

    fn blockRequestResident(self: *const ChunkCache, request: input_store.BlockRequest) bool {
        if (self.deps.blocks.materializedChunk(request.world, geometry.chunkForBlock(request.pos)) == null) return false;
        return request.kind != .use_item_on or
            self.deps.blocks.materializedChunk(request.world, geometry.chunkForBlock(request.against_pos)) != null;
    }

    fn requestChunkResident(self: *ChunkCache, world: lightning_rod.world_identity.Handle, chunk: geometry.ChunkPos) bool {
        if (self.deps.blocks.materializedChunk(world, chunk) != null) return true;
        _ = self.deps.materialization.requestCold(world, chunk);
        return false;
    }

    fn deferBlock(self: *ChunkCache, request: input_store.BlockRequest) void {
        const session = self.deps.players.session(request.slot) orelse return;
        for (self.deferred_blocks[0..self.deferred_block_count]) |existing|
            if (existing.request.slot == request.slot and existing.request.sequence == request.sequence and existing.session.eql(session)) return;
        if (self.deferred_block_count == self.deferred_blocks.len) return;
        self.deferred_blocks[self.deferred_block_count] = .{ .request = request, .session = session };
        self.deferred_block_count += 1;
    }

    fn removeDeferredBlock(self: *ChunkCache, index: usize) void {
        std.mem.copyForwards(
            DeferredBlock,
            self.deferred_blocks[index .. self.deferred_block_count - 1],
            self.deferred_blocks[index + 1 .. self.deferred_block_count],
        );
        self.deferred_block_count -= 1;
    }

    fn digPosition(action: input_store.DigAction) ?geometry.BlockPos {
        return switch (action) {
            .none => null,
            .start => |value| value.pos,
            .finish => |value| value.pos,
            .cancel => |value| value.pos,
        };
    }
};
