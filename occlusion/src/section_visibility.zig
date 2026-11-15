const std = @import("std");
const assert = std.debug.assert;

pub const side = 16;
pub const volume = side * side * side;

pub const Bounds = struct {
    minimum: [3]i32,
    maximum: [3]i32,

    pub fn fromBits(bits: *const [64]u64) Bounds {
        return fromWords(bits, false);
    }

    fn fromWords(bits: *const [64]u64, comptime invert: bool) Bounds {
        var result: Bounds = .{ .minimum = @splat(16), .maximum = @splat(0) };
        var columns: u16 = 0;
        for (bits, 0..) |stored, index| {
            const word = if (invert) ~stored else stored;
            if (word == 0) continue;
            columns |= @truncate(word | (word >> 16) | (word >> 32) | (word >> 48));
            result.minimum[1] = @min(result.minimum[1], @as(i32, @intCast(index / 4)));
            result.maximum[1] = @as(i32, @intCast(index / 4 + 1));
            result.minimum[2] = @min(result.minimum[2], @as(i32, @intCast(index % 4 * 4 + @ctz(word) / 16)));
            result.maximum[2] = @max(result.maximum[2], @as(i32, @intCast(index % 4 * 4 + (63 - @clz(word)) / 16 + 1)));
        }
        assert(columns != 0);
        result.minimum[0] = @intCast(@ctz(columns));
        result.maximum[0] = @intCast(16 - @clz(columns));
        return result;
    }
};

pub const Grid = struct {
    minimum: [3]i32,
    size: [3]usize,

    pub fn count(self: Grid) usize {
        return self.size[0] * self.size[1] * self.size[2];
    }

    pub fn index(self: Grid, at: [3]i32) ?usize {
        var local: [3]usize = undefined;
        for (0..3) |axis| {
            const offset = @as(i64, at[axis]) - self.minimum[axis];
            if (offset < 0 or offset >= self.size[axis]) return null;
            local[axis] = @intCast(offset);
        }
        return (local[2] * self.size[0] + local[0]) * self.size[1] + local[1];
    }

    pub fn position(self: Grid, entry: usize) [3]i32 {
        assert(entry < self.count());
        return .{
            self.minimum[0] + @as(i32, @intCast(entry / self.size[1] % self.size[0])),
            self.minimum[1] + @as(i32, @intCast(entry % self.size[1])),
            self.minimum[2] + @as(i32, @intCast(entry / self.size[1] / self.size[0])),
        };
    }
};

pub const Component = struct { seed: u12, faces: u6 };

pub const Workspace = struct {
    seen: [volume / 64]u64 = undefined,
    component_bits: [volume / 64]u64 = undefined,
    cuts: [3][15]?Bounds = undefined,
    reached: [64]u64 = undefined,
    labels: [256]u64 = undefined,
    count: usize = 0,

    fn visit(self: *Workspace, word: usize, bits: u64, pending: *u64) void {
        assert(word < self.seen.len);
        const fresh = bits & ~self.seen[word];
        if (fresh == 0) return;
        self.seen[word] |= fresh;
        self.component_bits[word] |= fresh;
        self.count += @popCount(fresh);
        pending.* |= @as(u64, 1) << @intCast(word);
    }

    fn flood(self: *Workspace, seed: u12) Component {
        assert(self.seen[seed / 64] & (@as(u64, 1) << @intCast(seed % 64)) == 0);
        @memset(&self.component_bits, 0);
        self.count = 0;
        var pending: u64 = 0;
        self.visit(seed / 64, @as(u64, 1) << @intCast(seed % 64), &pending);
        while (pending != 0) {
            const word: usize = @ctz(pending);
            pending &= pending - 1;
            const previous = self.component_bits[word];
            const open = ~self.seen[word] | previous;
            var bits = previous;
            while (true) {
                // A word contains four complete X rows. Mask X edges before shifting.
                const adjacent = ((bits & 0x7fff7fff7fff7fff) << 1) | ((bits & 0xfffefffefffefffe) >> 1) | (bits << 16) | (bits >> 16);
                const expanded = bits | (adjacent & open);
                if (expanded == bits) break;
                bits = expanded;
            }
            const fresh = bits & ~previous;
            self.seen[word] |= fresh;
            self.component_bits[word] = bits;
            self.count += @popCount(fresh);
            if (word >= 4) self.visit(word - 4, bits, &pending);
            if (word + 4 < self.seen.len) self.visit(word + 4, bits, &pending);
            if (word % 4 != 0) self.visit(word - 1, bits << 48, &pending);
            if (word % 4 != 3) self.visit(word + 1, bits >> 48, &pending);
        }
        var component: Component = .{ .seed = seed, .faces = 0 };
        var combined: u64 = 0;
        for (self.component_bits, 0..) |bits, word| {
            if (bits == 0) continue;
            component.seed = @min(component.seed, @as(u12, @intCast(word * 64 + @ctz(bits))));
            combined |= bits;
            if (word < 4) component.faces |= 4;
            if (word >= 60) component.faces |= 8;
            if (word % 4 == 0 and bits & 0xffff != 0) component.faces |= 16;
            if (word % 4 == 3 and bits & 0xffff000000000000 != 0) component.faces |= 32;
        }
        if (combined & 0x0001000100010001 != 0) component.faces |= 1;
        if (combined & 0x8000800080008000 != 0) component.faces |= 2;
        assert(self.count > 0 and self.count <= volume);
        return component;
    }

    fn geometry(self: *const Workspace) ComponentGeometry {
        assert(self.count > 0);
        var result: ComponentGeometry = .{ .bounds = Bounds.fromBits(&self.component_bits), .portals = undefined };
        result.rectangular = boundsVolume(result.bounds) == self.count;
        for (&result.portals, 0..) |*portal, face| portal.* = extractFace(&self.component_bits, face, false);
        return result;
    }
};

const ComponentGeometry = struct { bounds: Bounds, rectangular: bool = false, portals: [6][4]u64 };

fn boundsVolume(bounds: Bounds) usize {
    return @intCast((bounds.maximum[0] - bounds.minimum[0]) * (bounds.maximum[1] - bounds.minimum[1]) * (bounds.maximum[2] - bounds.minimum[2]));
}

const ComponentBounds = packed struct(u32) {
    minimum_x: u4 = 0,
    maximum_x: u4 = 15,
    minimum_y: u4 = 0,
    maximum_y: u4 = 15,
    minimum_z: u4 = 0,
    maximum_z: u4 = 15,
    faces: u6 = 63,
    rectangular: bool = true,
    reserved: u1 = 0,

    fn init(bounds: Bounds, faces: u6, rectangular: bool) ComponentBounds {
        return .{
            .minimum_x = @intCast(bounds.minimum[0]),
            .maximum_x = @intCast(bounds.maximum[0] - 1),
            .minimum_y = @intCast(bounds.minimum[1]),
            .maximum_y = @intCast(bounds.maximum[1] - 1),
            .minimum_z = @intCast(bounds.minimum[2]),
            .maximum_z = @intCast(bounds.maximum[2] - 1),
            .faces = faces,
            .rectangular = rectangular,
        };
    }

    fn geometry(self: ComponentBounds) Bounds {
        return .{
            .minimum = .{ self.minimum_x, self.minimum_y, self.minimum_z },
            .maximum = .{ @as(i32, self.maximum_x) + 1, @as(i32, self.maximum_y) + 1, @as(i32, self.maximum_z) + 1 },
        };
    }
};

pub const Topology = struct {
    paths: u36 = 0,
    pub const closed: Topology = .{};
    pub const open: Topology = .{ .paths = (1 << 36) - 1 };

    // Reversing a ray exchanges entry and exit and reverses all three directions.
    pub fn index(octant: usize, entry: usize, exit: usize) usize {
        assert(octant < 8 and entry < 3 and exit < 3);
        return if (octant < 4) octant * 9 + entry * 3 + exit else (octant ^ 7) * 9 + exit * 3 + entry;
    }

    pub fn fromConnections(connections: [6]u6) Topology {
        var result: Topology = .{};
        inline for (0..4) |octant| inline for (0..3) |entry| inline for (0..3) |exit| {
            const from = entry * 2 + 1 - ((octant >> entry) & 1);
            const to = exit * 2 + ((octant >> exit) & 1);
            assert((connections[from] >> to) & 1 == (connections[to] >> from) & 1);
            if (connections[from] & (@as(u6, 1) << to) != 0) result.paths |= @as(u36, 1) << comptime index(octant, entry, exit);
        };
        return result;
    }
};

pub const Section = struct {
    // Each adjacent X pair contributes at most one component and one row run.
    // Each octant maps 16 tiles on each incoming face to its three outgoing faces.
    const transfer_prefix = 6 * (@sizeOf(u64) + @sizeOf(u16));
    pub const transfer_bytes = transfer_prefix + 8 * 3 * 16 * 3 * @sizeOf(u16);
    pub const prefix_bytes = 5;
    const fixed_bytes = prefix_bytes + 26;
    const header_bytes = fixed_bytes + transfer_bytes;
    const empty_transfers = makeEmptyTransfers();
    const empty_transfer_groups = makeEmptyTransferGroups();
    pub const prepared_bytes = header_bytes + (volume / 2) * (BakedComponent.header_bytes + 2) + 6 * side * side * 3;
    solid: [volume / 64]u64 = @splat(0),
    connections: [6]u6 = @splat(63),
    faces: u6 = 63,
    blocked_pairs: [6]u6 = @splat(0),
    topology: Topology = .open,
    bounds: ComponentBounds = .{},
    components: u16 = 1,
    boundary_components: u16 = 1,
    first: u12 = 0,
    kind: enum { air, solid, mixed } = .air,
    boundary_open: bool = true,
    component_data: []const u8 = &.{},
    face_words: [6][4]u64 = undefined,
    apertures: [6]Aperture = undefined,
    transfers: []const u8 = &.{},
    prepared_data: []const u8 = &.{},

    pub fn retainPrepared(self: *Section, destination: []u8) void {
        assert(self.kind == .mixed and destination.len == self.prepared_data.len and destination.len >= transfer_prefix);
        if (destination.ptr != self.prepared_data.ptr) @memcpy(destination, self.prepared_data);
        const size = self.transfers.len;
        self.prepared_data = destination;
        self.transfers = destination[0..size];
        self.component_data = destination[size..];
    }

    pub fn writePrepared(self: *const Section, output: []u8) !usize {
        assert(self.kind == .mixed);
        const length = fixed_bytes + self.prepared_data.len;
        assert(length <= prepared_bytes);
        if (output.len < length) return error.BufferTooSmall;
        std.mem.writeInt(u40, output[0..prefix_bytes], self.topology.paths, .little);
        const header = output[prefix_bytes..];
        for (self.connections, header[0..6]) |value, *byte| byte.* = value;
        header[6] = self.faces;
        for (self.blocked_pairs, header[7..13]) |value, *byte| byte.* = value;
        std.mem.writeInt(u32, header[13..17], @bitCast(self.bounds), .little);
        std.mem.writeInt(u16, header[17..19], self.components, .little);
        std.mem.writeInt(u16, header[19..21], self.boundary_components, .little);
        std.mem.writeInt(u16, header[21..23], self.first, .little);
        header[23] = @intFromBool(self.boundary_open);
        std.mem.writeInt(u16, header[24..26], @intCast(self.transfers.len), .little);
        if (output[fixed_bytes..].ptr != self.prepared_data.ptr) @memcpy(output[fixed_bytes..length], self.prepared_data);
        return length;
    }

    pub fn preparedTopology(input: []const u8) !Topology {
        if (input.len < fixed_bytes + transfer_prefix or input.len > prepared_bytes) return error.Corrupt;
        return prefixTopology(input[0..prefix_bytes]);
    }

    pub fn prefixTopology(input: []const u8) !Topology {
        if (input.len != prefix_bytes) return error.Corrupt;
        const paths = std.mem.readInt(u40, input[0..prefix_bytes], .little);
        if (paths >> 36 != 0) return error.Corrupt;
        return .{ .paths = @intCast(paths) };
    }

    fn transpose(input: u64) u64 {
        var result = input;
        inline for (.{ 7, 14, 28 }, .{ 0x00aa00aa00aa00aa, 0x0000cccc0000cccc, 0x00000000f0f0f0f0 }) |shift, mask| {
            const swapped = (result ^ (result >> shift)) & mask;
            result ^= swapped ^ (swapped << shift);
        }
        return result;
    }

    /// Component records borrow input until this section is replaced.
    pub fn readPrepared(self: *Section, solid: *const [64]u64, input: []const u8) !void {
        if (input.len < fixed_bytes + transfer_prefix or input.len > prepared_bytes) return error.Corrupt;
        const topology = try prefixTopology(input[0..prefix_bytes]);
        const header = input[prefix_bytes..];
        if (header[23] > 1) return error.Corrupt;
        const transfer_length = std.mem.readInt(u16, header[24..26], .little);
        if (transfer_length < transfer_prefix or transfer_length > transfer_bytes or transfer_length > input.len - fixed_bytes) return error.Corrupt;
        const records_offset = fixed_bytes + @as(usize, transfer_length);
        var transfer_end: usize = transfer_prefix;
        for (0..6) |group| {
            if (std.mem.readInt(u16, header[26 + 48 + group * 2 ..][0..2], .little) != transfer_end) return error.Corrupt;
            transfer_end += @as(usize, @popCount(std.mem.readInt(u64, header[26 + group * 8 ..][0..8], .little))) * 6;
        }
        if (transfer_end != transfer_length) return error.Corrupt;
        const components = std.mem.readInt(u16, header[17..19], .little);
        const boundary = std.mem.readInt(u16, header[19..21], .little);
        const first = std.mem.readInt(u16, header[21..23], .little);
        if (components == 0 or components > volume / 2 or boundary > components or first >= volume) return error.Corrupt;
        if ((components == 1) != (input.len == records_offset)) return error.Corrupt;
        self.* = .{
            .solid = solid.*,
            .topology = topology,
            .kind = .mixed,
            .components = components,
            .boundary_components = boundary,
            .first = @intCast(first),
            .boundary_open = header[23] != 0,
            .bounds = @bitCast(std.mem.readInt(u32, header[13..17], .little)),
            .transfers = input[fixed_bytes..records_offset],
            .prepared_data = input[fixed_bytes..],
            .component_data = input[records_offset..],
        };
        if (!validBounds(self.bounds) or self.blocked(self.first) or header[6] > 63) return error.Corrupt;
        self.faces = @intCast(header[6]);
        if (self.bounds.faces != self.faces) return error.Corrupt;
        var matrix: u64 = 0;
        var cuts: u64 = 0;
        var permitted_connections: [6]u6 = undefined;
        for (&self.connections, &self.blocked_pairs, 0..) |*connection, *obstructed, face| {
            if (header[face] > 63 or header[7 + face] > 63) return error.Corrupt;
            connection.* = @intCast(header[face]);
            obstructed.* = @intCast(header[7 + face]);
            if (connection.* & ~self.faces != 0 or obstructed.* & ~connection.* != 0) return error.Corrupt;
            if ((connection.* ^ self.faces) & (@as(u6, 1) << @intCast(face)) != 0) return error.Corrupt;
            matrix |= @as(u64, connection.*) << @intCast(face * 8);
            cuts |= @as(u64, obstructed.*) << @intCast(face * 8);
            permitted_connections[face] = connection.* & ~obstructed.*;
        }
        if (transpose(matrix) != matrix or transpose(cuts) != cuts) return error.Corrupt;
        if (topology.paths & ~Topology.fromConnections(permitted_connections).paths != 0) return error.Corrupt;
        for (&self.face_words, 0..) |*words, face| words.* = extractFace(solid, face, true);
        self.cacheApertures();
        if (components == 1) return;
        var cursor: usize = records_offset;
        var covered = solid.*;
        var connected: [6]u6 = @splat(0);
        var boundary_count: usize = 0;
        var previous_seed: ?u12 = null;
        for (0..components) |_| {
            if (input.len - cursor < BakedComponent.header_bytes) return error.Corrupt;
            const length = std.mem.readInt(u16, input[cursor..][0..2], .little);
            if (length < BakedComponent.header_bytes or length > input.len - cursor) return error.Corrupt;
            const record: BakedComponent = .{ .bytes = input[cursor..][0..length] };
            if (record.rawSeed() >= volume or !validBounds(record.bounds())) return error.Corrupt;
            const seed = record.seed();
            if (previous_seed) |previous| if (seed <= previous) return error.Corrupt;
            if (previous_seed == null and seed != first) return error.Corrupt;
            previous_seed = seed;
            const runs = record.runCount();
            if (runs == 0 or runs > volume / 2 or BakedComponent.header_bytes + runs * 2 > length) return error.Corrupt;
            var previous_end: usize = 0;
            for (0..runs) |run_index| {
                const run = record.run(run_index);
                const start: usize = run & 4095;
                const count: usize = (run >> 12) + 1;
                if (start < previous_end or start % 16 + count > 16) return error.Corrupt;
                if (run_index == 0 and start != seed) return error.Corrupt;
                const mask = ((@as(u64, 1) << @intCast(count)) - 1) << @intCast(start % 64);
                if (covered[start / 64] & mask != 0) return error.Corrupt;
                covered[start / 64] |= mask;
                previous_end = start + count;
            }
            var portal_cursor = BakedComponent.header_bytes + runs * 2;
            const faces = record.bounds().faces;
            for (0..6) |face| {
                if (faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
                const words = try BakedComponent.readPortal(record.bytes, &portal_cursor, self, face);
                const actual: @Vector(4, u64) = words;
                const permitted: @Vector(4, u64) = self.face_words[face];
                if (@reduce(.Or, actual) == 0 or @reduce(.Or, actual & ~permitted) != 0) return error.Corrupt;
            }
            if (portal_cursor != length) return error.Corrupt;
            boundary_count += @intFromBool(faces != 0);
            for (0..6) |face| if (faces & (@as(u6, 1) << @intCast(face)) != 0) {
                connected[face] |= faces;
            };
            cursor += length;
        }
        if (cursor != input.len or boundary_count != boundary) return error.Corrupt;
        for (covered) |word| if (word != std.math.maxInt(u64)) return error.Corrupt;
        if (!std.mem.eql(u6, &connected, &self.connections)) return error.Corrupt;
    }

    fn validBounds(bounds: ComponentBounds) bool {
        return bounds.reserved == 0 and bounds.minimum_x <= bounds.maximum_x and bounds.minimum_y <= bounds.maximum_y and bounds.minimum_z <= bounds.maximum_z;
    }

    /// Component records borrow output until this section is replaced.
    pub fn build(self: *Section, occupied_bits: *const [volume / 64]u64, workspace: *Workspace, output: []u8) void {
        assert(output.len >= prepared_bytes);
        self.solid = occupied_bits.*;
        self.first = 0;
        self.component_data = &.{};
        self.transfers = &.{};
        self.prepared_data = &.{};
        self.blocked_pairs = @splat(0);
        self.topology = .open;
        self.bounds = .{};
        self.boundary_open = true;
        var occupied: usize = 0;
        for (occupied_bits) |bits| occupied += @popCount(bits);
        if (occupied == 0) {
            self.kind = .air;
            self.connections = @splat(63);
            self.faces = 63;
            self.components = 1;
            self.boundary_components = 1;
            self.first = 0;
            return;
        }
        self.kind = if (occupied == volume) .solid else .mixed;
        self.topology = .{};
        self.boundary_open = !self.boundaryChanged(&@as([64]u64, @splat(0)));
        self.connections = @splat(0);
        self.faces = 0;
        self.components = 0;
        self.boundary_components = 0;
        if (self.kind == .solid) return;
        for (&self.face_words, 0..) |*words, face| words.* = extractFace(occupied_bits, face, true);
        self.cacheApertures();
        workspace.seen = occupied_bits.*;
        var prepared_length: usize = header_bytes;
        for (0..volume / 64) |word| {
            var unseen = ~workspace.seen[word];
            while (unseen != 0) : (unseen = ~workspace.seen[word]) {
                const connected = workspace.flood(@intCast(word * 64 + @ctz(unseen)));
                if (self.components == 0) self.first = connected.seed;
                self.components += 1;
                self.boundary_components += @intFromBool(connected.faces != 0);
                const record_length = BakedComponent.write(output[prepared_length..], self, connected, workspace);
                prepared_length += record_length;
                self.faces |= connected.faces;
                for (0..6) |face| if (connected.faces & (@as(u6, 1) << @as(u3, @intCast(face))) != 0) {
                    self.connections[face] |= connected.faces;
                };
            }
        }
        assert(prepared_length <= prepared_bytes);
        if (self.components > 1) self.component_data = output[header_bytes..prepared_length];
        const open = Bounds.fromWords(&self.solid, true);
        self.bounds = ComponentBounds.init(open, self.faces, boundsVolume(open) == volume - occupied);
        var endpoints: [6]?Bounds = undefined;
        for (&endpoints, 0..) |*endpoint, face| endpoint.* = portalBounds(face, self.faceWords(face));
        var known: [3]u16 = @splat(0);
        for (0..6) |from| for (from + 1..6) |to| {
            if (self.connections[from] & (@as(u6, 1) << @intCast(to)) == 0) continue;
            const first = endpoints[from].?;
            const second = endpoints[to].?;
            const obstructed = check: {
                for (0..3) |axis| {
                    var entry = first;
                    var exit = second;
                    if (entry.minimum[axis] > exit.minimum[axis]) std.mem.swap(Bounds, &entry, &exit);
                    if (entry.maximum[axis] + 1 >= exit.minimum[axis]) continue;
                    var contained = true;
                    for (0..3) |coordinate| {
                        if (coordinate == axis) continue;
                        contained = contained and open.minimum[coordinate] >= @max(entry.minimum[coordinate], exit.minimum[coordinate]) and
                            open.maximum[coordinate] <= @min(entry.maximum[coordinate], exit.maximum[coordinate]);
                    }
                    // Every slice is inside both endpoint rectangles, so none can prove separation.
                    if (contained) continue;
                    var plane = entry.maximum[axis] + 1;
                    while (plane < exit.minimum[axis]) : (plane += 1) {
                        const offset: usize = @intCast(plane - 1);
                        const bit = @as(u16, 1) << @intCast(offset);
                        if (known[axis] & bit == 0) {
                            var words = extractSlice(&self.solid, axis, @intCast(plane - 1), true);
                            for (&words, extractSlice(&self.solid, axis, @intCast(plane), true)) |*word, other| word.* &= other;
                            workspace.cuts[axis][offset] = portalBounds(axis * 2, words);
                            known[axis] |= bit;
                        }
                        const middle = workspace.cuts[axis][offset] orelse break :check true;
                        if (cutSeparates(entry, exit, axis, plane, middle)) break :check true;
                    }
                }
                break :check false;
            };
            if (obstructed) {
                self.blocked_pairs[from] |= @as(u6, 1) << @intCast(to);
                self.blocked_pairs[to] |= @as(u6, 1) << @intCast(from);
            }
        };
        assert((self.components == 0) == (self.kind == .solid));
        if (self.kind == .mixed) {
            const size = self.bakeTransfers(workspace, output[fixed_bytes..header_bytes]);
            const records_offset = fixed_bytes + size;
            const records_length = self.component_data.len;
            if (records_length != 0 and records_offset != header_bytes) std.mem.copyForwards(u8, output[records_offset..][0..records_length], self.component_data);
            self.component_data = output[records_offset..][0..records_length];
            self.transfers = output[fixed_bytes..records_offset];
            self.prepared_data = output[fixed_bytes .. records_offset + records_length];
        }
    }

    fn cutSeparates(entry: Bounds, exit: Bounds, axis: usize, plane: i32, middle: Bounds) bool {
        assert(entry.maximum[axis] < plane and plane < exit.minimum[axis]);
        // These fractions enclose the crossing parameter for every pair of endpoints.
        const numerator = [2]i32{ plane - entry.maximum[axis], plane - entry.minimum[axis] };
        const denominator = [2]i32{ exit.maximum[axis] - entry.maximum[axis], exit.minimum[axis] - entry.minimum[axis] };
        for (0..3) |coordinate| {
            if (coordinate == axis) continue;
            var below = true;
            var above = true;
            for (numerator, denominator) |n, d| {
                assert(n > 0 and n < d);
                const minimum = entry.minimum[coordinate] * (d - n) + exit.minimum[coordinate] * n;
                const maximum = entry.maximum[coordinate] * (d - n) + exit.maximum[coordinate] * n;
                below = below and maximum <= d * middle.minimum[coordinate];
                above = above and minimum >= d * middle.maximum[coordinate];
            }
            if (below or above) return true;
        }
        return false;
    }

    fn coarseFace(words: [4]u64) u16 {
        var rows: @Vector(4, u64) = words;
        rows |= rows >> @splat(16);
        rows |= rows >> @splat(32);
        rows |= rows >> @splat(1);
        rows |= rows >> @splat(2);
        rows &= @splat(0x1111);
        rows = (rows | (rows >> @splat(3))) & @as(@Vector(4, u64), @splat(0x0303));
        rows = (rows | (rows >> @splat(6))) & @as(@Vector(4, u64), @splat(15));
        return @intCast(rows[0] | (rows[1] << 4) | (rows[2] << 8) | (rows[3] << 12));
    }

    fn coarseWords(selected: u16) [4]u64 {
        const rows = comptime blk: {
            var result: [16]u64 = @splat(0);
            for (&result, 0..) |*word, mask| for (0..4) |bit| {
                if (mask & (@as(usize, 1) << bit) != 0) word.* |= @as(u64, 0x000f000f000f000f) << (bit * 4);
            };
            break :blk result;
        };
        var words: [4]u64 = undefined;
        inline for (0..4) |group| words[group] = rows[@as(u4, @truncate(selected >> (group * 4)))];
        return words;
    }

    fn makeEmptyTransfers() [8][3][16][3]u16 {
        @setEvalBranchQuota(2000000);
        var output: [8][3][16][3]u16 = @splat(@splat(@splat(@splat(0))));
        for (0..8) |octant| for (0..3) |entry| for (0..16) |tile| for (0..3) |exit| for (0..16) |target| {
            var source: [3]usize = undefined;
            source[entry] = if (octant & (@as(usize, 1) << entry) != 0) 0 else 3;
            source[if (entry == 0) 2 else 0] = tile % 4;
            source[if (entry == 1) 2 else 1] = tile / 4;
            var destination: [3]usize = undefined;
            destination[exit] = if (octant & (@as(usize, 1) << exit) != 0) 3 else 0;
            destination[if (exit == 0) 2 else 0] = target % 4;
            destination[if (exit == 1) 2 else 1] = target / 4;
            var possible = true;
            for (0..3) |axis| possible = possible and (if (octant & (@as(usize, 1) << axis) != 0) destination[axis] >= source[axis] else destination[axis] <= source[axis]);
            if (possible) output[octant][entry][tile][exit] |= @as(u16, 1) << target;
        };
        return output;
    }

    fn makeEmptyTransferGroups() [8][3][4][16][3]u16 {
        @setEvalBranchQuota(100000);
        var output: [8][3][4][16][3]u16 = undefined;
        for (&output, 0..) |*directions, octant| for (directions, 0..) |*groups, axis| for (groups, 0..) |*masks, group| for (masks, 0..) |*result, mask| {
            result.* = @splat(0);
            for (0..4) |bit| if (mask & (@as(usize, 1) << bit) != 0) {
                for (result, empty_transfers[octant][axis][group * 4 + bit]) |*value, reached| value.* |= reached;
            };
        };
        return output;
    }

    fn transferMany(self: *const Section, octant: u3, axis: usize, tiles: u16) [3]u16 {
        const row = (@as(usize, octant) * 3 + axis) * 16;
        const mask = std.mem.readInt(u64, self.transfers[(row / 64) * 8 ..][0..8], .little);
        const shift: u6 = @intCast(row % 64);
        const exceptions = tiles & @as(u16, @truncate(mask >> shift));
        const defaults = tiles & ~exceptions;
        var result: [3]u16 = @splat(0);
        inline for (0..4) |group| {
            const selected: u4 = @truncate(defaults >> (group * 4));
            for (&result, empty_transfer_groups[octant][axis][group][selected]) |*value, reached| value.* |= reached;
        }
        var pending = exceptions;
        while (pending != 0) : (pending &= pending - 1) {
            for (&result, self.transfer(octant, axis, @intCast(@ctz(pending)))) |*value, reached| value.* |= reached;
        }
        return result;
    }

    fn sweepLabels(comptime positive: bool, initial: @Vector(16, u64), occupied: u16) @Vector(16, u64) {
        const occupied_lanes: @Vector(16, bool) = @bitCast(occupied);
        const zero: @Vector(16, u64) = @splat(0);
        var permitted = @select(u64, occupied_lanes, zero, @as(@Vector(16, u64), @splat(std.math.maxInt(u64))));
        var reached = initial & permitted;
        inline for ([_]usize{ 1, 2, 4, 8 }) |distance| {
            const offsets = comptime indices: {
                var result: [16]i32 = undefined;
                for (&result, 0..) |*value, index| value.* = if (positive) (if (index >= distance) @intCast(index - distance) else -1) else (if (index + distance < 16) @intCast(index + distance) else -1);
                break :indices result;
            };
            reached |= @shuffle(u64, reached, zero, offsets) & permitted;
            permitted &= @shuffle(u64, permitted, zero, offsets);
        }
        return reached;
    }

    fn labelSeeds(comptime base: usize) [4]@Vector(16, u64) {
        var result: [4]@Vector(16, u64) = undefined;
        for (&result, 0..) |*row, group| for (0..16) |x| {
            row.*[x] = @as(u64, 1) << @intCast(base + group * 4 + x / 4);
        };
        return result;
    }

    fn directionalTransfers(self: *const Section, octant: usize, workspace: *Workspace) [3][16][3]u16 {
        const from_y = comptime labelSeeds(16);
        const from_z = comptime labelSeeds(32);
        const zero: @Vector(16, u64) = @splat(0);
        var boundary: [3][16]u64 = @splat(@splat(0));
        const positive_x = octant & 1 != 0;
        const positive_y = octant & 2 != 0;
        const positive_z = octant & 4 != 0;
        const low = [2]usize{ self.bounds.minimum_y, self.bounds.minimum_z };
        const high = [2]usize{ @as(usize, self.bounds.maximum_y) + 1, @as(usize, self.bounds.maximum_z) + 1 };
        for (0..high[0] - low[0]) |iy| {
            const y = if (positive_y) low[0] + iy else high[0] - 1 - iy;
            for (0..high[1] - low[1]) |iz| {
                const z = if (positive_z) low[1] + iz else high[1] - 1 - iz;
                const row = workspace.labels[z * 16 ..][0..16];
                const occupied: u16 = @truncate(self.solid[y * 4 + z / 4] >> @intCast(z % 4 * 16));
                if (occupied == std.math.maxInt(u16)) {
                    @memset(row, 0);
                    continue;
                }
                var labels: @Vector(16, u64) = if (iy != 0) row.* else zero;
                if (iz != 0) labels |= @as(@Vector(16, u64), workspace.labels[(if (positive_z) z - 1 else z + 1) * 16 ..][0..16].*);
                if (positive_x) labels[0] |= @as(u64, 1) << @intCast(y / 4 * 4 + z / 4) else labels[15] |= @as(u64, 1) << @intCast(y / 4 * 4 + z / 4);
                if (y == (if (positive_y) @as(usize, 0) else 15)) labels |= from_y[z / 4];
                if (z == (if (positive_z) @as(usize, 0) else 15)) labels |= from_z[y / 4];
                const reached = if (positive_x) sweepLabels(true, labels, occupied) else sweepLabels(false, labels, occupied);
                row.* = reached;
                boundary[0][y / 4 * 4 + z / 4] |= if (positive_x) reached[15] else reached[0];
                const exit_y = y == (if (positive_y) @as(usize, 15) else 0);
                const exit_z = z == (if (positive_z) @as(usize, 15) else 0);
                if (!exit_y and !exit_z) continue;
                inline for (0..4) |group| {
                    const collapsed = @reduce(.Or, @shuffle(u64, reached, zero, @as(@Vector(4, i32), .{ group * 4, group * 4 + 1, group * 4 + 2, group * 4 + 3 })));
                    if (exit_y) boundary[1][z / 4 * 4 + group] |= collapsed;
                    if (exit_z) boundary[2][y / 4 * 4 + group] |= collapsed;
                }
            }
        }
        var output: [3][16][3]u16 = undefined;
        for (0..3) |exit| {
            const lanes: @Vector(16, u64) = boundary[exit];
            for (0..3) |axis| for (0..16) |tile| {
                const bit: @Vector(16, u64) = @splat(@as(u64, 1) << @intCast(axis * 16 + tile));
                output[axis][tile][exit] = @bitCast(lanes & bit != zero);
            };
        }
        return output;
    }

    // A bit identifies one incoming face tile. All 48 starts share one monotone sweep.
    fn bakeTransfers(self: *Section, workspace: *Workspace, output: []u8) usize {
        assert(output.len == transfer_bytes);
        @memset(output[0..transfer_prefix], 0);
        var masks: [6]u64 = @splat(0);
        var cursor: usize = transfer_prefix;
        for (0..8) |octant| {
            const computed = if (!self.boundary_open and self.faces != 0) self.directionalTransfers(octant, workspace) else undefined;
            if (octant < 4) {
                for (0..3) |entry| for (0..3) |exit| {
                    const from = entry * 2 + 1 - ((octant >> @intCast(entry)) & 1);
                    const to = exit * 2 + ((octant >> @intCast(exit)) & 1);
                    if (self.connections[from] & ~self.blocked_pairs[from] & (@as(u6, 1) << @intCast(to)) == 0) continue;
                    var reached: u16 = 0;
                    if (self.boundary_open) {
                        reached = 1;
                    } else {
                        for (computed[entry]) |tiles| reached |= tiles[exit];
                    }
                    if (reached != 0) self.topology.paths |= @as(u36, 1) << @intCast(Topology.index(octant, entry, exit));
                };
            }
            var face_masks: [3]u16 = undefined;
            for (&face_masks, 0..) |*mask, axis| mask.* = coarseFace(self.faceWords(axis * 2 + ((octant >> @intCast(axis)) & 1)));
            for (0..3) |incoming_axis| for (0..16) |tile| {
                const row = (octant * 3 + incoming_axis) * 16 + tile;
                if (row % 64 == 0) std.mem.writeInt(u16, output[48 + (row / 64) * 2 ..][0..2], @intCast(cursor), .little);
                if (self.boundary_open or self.faces == 0) continue;
                const face = incoming_axis * 2 + 1 - ((octant >> @intCast(incoming_axis)) & 1);
                const words = self.faceWords(face);
                var selected = coarseWords(@as(u16, 1) << @intCast(tile));
                for (&selected, words) |*word, open| word.* &= open;
                if (@reduce(.Or, @as(@Vector(4, u64), selected)) == 0) continue;
                var actual = computed[incoming_axis][tile];
                if (self.bounds.rectangular and std.mem.eql(u64, &selected, &words)) actual = face_masks;
                var different = false;
                for (actual, face_masks, 0..) |value, open, axis| different = different or value != empty_transfers[octant][incoming_axis][tile][axis] & open;
                if (!different) continue;
                masks[row / 64] |= @as(u64, 1) << @intCast(row % 64);
                for (actual) |mask| {
                    std.mem.writeInt(u16, output[cursor..][0..2], mask, .little);
                    cursor += 2;
                }
            };
        }
        for (masks, 0..) |mask, index| std.mem.writeInt(u64, output[index * 8 ..][0..8], mask, .little);
        return cursor;
    }

    fn transfer(self: *const Section, octant: u3, axis: usize, tile: u4) [3]u16 {
        const row = (@as(usize, octant) * 3 + axis) * 16 + tile;
        const mask = std.mem.readInt(u64, self.transfers[(row / 64) * 8 ..][0..8], .little);
        const bit = @as(u64, 1) << @intCast(row % 64);
        if (mask & bit == 0) return empty_transfers[octant][axis][tile];
        const base = std.mem.readInt(u16, self.transfers[48 + (row / 64) * 2 ..][0..2], .little);
        const offset = base + @as(usize, @popCount(mask & (bit - 1))) * 6;
        var result: [3]u16 = undefined;
        for (&result, 0..) |*value, index| value.* = std.mem.readInt(u16, self.transfers[offset + index * 2 ..][0..2], .little);
        return result;
    }

    fn restrictBaked(self: *const Section, portals: *[6][4]u64, incoming: u6, entries: *const [3]Entry, octant: u3, camera: ?Bounds, bounds: ComponentBounds, workspace: *Workspace) void {
        if (self.boundary_open) return;
        if (camera != null) return self.restrictPortals(portals, incoming, entries, octant, camera, bounds, workspace);
        var reached: [3]u16 = @splat(0);
        for (0..3) |axis| {
            const face = axis * 2 + 1 - @as(usize, (octant >> @intCast(axis)) & 1);
            if (incoming & (@as(u6, 1) << @intCast(face)) == 0) continue;
            var words = portals[face];
            entries[axis].restrict(&words);
            for (&reached, self.transferMany(octant, axis, coarseFace(words))) |*mask, value| mask.* |= value;
        }
        for (0..3) |axis| {
            const face = axis * 2 + @as(usize, (octant >> @intCast(axis)) & 1);
            for (&portals[face], coarseWords(reached[axis])) |*word, permitted| word.* &= permitted;
        }
    }

    fn restrictPortals(self: *const Section, portals: *[6][4]u64, incoming: u6, entries: *const [3]Entry, octant: u3, camera: ?Bounds, bounds: ComponentBounds, workspace: *Workspace) void {
        // Every straight ray is monotone in each coordinate. Reachability may overdisclose but cannot reject such a ray.
        // Open boundaries use the coarse model, so their interior edits cannot change visibility.
        if (self.boundary_open) return;
        if (camera) |region| {
            for (0..3) |axis| assert(region.minimum[axis] >= 0 and region.minimum[axis] < region.maximum[axis] and region.maximum[axis] <= side);
            const extent = bounds.geometry();
            var contained = true;
            for (0..3) |axis| contained = contained and region.minimum[axis] <= extent.minimum[axis] and region.maximum[axis] >= extent.maximum[axis];
            if (contained) return;
        }
        var starts: [3][4]u64 = @splat(@splat(0));
        for (&starts, 0..) |*words, axis| {
            const face = axis * 2 + (1 - @as(usize, (octant >> @intCast(axis)) & 1));
            if (incoming & (@as(u6, 1) << @intCast(face)) == 0) continue;
            words.* = portals[face];
            entries[axis].restrict(words);
            if (bounds.rectangular and @reduce(.Or, @as(@Vector(4, u64), words.*)) != 0 and std.mem.eql(u64, words, &portals[face])) return;
        }
        const positive_x = octant & 1 != 0;
        const positive_y = octant & 2 != 0;
        const positive_z = octant & 4 != 0;
        var camera_words: [4]u64 = @splat(0);
        var camera_minimum: usize = 0;
        var camera_maximum: usize = 0;
        if (camera) |region| {
            camera_words = @splat(std.math.maxInt(u64));
            Aperture.init(2, region).restrict(&camera_words);
            camera_minimum = @intCast(region.minimum[1]);
            camera_maximum = @intCast(region.maximum[1]);
        }
        @memset(&workspace.reached, 0);
        const minimum_y: usize = bounds.minimum_y;
        const maximum_y: usize = @as(usize, bounds.maximum_y) + 1;
        const minimum_z: usize = bounds.minimum_z / 4;
        const maximum_z: usize = @as(usize, bounds.maximum_z) / 4 + 1;
        for (0..maximum_y - minimum_y) |iy| {
            const y = if (positive_y) minimum_y + iy else maximum_y - 1 - iy;
            for (0..maximum_z - minimum_z) |iz| {
                const z = if (positive_z) minimum_z + iz else maximum_z - 1 - iz;
                const index = y * 4 + z;
                const open = ~self.solid[index];
                if (open == 0) {
                    workspace.reached[index] = 0;
                    continue;
                }
                const nibble = (starts[0][y / 4] >> @intCast(y % 4 * 16 + z * 4)) & 15;
                var bits = (nibble | (nibble << 30)) & 0x0000000300000003;
                bits = (bits | (bits << 15)) & 0x0001000100010001;
                if (!positive_x) bits <<= 15;
                if (y >= camera_minimum and y < camera_maximum) bits |= camera_words[z];
                if (iy == 0) bits |= starts[1][z];
                if (iz == 0) {
                    const row = (starts[2][y / 4] >> @intCast(y % 4 * 16)) & 0xffff;
                    bits |= if (positive_z) row else row << 48;
                }
                if (iy != 0) bits |= workspace.reached[(if (positive_y) y - 1 else y + 1) * 4 + z];
                if (iz != 0) {
                    const previous = workspace.reached[y * 4 + (if (positive_z) z - 1 else z + 1)];
                    bits |= if (positive_z) previous >> 48 else previous << 48;
                }
                bits &= open;
                if (bits == 0 or bits == open) {
                    workspace.reached[index] = bits;
                    continue;
                }
                if (open == std.math.maxInt(u64)) {
                    if (positive_x) {
                        bits |= (bits << 1) & 0xfffefffefffefffe;
                        bits |= (bits << 2) & 0xfffcfffcfffcfffc;
                        bits |= (bits << 4) & 0xfff0fff0fff0fff0;
                        bits |= (bits << 8) & 0xff00ff00ff00ff00;
                    } else {
                        bits |= (bits >> 1) & 0x7fff7fff7fff7fff;
                        bits |= (bits >> 2) & 0x3fff3fff3fff3fff;
                        bits |= (bits >> 4) & 0x0fff0fff0fff0fff;
                        bits |= (bits >> 8) & 0x00ff00ff00ff00ff;
                    }
                    if (positive_z) {
                        bits |= bits << 16;
                        bits |= bits << 32;
                    } else {
                        bits |= bits >> 16;
                        bits |= bits >> 32;
                    }
                    workspace.reached[index] = bits;
                    continue;
                }
                bits = sweepRows(bits, open, positive_x);
                for (0..3) |_| {
                    const expanded = bits | ((if (positive_z) bits << 16 else bits >> 16) & open);
                    if (expanded == bits) break;
                    bits = sweepRows(expanded, open, positive_x);
                }
                workspace.reached[index] = bits;
            }
        }
        for (0..3) |axis| {
            const face = axis * 2 + @as(usize, (octant >> @intCast(axis)) & 1);
            for (&portals[face], extractFace(&workspace.reached, face, false)) |*word, reached| word.* &= reached;
        }
    }

    pub fn component(self: *const Section, index: u12, workspace: *Workspace) ?Component {
        if (self.blocked(index)) return null;
        if (self.kind == .air) return .{ .seed = 0, .faces = 63 };
        if (self.components == 1) return .{ .seed = self.first, .faces = self.faces };
        var components = self.componentIterator();
        while (components.next()) |entry| {
            if (!entry.contains(index)) continue;
            entry.membership(&workspace.component_bits);
            workspace.count = 0;
            for (&workspace.seen, self.solid, workspace.component_bits) |*seen, occupied, selected| {
                seen.* = occupied | selected;
                workspace.count += @popCount(selected);
            }
            return .{ .seed = entry.seed(), .faces = entry.bounds().faces };
        }
        unreachable;
    }

    pub fn expandComponents(self: *const Section, incoming: *const [64]u64, permitted: *const [64]u64, reached: *[64]u64, workspace: *Workspace) u6 {
        const added: @Vector(64, u64) = incoming.* & ~@as(@Vector(64, u64), self.solid) & ~@as(@Vector(64, u64), reached.*) & @as(@Vector(64, u64), permitted.*);
        if (@reduce(.Or, added) == 0) return 0;
        if (self.components == 1) {
            reached.* = @as(@Vector(64, u64), reached.*) | (~@as(@Vector(64, u64), self.solid) & @as(@Vector(64, u64), permitted.*));
            return self.faces;
        }
        var faces: u6 = 0;
        var components = self.componentIterator();
        while (components.next()) |entry| {
            entry.membership(&workspace.component_bits);
            const bits: @Vector(64, u64) = workspace.component_bits;
            if (@reduce(.Or, bits & added) == 0) continue;
            reached.* = @as(@Vector(64, u64), reached.*) | (bits & @as(@Vector(64, u64), permitted.*));
            faces |= entry.bounds().faces;
        }
        return faces;
    }

    fn componentIterator(self: *const Section) ComponentIterator {
        assert(self.components > 1 and self.component_data.len != 0);
        return .{ .data = self.component_data };
    }

    pub fn blocked(self: *const Section, index: u12) bool {
        return self.solid[index / 64] & (@as(u64, 1) << @as(u6, @intCast(index % 64))) != 0;
    }

    pub fn boundaryChanged(self: *const Section, solid: *const [64]u64) bool {
        for (self.solid, solid, 0..) |previous, current, word| {
            var mask: u64 = if (word < 4 or word >= 60) std.math.maxInt(u64) else 0x8001800180018001;
            if (word % 4 == 0) mask |= 0xffff;
            if (word % 4 == 3) mask |= 0xffff000000000000;
            if ((previous ^ current) & mask != 0) return true;
        }
        return false;
    }

    fn faceWords(self: *const Section, face: usize) [4]u64 {
        assert(face < 6);
        if (self.kind == .solid) return @splat(0);
        if (self.kind == .air) return @splat(std.math.maxInt(u64));
        return self.face_words[face];
    }

    fn portalBounds(face: usize, words: [4]u64) ?Bounds {
        const axis = face / 2;
        const u: usize = if (axis == 0) 2 else 0;
        const v: usize = if (axis == 1) 2 else 1;
        var columns: u16 = 0;
        var minimum: i32 = 16;
        var maximum: i32 = 0;
        for (words, 0..) |word, group| {
            if (word == 0) continue;
            columns |= @truncate(word | (word >> 16) | (word >> 32) | (word >> 48));
            minimum = @min(minimum, @as(i32, @intCast(group * 4 + @ctz(word) / 16)));
            maximum = @as(i32, @intCast(group * 4 + (63 - @clz(word)) / 16 + 1));
        }
        if (columns == 0) return null;
        var bounds: Bounds = .{ .minimum = @splat(0), .maximum = @splat(0) };
        bounds.minimum[axis] = if (face % 2 == 0) 0 else 16;
        bounds.maximum[axis] = bounds.minimum[axis];
        bounds.minimum[u] = @intCast(@ctz(columns));
        bounds.maximum[u] = @intCast(16 - @clz(columns));
        bounds.minimum[v] = minimum;
        bounds.maximum[v] = maximum;
        return bounds;
    }

    fn cacheApertures(self: *Section) void {
        for (self.face_words, 0..) |words, face| {
            self.apertures[face] = if (portalBounds(face, words)) |bounds| .init(face, bounds) else @bitCast(@as(u16, 0));
        }
    }

    fn openingBounds(self: *const Section, face: usize, words: [4]u64) ?Bounds {
        if (self.kind == .mixed and std.mem.eql(u64, &words, &self.face_words[face])) {
            if (@reduce(.Or, @as(@Vector(4, u64), words)) == 0) return null;
            return self.apertures[face].box(face);
        }
        return portalBounds(face, words);
    }

    pub fn portal(self: *const Section, face: usize, adjacent: ?*const Section) ?Bounds {
        var words = self.faceWords(face);
        if (adjacent) |other| for (&words, other.faceWords(face ^ 1)) |*word, opposite| {
            word.* &= opposite;
        };
        return portalBounds(face, words);
    }
};

test "compact directional prefixes round trip paths and reject incorrect lengths and high bits" {
    var random = std.Random.DefaultPrng.init(0x319d75);
    for (0..512) |trial| {
        const expected: Topology = .{ .paths = if (trial == 0) 0 else if (trial == 1) Topology.open.paths else random.random().int(u36) };
        var prefix: [Section.prefix_bytes]u8 = undefined;
        std.mem.writeInt(u40, &prefix, expected.paths, .little);
        var high = prefix;
        high[4] |= @as(u8, 1) << @intCast(4 + trial % 4);
        try std.testing.expectError(error.Corrupt, Section.prefixTopology(&high));
        try std.testing.expectEqualDeep(expected, try Section.prefixTopology(&prefix));
        for (0..Section.prefix_bytes) |length| try std.testing.expectError(error.Corrupt, Section.prefixTopology(prefix[0..length]));
    }
    try std.testing.expectError(error.Corrupt, Section.prefixTopology(&@as([Section.prefix_bytes + 1]u8, @splat(0))));
}

fn sweepRows(bits: u64, open: u64, positive: bool) u64 {
    assert(bits & ~open == 0);
    if (positive) {
        // The cleared high bit absorbs each row's carry before it can reach the next row.
        const lanes = open & 0x7fff7fff7fff7fff;
        const filled = lanes & (bits | ((lanes +% (bits & 0x7fff7fff7fff7fff)) ^ lanes));
        return filled | (open & (bits | (filled << 1)) & 0x8000800080008000);
    }
    var result = bits;
    var pass = open & 0x7fff7fff7fff7fff;
    result |= (result >> 1) & pass;
    pass &= pass >> 1;
    result |= (result >> 2) & pass;
    pass &= pass >> 2;
    result |= (result >> 4) & pass;
    pass &= pass >> 4;
    result |= (result >> 8) & pass;
    return result;
}

test "prepared topology preserves connectivity partitions and occlusion proofs" {
    var random = std.Random.DefaultPrng.init(0x9aa74c);
    for (0..12) |shape| {
        var solid: [64]u64 = @splat(0);
        for (0..volume) |index| {
            const x = index % 16;
            const y = index / 256;
            const z = index / 16 % 16;
            const occupied = switch (shape) {
                0 => x == 8,
                1 => y == 8,
                2 => z == 8,
                3 => x == 0 or x == 15 or y == 0 or y == 15 or z == 0 or z == 15,
                4 => x % 2 == 0 and y % 2 == 0 and z % 2 == 0,
                5 => (x + y + z) % 2 == 0,
                else => random.random().boolean(),
            };
            if (occupied) solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        var original: Section = .{};
        var workspace: Workspace = undefined;
        var prepared: [Section.prepared_bytes]u8 = undefined;
        original.build(&solid, &workspace, &prepared);
        var encoded: [Section.prepared_bytes]u8 = undefined;
        const length = try original.writePrepared(&encoded);
        const projected = try Section.preparedTopology(encoded[0..length]);
        try std.testing.expectEqualDeep(original.topology, projected);
        var restored: Section = .{};
        try restored.readPrepared(&solid, encoded[0..length]);
        try std.testing.expectEqualSlices(u64, &original.solid, &restored.solid);
        try std.testing.expectEqualSlices(u6, &original.connections, &restored.connections);
        try std.testing.expectEqualSlices(u6, &original.blocked_pairs, &restored.blocked_pairs);
        try std.testing.expectEqualDeep(original.topology, restored.topology);
        try std.testing.expectEqual(original.faces, restored.faces);
        try std.testing.expectEqual(original.components, restored.components);
        try std.testing.expectEqual(original.boundary_components, restored.boundary_components);
        try std.testing.expectEqual(original.first, restored.first);
        try std.testing.expectEqual(original.bounds, restored.bounds);
        try std.testing.expectEqual(original.boundary_open, restored.boundary_open);
        try std.testing.expectEqualSlices(u8, original.component_data, restored.component_data);
        try std.testing.expectEqualSlices(u8, original.transfers, restored.transfers);
        try std.testing.expectEqualDeep(original.face_words, restored.face_words);
        if (restored.components > 1) {
            var reference: Workspace = undefined;
            reference.seen = solid;
            var components = restored.componentIterator();
            while (components.next()) |record| {
                const expected = reference.flood(record.seed());
                const actual = restored.component(record.seed(), &workspace).?;
                try std.testing.expectEqual(expected, actual);
                try std.testing.expectEqual(reference.count, workspace.count);
                try std.testing.expectEqualSlices(u64, &reference.component_bits, &workspace.component_bits);
                try std.testing.expectEqualDeep(reference.geometry(), record.geometry(&restored));
            }
        }
        var canonical: [Section.prepared_bytes]u8 = undefined;
        try std.testing.expectEqual(length, try restored.writePrepared(&canonical));
        try std.testing.expectEqualSlices(u8, encoded[0..length], canonical[0..length]);
        var truncated: usize = 0;
        while (truncated < length) : (truncated += @max(1, length / 64)) try std.testing.expectError(error.Corrupt, restored.readPrepared(&solid, encoded[0..truncated]));
        try std.testing.expectError(error.Corrupt, restored.readPrepared(&solid, encoded[0 .. length - 1]));
        encoded[Section.prefix_bytes + 23] |= 0x80;
        try std.testing.expectError(error.Corrupt, restored.readPrepared(&solid, encoded[0..length]));
    }
}

const Aperture = packed struct(u16) {
    minimum_u: u4,
    maximum_u: u4,
    minimum_v: u4,
    maximum_v: u4,

    fn init(face: usize, bounds: Bounds) Aperture {
        assert(face < 6);
        const u: usize = if (face / 2 == 0) 2 else 0;
        const v: usize = if (face / 2 == 1) 2 else 1;
        assert(bounds.minimum[u] >= 0 and bounds.minimum[u] < bounds.maximum[u] and bounds.maximum[u] <= 16);
        assert(bounds.minimum[v] >= 0 and bounds.minimum[v] < bounds.maximum[v] and bounds.maximum[v] <= 16);
        return .{ .minimum_u = @intCast(bounds.minimum[u]), .maximum_u = @intCast(bounds.maximum[u] - 1), .minimum_v = @intCast(bounds.minimum[v]), .maximum_v = @intCast(bounds.maximum[v] - 1) };
    }

    fn restrict(self: Aperture, words: *[4]u64) void {
        const columns = (@as(u16, 0xffff) << self.minimum_u) & (@as(u16, 0xffff) >> (15 - self.maximum_u));
        const rows: @Vector(16, u16) = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const live = (rows >= @as(@Vector(16, u16), @splat(self.minimum_v))) & (rows <= @as(@Vector(16, u16), @splat(self.maximum_v)));
        const mask = @select(u16, live, @as(@Vector(16, u16), @splat(columns)), @as(@Vector(16, u16), @splat(0)));
        words.* = @bitCast(@as(@Vector(16, u16), @bitCast(words.*)) & mask);
    }

    fn box(self: Aperture, face: usize) Bounds {
        assert(face < 6);
        const axis = face / 2;
        const u: usize = if (axis == 0) 2 else 0;
        const v: usize = if (axis == 1) 2 else 1;
        var result: Bounds = .{ .minimum = @splat(0), .maximum = @splat(0) };
        result.minimum[axis] = if (face % 2 == 0) 0 else 16;
        result.maximum[axis] = result.minimum[axis];
        result.minimum[u] = self.minimum_u;
        result.maximum[u] = @as(i32, self.maximum_u) + 1;
        result.minimum[v] = self.minimum_v;
        result.maximum[v] = @as(i32, self.maximum_v) + 1;
        return result;
    }
};

const BakedComponent = struct {
    const header_bytes = 10;
    bytes: []const u8,

    fn rawSeed(self: BakedComponent) u16 {
        return std.mem.readInt(u16, self.bytes[2..4], .little);
    }

    fn seed(self: BakedComponent) u12 {
        return @intCast(self.rawSeed());
    }

    fn bounds(self: BakedComponent) ComponentBounds {
        return @bitCast(std.mem.readInt(u32, self.bytes[4..8], .little));
    }

    fn runCount(self: BakedComponent) usize {
        return std.mem.readInt(u16, self.bytes[8..10], .little);
    }

    fn run(self: BakedComponent, index: usize) u16 {
        assert(index < self.runCount());
        return std.mem.readInt(u16, self.bytes[header_bytes + index * 2 ..][0..2], .little);
    }

    fn contains(self: BakedComponent, index: u12) bool {
        var low: usize = 0;
        var high = self.runCount();
        while (low < high) {
            const middle = low + (high - low) / 2;
            const value = self.run(middle);
            const start = value & 4095;
            const length: usize = (value >> 12) + 1;
            if (index < start) high = middle else if (index - start >= length) low = middle + 1 else return true;
        }
        return false;
    }

    fn membership(self: BakedComponent, output: *[64]u64) void {
        @memset(output, 0);
        for (0..self.runCount()) |index| {
            const value = self.run(index);
            const start = value & 4095;
            const length: usize = (value >> 12) + 1;
            output[start / 64] |= ((@as(u64, 1) << @intCast(length)) - 1) << @intCast(start % 64);
        }
    }

    fn geometry(self: BakedComponent, section: *const Section) ComponentGeometry {
        const extent = self.bounds();
        var result: ComponentGeometry = .{ .bounds = extent.geometry(), .rectangular = extent.rectangular, .portals = @splat(@splat(0)) };
        var cursor = header_bytes + self.runCount() * 2;
        for (0..6) |face| {
            if (extent.faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
            result.portals[face] = readPortal(self.bytes, &cursor, section, face) catch unreachable;
        }
        assert(cursor == self.bytes.len);
        return result;
    }

    fn readPortal(input: []const u8, cursor: *usize, section: *const Section, face: usize) ![4]u64 {
        if (cursor.* >= input.len) return error.Corrupt;
        const tag = input[cursor.*];
        cursor.* += 1;
        if (tag == 0) return section.faceWords(face);
        if (tag == 1) {
            if (input.len - cursor.* < 32) return error.Corrupt;
            var words: [4]u64 = undefined;
            for (&words, 0..) |*word, index| word.* = std.mem.readInt(u64, input[cursor.* + index * 8 ..][0..8], .little);
            cursor.* += 32;
            return words;
        }
        if (tag == 2) {
            if (cursor.* >= input.len) return error.Corrupt;
            const count: usize = input[cursor.*];
            cursor.* += 1;
            if (count == 0 or count >= 31 or count > input.len - cursor.*) return error.Corrupt;
            var words: [4]u64 = @splat(0);
            var previous: ?u8 = null;
            for (input[cursor.*..][0..count]) |index| {
                if (previous) |last| if (index <= last) return error.Corrupt;
                previous = index;
                words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            }
            cursor.* += count;
            return words;
        }
        if (tag == 3 or tag == 4) {
            if (input.len - cursor.* < 2) return error.Corrupt;
            const aperture: Aperture = @bitCast(std.mem.readInt(u16, input[cursor.*..][0..2], .little));
            cursor.* += 2;
            if (aperture.minimum_u > aperture.maximum_u or aperture.minimum_v > aperture.maximum_v) return error.Corrupt;
            var words = section.faceWords(face);
            aperture.restrict(&words);
            if (tag == 4) for (&words, section.faceWords(face)) |*word, open| {
                word.* = open & ~word.*;
            };
            return words;
        }
        return error.Corrupt;
    }

    fn write(output: []u8, section: *const Section, component: Component, workspace: *const Workspace) usize {
        assert(output.len >= header_bytes);
        var cursor: usize = header_bytes;
        var runs: usize = 0;
        for (workspace.component_bits, 0..) |word, offset| {
            if (word == 0) continue;
            for (0..4) |row| {
                var bits: u16 = @truncate(word >> @intCast(row * 16));
                while (bits != 0) {
                    const first: usize = @ctz(bits);
                    const count = @min(@as(usize, @ctz(~(bits >> @intCast(first)))), 16 - first);
                    assert(count > 0 and count <= 16);
                    const start = offset * 64 + row * 16 + first;
                    const value: u16 = @intCast(start | ((count - 1) << 12));
                    std.mem.writeInt(u16, output[cursor..][0..2], value, .little);
                    cursor += 2;
                    runs += 1;
                    bits &= ~@as(u16, @intCast(((@as(u32, 1) << @intCast(count)) - 1) << @intCast(first)));
                }
            }
        }
        const data = workspace.geometry();
        const extent = ComponentBounds.init(data.bounds, component.faces, data.rectangular);
        for (data.portals, 0..) |words, face| {
            if (component.faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
            const full = section.faceWords(face);
            if (std.mem.eql(u64, &words, &full)) {
                output[cursor] = 0;
                cursor += 1;
                continue;
            }
            const aperture = Aperture.init(face, Section.portalBounds(face, words).?);
            var selected = full;
            aperture.restrict(&selected);
            if (std.mem.eql(u64, &words, &selected)) {
                output[cursor] = 3;
                std.mem.writeInt(u16, output[cursor + 1 ..][0..2], @bitCast(aperture), .little);
                cursor += 3;
                continue;
            }
            var excluded = full;
            for (&excluded, words) |*word, value| word.* &= ~value;
            if (Section.portalBounds(face, excluded)) |bounds_value| {
                const inverted = Aperture.init(face, bounds_value);
                selected = full;
                inverted.restrict(&selected);
                if (std.mem.eql(u64, &excluded, &selected)) {
                    output[cursor] = 4;
                    std.mem.writeInt(u16, output[cursor + 1 ..][0..2], @bitCast(inverted), .little);
                    cursor += 3;
                    continue;
                }
            }
            var count: usize = 0;
            for (words) |word| count += @popCount(word);
            if (count < 31) {
                output[cursor] = 2;
                output[cursor + 1] = @intCast(count);
                cursor += 2;
                for (words, 0..) |word, group| {
                    var bits = word;
                    while (bits != 0) : (bits &= bits - 1) {
                        output[cursor] = @intCast(group * 64 + @ctz(bits));
                        cursor += 1;
                    }
                }
            } else {
                output[cursor] = 1;
                cursor += 1;
                for (words, 0..) |word, index| std.mem.writeInt(u64, output[cursor + index * 8 ..][0..8], word, .little);
                cursor += 32;
            }
        }
        assert(cursor <= std.math.maxInt(u16) and runs <= volume / 2);
        std.mem.writeInt(u16, output[0..2], @intCast(cursor), .little);
        std.mem.writeInt(u16, output[2..4], component.seed, .little);
        std.mem.writeInt(u32, output[4..8], @bitCast(extent), .little);
        std.mem.writeInt(u16, output[8..10], @intCast(runs), .little);
        return cursor;
    }
};

const ComponentIterator = struct {
    data: []const u8,

    fn next(self: *ComponentIterator) ?BakedComponent {
        if (self.data.len == 0) return null;
        assert(self.data.len >= BakedComponent.header_bytes);
        const length = std.mem.readInt(u16, self.data[0..2], .little);
        assert(length >= BakedComponent.header_bytes and length <= self.data.len);
        const result: BakedComponent = .{ .bytes = self.data[0..length] };
        self.data = self.data[length..];
        return result;
    }
};

const Entry = struct {
    words: [4]u64,

    fn init(face: usize, bounds: Bounds, words: [4]u64) Entry {
        var result: Entry = .{ .words = words };
        Aperture.init(face, bounds).restrict(&result.words);
        assert(@reduce(.Or, @as(@Vector(4, u64), result.words)) != 0);
        return result;
    }

    fn merge(self: *Entry, other: Entry) void {
        for (&self.words, other.words) |*word, additional| word.* |= additional;
    }

    fn restrict(self: Entry, words: *[4]u64) void {
        for (words, self.words) |*word, permitted| word.* &= permitted;
    }
};

test "incoming portal entries preserve exact openings within and across tiles" {
    for (0..6) |face| for ([_]usize{ 34, 238 }) |other| {
        var first: [4]u64 = @splat(0);
        first[0] = @as(u64, 1) << 17;
        var last: [4]u64 = @splat(0);
        last[other / 64] = @as(u64, 1) << @intCast(other % 64);
        const first_bounds = Section.portalBounds(face, first).?;
        const last_bounds = Section.portalBounds(face, last).?;
        var entry = Entry.init(face, first_bounds, first);
        entry.merge(Entry.init(face, last_bounds, last));
        var selected: [4]u64 = @splat(std.math.maxInt(u64));
        entry.restrict(&selected);
        for (first, last, selected) |a, b, actual| try std.testing.expectEqual(a | b, actual);
    };
}

test "aperture vectors preserve every rectangular row and column mask" {
    var random = std.Random.DefaultPrng.init(0xc672c945);
    for (0..16) |minimum_u| for (minimum_u..16) |maximum_u| for (0..16) |minimum_v| for (minimum_v..16) |maximum_v| {
        var words: [4]u64 = undefined;
        for (&words) |*word| word.* = random.random().int(u64);
        var expected = words;
        for (0..256) |bit| {
            if (bit % 16 < minimum_u or bit % 16 > maximum_u or bit / 16 < minimum_v or bit / 16 > maximum_v) expected[bit / 64] &= ~(@as(u64, 1) << @intCast(bit % 64));
        }
        const aperture: Aperture = .{ .minimum_u = @intCast(minimum_u), .maximum_u = @intCast(maximum_u), .minimum_v = @intCast(minimum_v), .maximum_v = @intCast(maximum_v) };
        aperture.restrict(&words);
        try std.testing.expectEqualSlices(u64, &expected, &words);
    };
}

test "coarse face vectors match every voxel and deterministic mixed openings" {
    var random = std.Random.DefaultPrng.init(0x412d391);
    for (0..1024) |pass| {
        var words: [4]u64 = @splat(0);
        if (pass < 256) {
            words[pass / 64] = @as(u64, 1) << @intCast(pass % 64);
        } else for (&words) |*word| word.* = random.random().int(u64);
        var expected: u16 = 0;
        for (0..256) |bit| {
            if (words[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0) expected |= @as(u16, 1) << @intCast((bit / 16 / 4) * 4 + bit % 16 / 4);
        }
        try std.testing.expectEqual(expected, Section.coarseFace(words));
    }
}

fn coordinates(index: u12) [3]i32 {
    return .{ index % 16, index / 256, index / 16 % 16 };
}

pub fn transportFace(data: *const [64]u64, face: usize, destination: *[64]u64) bool {
    assert(face < 6);
    const bits = extractFace(data, face, false);
    if (@reduce(.Or, @as(@Vector(4, u64), bits)) == 0) return false;
    const positive = face & 1 == 0;
    var changed = false;
    switch (face / 2) {
        0 => for (0..16) |y| for (0..16) |z| {
            const index = y * 16 + z;
            const bit = (bits[index / 64] >> @as(u6, @intCast(index % 64))) & 1;
            const selected = bit << @as(u6, @intCast(z % 4 * 16 + @as(usize, if (positive) 15 else 0)));
            const word = &destination[y * 4 + z / 4];
            changed = changed or word.* & selected != selected;
            word.* |= selected;
        },
        1 => {
            const target = destination[if (positive) @as(usize, 60) else 0..][0..4];
            const before: @Vector(4, u64) = target.*;
            const after = before | @as(@Vector(4, u64), bits);
            changed = @reduce(.Or, before != after);
            target.* = after;
        },
        2 => for (0..16) |y| {
            const row = (bits[y / 4] >> @as(u6, @intCast(y % 4 * 16))) & 65535;
            const selected = row << @as(u6, if (positive) 48 else 0);
            const word = &destination[y * 4 + @as(usize, if (positive) 3 else 0)];
            changed = changed or word.* & selected != selected;
            word.* |= selected;
        },
        else => unreachable,
    }
    return changed;
}

fn extractFace(data: *const [64]u64, face: usize, comptime invert: bool) [4]u64 {
    assert(face < 6);
    const axis = face / 2;
    const edge: usize = if (face % 2 == 0) 0 else 15;
    return extractSlice(data, axis, edge, invert);
}

fn extractSlice(data: *const [64]u64, axis: usize, edge: usize, comptime invert: bool) [4]u64 {
    assert(axis < 3 and edge < 16);
    var words: [4]u64 = @splat(0);
    for (&words, 0..) |*word, group| {
        if (axis == 1) {
            word.* = if (invert) ~data[edge * 4 + group] else data[edge * 4 + group];
            continue;
        }
        for (0..4) |row| {
            const y = group * 4 + row;
            var bits: u16 = 0;
            if (axis == 2) {
                const value = if (invert) ~data[y * 4 + edge / 4] else data[y * 4 + edge / 4];
                bits = @truncate(value >> @intCast(edge % 4 * 16));
            } else for (0..4) |column| {
                const value = if (invert) ~data[y * 4 + column] else data[y * 4 + column];
                // Pack the four bits spaced sixteen apart into one nibble.
                var gathered = (value >> @intCast(edge)) & 0x0001000100010001;
                gathered = (gathered | (gathered >> 15)) & 0x0000000300000003;
                gathered = (gathered | (gathered >> 30)) & 15;
                bits |= @as(u16, @intCast(gathered)) << @intCast(column * 4);
            }
            word.* |= @as(u64, bits) << @intCast(row * 16);
        }
    }
    return words;
}

fn localIndex(point: [3]i32) u12 {
    for (point) |coordinate| assert(coordinate >= 0 and coordinate < 16);
    return @intCast(point[1] * 256 + point[2] * 16 + point[0]);
}

test "directional row closure matches scalar reachability without crossing row boundaries" {
    var random = std.Random.DefaultPrng.init(0x731fa);
    for (0..4096) |pattern| {
        const open = if (pattern == 0) @as(u64, 0) else if (pattern == 1) std.math.maxInt(u64) else random.random().int(u64);
        const bits = random.random().int(u64) & open;
        for ([_]bool{ false, true }) |positive| {
            var expected: u64 = 0;
            for (0..4) |row| {
                var reached = false;
                for (0..16) |index| {
                    const x = if (positive) index else 15 - index;
                    const bit = @as(u64, 1) << @intCast(row * 16 + x);
                    reached = open & bit != 0 and (reached or bits & bit != 0);
                    if (reached) expected |= bit;
                }
            }
            try std.testing.expectEqual(expected, sweepRows(bits, open, positive));
        }
    }
}

test "directional section sweeps preserve scalar voxel reachability in every octant" {
    var random = std.Random.DefaultPrng.init(0x8137ab);
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var section: Section = .{};
    for (0..32) |pattern| {
        var solid: [64]u64 = undefined;
        for (&solid) |*word| word.* = if (pattern == 0) 0 else if (pattern == 1) std.math.maxInt(u64) else random.random().int(u64);
        if (pattern == 2 or pattern == 3) for (0..4096) |local| {
            const point = coordinates(@intCast(local));
            const bit = @as(u64, 1) << @intCast(local % 64);
            const inside = point[1] >= 4 and point[1] < 12 and point[2] >= 2 and point[2] < 14;
            if (!inside) solid[local / 64] |= bit else if (pattern == 2) solid[local / 64] &= ~bit;
        };
        section.build(&solid, &workspace, &prepared);
        for (0..8) |octant| {
            var entries: [3]Entry = undefined;
            for (&entries) |*entry| {
                for (&entry.words) |*word| word.* = if (pattern == 2) std.math.maxInt(u64) else random.random().int(u64);
            }
            const incoming: u6 = if (pattern < 4) 63 else random.random().int(u6);
            const camera: ?Bounds = if (pattern % 2 == 0) .{ .minimum = .{ 3, 5, 6 }, .maximum = .{ 9, 11, 12 } } else null;
            var portals: [6][4]u64 = undefined;
            for (&portals, 0..) |*words, face| words.* = section.faceWords(face);
            section.restrictPortals(&portals, incoming, &entries, @intCast(octant), camera, section.bounds, &workspace);
            var reached: [4096]bool = undefined;
            for (0..16) |iy| for (0..16) |iz| for (0..16) |ix| {
                const point = [3]i32{ @intCast(if (octant & 1 != 0) ix else 15 - ix), @intCast(if (octant & 2 != 0) iy else 15 - iy), @intCast(if (octant & 4 != 0) iz else 15 - iz) };
                const local = localIndex(point);
                reached[local] = false;
                if (section.blocked(local)) continue;
                if (camera) |bounds| reached[local] = point[0] >= bounds.minimum[0] and point[0] < bounds.maximum[0] and point[1] >= bounds.minimum[1] and point[1] < bounds.maximum[1] and point[2] >= bounds.minimum[2] and point[2] < bounds.maximum[2];
                for (0..3) |axis| {
                    const positive = octant & (@as(usize, 1) << @intCast(axis)) != 0;
                    if (point[axis] == (if (positive) @as(i32, 0) else 15)) {
                        const face = axis * 2 + @intFromBool(!positive);
                        if (incoming & (@as(u6, 1) << @intCast(face)) == 0) continue;
                        const u: usize = if (axis == 0) 2 else 0;
                        const v: usize = if (axis == 1) 2 else 1;
                        const bit: usize = @intCast(point[v] * 16 + point[u]);
                        reached[local] = reached[local] or entries[axis].words[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0;
                    } else {
                        var previous = point;
                        previous[axis] += if (positive) @as(i32, -1) else 1;
                        reached[local] = reached[local] or reached[localIndex(previous)];
                    }
                }
            };
            for (0..3) |axis| {
                const face = axis * 2 + (octant >> @intCast(axis) & 1);
                const u: usize = if (axis == 0) 2 else 0;
                const v: usize = if (axis == 1) 2 else 1;
                for (0..256) |bit| {
                    var point: [3]i32 = undefined;
                    point[axis] = if (face % 2 == 0) 0 else 15;
                    point[u] = @intCast(bit % 16);
                    point[v] = @intCast(bit / 16);
                    const actual = portals[face][bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0;
                    if (section.boundary_open) try std.testing.expect(!reached[localIndex(point)] or actual) else try std.testing.expectEqual(reached[localIndex(point)], actual);
                }
            }
        }
    }
}

test "interior slices match scalar occupancy on every axis and plane" {
    var random = std.Random.DefaultPrng.init(0x814fc31);
    var solid: [64]u64 = undefined;
    for (0..8) |_| {
        for (&solid) |*word| word.* = random.random().int(u64);
        for (0..3) |axis| for (0..16) |plane| {
            const words = extractSlice(&solid, axis, plane, true);
            const u: usize = if (axis == 0) 2 else 0;
            const v: usize = if (axis == 1) 2 else 1;
            for (0..256) |index| {
                var point: [3]i32 = undefined;
                point[axis] = @intCast(plane);
                point[u] = @intCast(index % 16);
                point[v] = @intCast(index / 16);
                const local = localIndex(point);
                const open = solid[local / 64] & (@as(u64, 1) << @intCast(local % 64)) == 0;
                try std.testing.expectEqual(open, words[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0);
            }
        };
    }
}

test "interior barriers distinguish connected winding tunnels from straight passages" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var section: Section = .{};
    for (0..3) |axis| for (2..14) |plane| {
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        for (0..16) |x| for (8..10) |y| for (0..16) |z| {
            const open = if (x + 1 < plane or x > plane + 1) z >= 7 and z < 9 else if (x == plane) z >= 13 and z < 15 else z >= 7 and z < 15;
            if (!open) continue;
            var point = [3]i32{ @intCast(x), @intCast(y), @intCast(z) };
            std.mem.swap(i32, &point[0], &point[axis]);
            const local = localIndex(point);
            solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        };
        section.build(&solid, &workspace, &prepared);
        const connected = section.connections;
        try std.testing.expectEqual(@as(u16, 1), section.components);
        try std.testing.expect(connected[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)) != 0);
        try std.testing.expect(section.blocked_pairs[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)) != 0);
        for (0..16) |x| for (8..10) |y| for (7..9) |z| {
            var point = [3]i32{ @intCast(x), @intCast(y), @intCast(z) };
            std.mem.swap(i32, &point[0], &point[axis]);
            const local = localIndex(point);
            solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        };
        section.build(&solid, &workspace, &prepared);
        try std.testing.expectEqual(connected, section.connections);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)));
    };
}

test "interior barriers preserve straight passages at every endpoint height" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var section: Section = .{};
    for (0..3) |axis| for (0..16) |start| for (0..16) |finish| {
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        const from = [2]i32{ @intCast(start), @intCast((start * 5 + finish * 3) % 16) };
        const to = [2]i32{ @intCast(finish), @intCast((finish * 7 + start) % 16) };
        for (0..16) |x| {
            var low: [2]i32 = undefined;
            var high: [2]i32 = undefined;
            for (0..2) |coordinate| {
                const a = (2 * from[coordinate] + 1) * 16 + 2 * (to[coordinate] - from[coordinate]) * @as(i32, @intCast(x));
                const b = a + 2 * (to[coordinate] - from[coordinate]);
                low[coordinate] = @divFloor(@min(a, b), 32);
                high[coordinate] = @divFloor(@max(a, b), 32);
            }
            var y = low[0];
            while (y <= high[0]) : (y += 1) {
                var z = low[1];
                while (z <= high[1]) : (z += 1) {
                    var point = [3]i32{ @intCast(x), y, z };
                    std.mem.swap(i32, &point[0], &point[axis]);
                    const local = localIndex(point);
                    solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
                }
            }
        }
        section.build(&solid, &workspace, &prepared);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)));
    };
}

test "face pair proofs reject bends in every orientation without changing connectivity" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var section: Section = .{};
    for (0..6) |from| for (from + 1..6) |to| {
        if (from / 2 == to / 2) continue;
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        const remaining = 3 - from / 2 - to / 2;
        for (0..13) |x| for (0..10) |z| for (8..10) |y| {
            if (z < 8 and x < 11) continue;
            var point: [3]i32 = undefined;
            point[from / 2] = @intCast(if (from % 2 == 0) x else 15 - x);
            point[to / 2] = @intCast(if (to % 2 == 0) z else 15 - z);
            point[remaining] = @intCast(y);
            const local = localIndex(point);
            solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        };
        section.build(&solid, &workspace, &prepared);
        try std.testing.expect(section.connections[from] & (@as(u6, 1) << @intCast(to)) != 0);
        try std.testing.expect(section.blocked_pairs[from] & (@as(u6, 1) << @intCast(to)) != 0);
        try std.testing.expect(section.blocked_pairs[to] & (@as(u6, 1) << @intCast(from)) != 0);
    };
}

test "face pair proofs preserve independently carved straight rays between all faces" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var section: Section = .{};
    var random = std.Random.DefaultPrng.init(0xe43f02);
    for (0..6) |from| for (from + 1..6) |to| for (0..32) |_| {
        var start: [3]f64 = undefined;
        var finish: [3]f64 = undefined;
        for (&start, &finish) |*a, *b| {
            a.* = @as(f64, @floatFromInt(random.random().uintLessThan(u8, 16))) + 0.5;
            b.* = @as(f64, @floatFromInt(random.random().uintLessThan(u8, 16))) + 0.5;
        }
        start[from / 2] = if (from % 2 == 0) 0 else 16;
        finish[to / 2] = if (to % 2 == 0) 0 else 16;
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        for (0..volume) |local| {
            const point = [3]usize{ local % 16, local / 256, local / 16 % 16 };
            var near: f64 = 0;
            var far: f64 = 1;
            for (point, start, finish) |coordinate, a, b| {
                const low: f64 = @floatFromInt(coordinate);
                const high = low + 1;
                if (a == b) {
                    if (a < low or a > high) far = -1;
                } else {
                    const entry = (low - a) / (b - a);
                    const exit = (high - a) / (b - a);
                    near = @max(near, @min(entry, exit));
                    far = @min(far, @max(entry, exit));
                }
            }
            if (near <= far) solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        }
        section.build(&solid, &workspace, &prepared);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[from] & (@as(u6, 1) << @intCast(to)));
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[to] & (@as(u6, 1) << @intCast(from)));
        var octant: usize = 0;
        for (start, finish, 0..) |a, b, axis| if (b > a) {
            octant |= @as(usize, 1) << @intCast(axis);
        };
        const path = Topology.index(octant, from / 2, to / 2);
        try std.testing.expect(section.topology.paths & (@as(u36, 1) << @intCast(path)) != 0);
        try std.testing.expectEqual(path, Topology.index(octant ^ 7, to / 2, from / 2));
    };
}

test "word flood matches scalar connectivity bounds and boundary masks for every component" {
    const Reference = struct {
        seen: [64]u64,
        bits: [64]u64 = undefined,
        queue: [4096]u12 = undefined,
        count: usize = 0,

        fn visit(self: *@This(), voxel: u12) void {
            const bit = @as(u64, 1) << @intCast(voxel % 64);
            if (self.seen[voxel / 64] & bit != 0) return;
            self.seen[voxel / 64] |= bit;
            self.bits[voxel / 64] |= bit;
            assert(self.count < self.queue.len);
            self.queue[self.count] = voxel;
            self.count += 1;
        }

        fn flood(self: *@This(), seed: u12) Component {
            @memset(&self.bits, 0);
            self.count = 0;
            self.visit(seed);
            var result: Component = .{ .seed = seed, .faces = 0 };
            var head: usize = 0;
            while (head < self.count) : (head += 1) {
                const voxel = self.queue[head];
                const point = coordinates(voxel);
                result.seed = @min(result.seed, voxel);
                for (0..3) |axis| {
                    const stride = [_]u12{ 1, 256, 16 };
                    if (point[axis] == 0) result.faces |= @as(u6, 1) << @intCast(axis * 2) else self.visit(voxel - stride[axis]);
                    if (point[axis] == 15) result.faces |= @as(u6, 1) << @intCast(axis * 2 + 1) else self.visit(voxel + stride[axis]);
                }
            }
            return result;
        }

        fn geometry(self: *const @This()) ComponentGeometry {
            var result: ComponentGeometry = .{ .bounds = .{ .minimum = @splat(16), .maximum = @splat(0) }, .portals = @splat(@splat(0)) };
            for (self.queue[0..self.count]) |voxel| {
                const point = coordinates(voxel);
                for (0..3) |axis| {
                    result.bounds.minimum[axis] = @min(result.bounds.minimum[axis], point[axis]);
                    result.bounds.maximum[axis] = @max(result.bounds.maximum[axis], point[axis] + 1);
                    if (point[axis] != 0 and point[axis] != 15) continue;
                    const face = axis * 2 + @intFromBool(point[axis] == 15);
                    const u: usize = if (axis == 0) 2 else 0;
                    const v: usize = if (axis == 1) 2 else 1;
                    const bit: usize = @intCast(point[v] * 16 + point[u]);
                    result.portals[face][bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
                }
            }
            result.rectangular = boundsVolume(result.bounds) == self.count;
            return result;
        }
    };
    var random = std.Random.DefaultPrng.init(0x95a4217);
    for (0..32) |pattern| {
        var solid: [64]u64 = @splat(0);
        for (0..4096) |voxel| {
            const point = coordinates(@intCast(voxel));
            const blocked = if (pattern == 0) false else if (pattern == 1) true else if (pattern == 2) @mod(point[0] + point[1] + point[2], 2) == 0 else random.random().uintLessThan(u8, 100) < (pattern % 5) * 20 + 10;
            if (blocked) solid[voxel / 64] |= @as(u64, 1) << @intCast(voxel % 64);
        }
        var reference: Reference = .{ .seen = solid };
        var workspace: Workspace = undefined;
        workspace.seen = solid;
        for (0..4096) |voxel| {
            if (workspace.seen[voxel / 64] & (@as(u64, 1) << @intCast(voxel % 64)) != 0) continue;
            try std.testing.expectEqual(reference.flood(@intCast(voxel)), workspace.flood(@intCast(voxel)));
            try std.testing.expectEqual(reference.count, workspace.count);
            try std.testing.expectEqualSlices(u64, &reference.seen, &workspace.seen);
            try std.testing.expectEqualSlices(u64, &reference.bits, &workspace.component_bits);
            try std.testing.expectEqualDeep(reference.geometry(), workspace.geometry());
        }
        try std.testing.expectEqualSlices(u64, &@as([64]u64, @splat(std.math.maxInt(u64))), &workspace.seen);
    }
}

test "section face connectivity preserves separated air components" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var bits: [64]u64 = @splat(0);
    for (0..16) |y| for (0..16) |z| {
        const index = localIndex(.{ 8, @intCast(y), @intCast(z) });
        bits[index / 64] |= @as(u64, 1) << @as(u6, @intCast(index % 64));
    };
    var section: Section = .{};
    section.build(&bits, &workspace, &prepared);
    try std.testing.expectEqual(@as(u16, 2), section.components);
    try std.testing.expect(section.component_data.len != 0);
    try std.testing.expectEqual(@as(u6, 0), section.connections[0] & 2);
    try std.testing.expectEqual(@as(u6, 0), section.component(localIndex(.{ 2, 8, 8 }), &workspace).?.faces & 2);
    try std.testing.expectEqual(@as(u6, 0), section.component(localIndex(.{ 12, 8, 8 }), &workspace).?.faces & 1);
    var components = section.componentIterator();
    _ = components.next().?;
    try std.testing.expectEqualDeep(workspace.geometry(), components.next().?.geometry(&section));
}

test "nested boundary components cache exact complementary apertures" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var solid: [64]u64 = @splat(std.math.maxInt(u64));
    for (0..16) |x| for (1..15) |y| for (1..15) |z| {
        const ring = y == 1 or y == 14 or z == 1 or z == 14;
        const center = y >= 6 and y < 10 and z >= 6 and z < 10;
        if (!ring and !center) continue;
        const index = localIndex(.{ @intCast(x), @intCast(y), @intCast(z) });
        solid[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
    };
    var section: Section = .{};
    section.build(&solid, &workspace, &prepared);
    try std.testing.expectEqual(@as(u16, 2), section.boundary_components);
    try std.testing.expect(section.component_data.len != 0);
    workspace.seen = solid;
    var components = section.componentIterator();
    while (components.next()) |component_value| {
        _ = workspace.flood(component_value.seed());
        try std.testing.expectEqualDeep(workspace.geometry(), component_value.geometry(&section));
    }
}

test "packed face extraction agrees with every scalar boundary cell on all axes" {
    var random = std.Random.DefaultPrng.init(0x9a1716);
    for (0..32) |_| {
        var section: Section = .{ .kind = .mixed };
        for (&section.solid) |*word| word.* = random.random().int(u64);
        for (0..6) |face| {
            const words = extractFace(&section.solid, face, true);
            const axis = face / 2;
            const u: usize = if (axis == 0) 2 else 0;
            const v: usize = if (axis == 1) 2 else 1;
            for (0..16) |row| for (0..16) |column| {
                var point: [3]i32 = undefined;
                point[axis] = if (face % 2 == 0) 0 else 15;
                point[u] = @intCast(column);
                point[v] = @intCast(row);
                const bit = row * 16 + column;
                try std.testing.expectEqual(!section.blocked(localIndex(point)), words[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0);
            };
        }
    }
}

test "entry apertures retain exactly their boundary cells on every face" {
    for (0..6) |face| {
        const u: usize = if (face / 2 == 0) 2 else 0;
        const v: usize = if (face / 2 == 1) 2 else 1;
        for ([_][4]i32{ .{ 0, 16, 0, 16 }, .{ 3, 12, 2, 7 }, .{ 15, 16, 0, 1 }, .{ 0, 1, 15, 16 } }) |rectangle| {
            var bounds: Bounds = .{ .minimum = @splat(0), .maximum = @splat(0) };
            bounds.minimum[u] = rectangle[0];
            bounds.maximum[u] = rectangle[1];
            bounds.minimum[v] = rectangle[2];
            bounds.maximum[v] = rectangle[3];
            var words: [4]u64 = @splat(std.math.maxInt(u64));
            Aperture.init(face, bounds).restrict(&words);
            for (0..256) |bit| {
                const column = @as(i32, @intCast(bit % 16));
                const row = @as(i32, @intCast(bit / 16));
                const included = column >= rectangle[0] and column < rectangle[1] and row >= rectangle[2] and row < rectangle[3];
                try std.testing.expectEqual(included, words[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0);
            }
        }
    }
}

test "baked portal transfers contain every exact directional boundary path" {
    var random = std.Random.DefaultPrng.init(0x461239b7);
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var data: Section = .{};
    for (0..12) |pattern| {
        var solid: [64]u64 = undefined;
        for (&solid) |*word| word.* = random.random().int(u64) & random.random().int(u64);
        if (pattern == 0) @memset(&solid, 0);
        if (pattern == 1) @memset(&solid, std.math.maxInt(u64));
        data.build(&solid, &workspace, &prepared);
        if (data.kind != .mixed) continue;
        for (0..8) |direction| for (0..8) |_| {
            for (0..3) |axis| {
                const tiles = random.random().int(u16);
                var expected: [3]u16 = @splat(0);
                var pending = tiles;
                while (pending != 0) : (pending &= pending - 1) {
                    for (&expected, data.transfer(@intCast(direction), axis, @intCast(@ctz(pending)))) |*value, reached| value.* |= reached;
                }
                try std.testing.expectEqualDeep(expected, data.transferMany(@intCast(direction), axis, tiles));
            }
            var entries: [3]Entry = undefined;
            for (&entries) |*entry| for (&entry.words) |*word| {
                word.* = random.random().int(u64);
            };
            const incoming = random.random().int(u6);
            var expected: [6][4]u64 = undefined;
            for (&expected, 0..) |*words, face| words.* = data.faceWords(face);
            var actual = expected;
            data.restrictPortals(&expected, incoming, &entries, @intCast(direction), null, data.bounds, &workspace);
            data.restrictBaked(&actual, incoming, &entries, @intCast(direction), null, data.bounds, &workspace);
            for (0..3) |axis| {
                const face = axis * 2 + ((direction >> @intCast(axis)) & 1);
                for (expected[face], actual[face]) |required, disclosed| try std.testing.expectEqual(@as(u64, 0), required & ~disclosed);
            }
        };
    }
}

test "baked portal transfers match scalar sweeps for every incoming tile" {
    var workspace: Workspace = undefined;
    var prepared: [Section.prepared_bytes]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x7e915ca2);
    for (0..8) |pattern| {
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        for (0..4096) |local| {
            const x = local % 16;
            const z = local / 16 % 16;
            const y = local / 256;
            const open = switch (pattern) {
                0 => y >= 8,
                1 => x < 4 and z >= 12,
                2 => y == 9 and z == 7,
                3 => x >= 3 and x < 11 and y >= 2 and y < 13 and z >= 4 and z < 15,
                4 => y == 4 and z == 4 or y == 12 and z == 12,
                5 => x > 0 and x < 15 and y > 0 and y < 15 and z > 0 and z < 15,
                else => random.random().uintLessThan(u8, 4) != 0,
            };
            if (open) solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        }
        var data: Section = .{};
        data.build(&solid, &workspace, &prepared);
        for (0..8) |octant| for (0..3) |incoming_axis| for (0..16) |tile| {
            const face = incoming_axis * 2 + 1 - ((octant >> @intCast(incoming_axis)) & 1);
            var selected = Section.coarseWords(@as(u16, 1) << @intCast(tile));
            for (&selected, data.faceWords(face)) |*word, open| word.* &= open;
            if (@reduce(.Or, @as(@Vector(4, u64), selected)) == 0) continue;
            var portals: [6][4]u64 = undefined;
            for (&portals, 0..) |*words, direction| words.* = data.faceWords(direction);
            var entries: [3]Entry = undefined;
            entries[incoming_axis] = .{ .words = selected };
            data.restrictPortals(&portals, @as(u6, 1) << @intCast(face), &entries, @intCast(octant), null, data.bounds, &workspace);
            const actual = data.transfer(@intCast(octant), incoming_axis, @intCast(tile));
            for (0..3) |axis| {
                const exit = axis * 2 + ((octant >> @intCast(axis)) & 1);
                try std.testing.expectEqual(Section.coarseFace(portals[exit]), actual[axis] & Section.coarseFace(data.faceWords(exit)));
            }
        };
    }
}

test "face transport matches scalar coordinates for every face" {
    var random = std.Random.DefaultPrng.init(0x9172);
    for (0..32) |_| {
        var source: [64]u64 = undefined;
        for (&source) |*word| word.* = random.random().int(u64);
        for (0..6) |face| {
            var actual: [64]u64 = @splat(0);
            var expected: [64]u64 = @splat(0);
            const axis = face / 2;
            const edge: usize = if (face & 1 == 0) 0 else 15;
            for (0..4096) |index| {
                var at = [_]usize{ index % 16, index / 256, index / 16 % 16 };
                if (at[axis] != edge or source[index / 64] & (@as(u64, 1) << @intCast(index % 64)) == 0) continue;
                at[axis] = 15 - edge;
                const target = at[1] * 256 + at[2] * 16 + at[0];
                expected[target / 64] |= @as(u64, 1) << @intCast(target % 64);
            }
            try std.testing.expect(transportFace(&source, face, &actual));
            try std.testing.expectEqualSlices(u64, &expected, &actual);
            try std.testing.expect(!transportFace(&source, face, &actual));
        }
    }
}
