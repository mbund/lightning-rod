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

pub const Section = struct {
    solid: [volume / 64]u64 = @splat(0),
    connections: [6]u6 = @splat(63),
    faces: u6 = 63,
    blocked_pairs: [6]u6 = @splat(0),
    bounds: ComponentBounds = .{},
    components: u16 = 1,
    boundary_components: u16 = 1,
    first: u12 = 0,
    kind: enum { air, solid, mixed } = .air,
    // Two components cover a common surface and cave split. Other partitions use flood traversal.
    cached_partitions: bool = false,
    boundary_open: bool = true,
    partitions: [2]Partition = undefined,

    pub fn build(self: *Section, occupied_bits: *const [volume / 64]u64, workspace: *Workspace) void {
        self.solid = occupied_bits.*;
        self.first = 0;
        self.cached_partitions = false;
        self.blocked_pairs = @splat(0);
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
        self.boundary_open = !self.boundaryChanged(&@as([64]u64, @splat(0)));
        self.connections = @splat(0);
        self.faces = 0;
        self.components = 0;
        self.boundary_components = 0;
        if (self.kind == .solid) return;
        workspace.seen = occupied_bits.*;
        var compact = true;
        for (0..volume / 64) |word| {
            var unseen = ~workspace.seen[word];
            while (unseen != 0) : (unseen = ~workspace.seen[word]) {
                const connected = workspace.flood(@intCast(word * 64 + @ctz(unseen)));
                if (self.components == 0) self.first = connected.seed;
                self.components += 1;
                self.boundary_components += @intFromBool(connected.faces != 0);
                if (connected.faces != 0 and self.boundary_components <= self.partitions.len and occupied + workspace.count < volume) {
                    if (Partition.init(self, workspace.geometry(), connected.faces, connected.seed)) |partition| self.partitions[self.boundary_components - 1] = partition else compact = false;
                }
                self.faces |= connected.faces;
                for (0..6) |face| if (connected.faces & (@as(u6, 1) << @as(u3, @intCast(face))) != 0) {
                    self.connections[face] |= connected.faces;
                };
            }
        }
        self.cached_partitions = compact and self.boundary_components == self.partitions.len;
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
        workspace.seen = self.solid;
        return workspace.flood(index);
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
        return extractFace(&self.solid, face, true);
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

    pub fn portal(self: *const Section, face: usize, adjacent: ?*const Section) ?Bounds {
        var words = self.faceWords(face);
        if (adjacent) |other| for (&words, other.faceWords(face ^ 1)) |*word, opposite| {
            word.* &= opposite;
        };
        return portalBounds(face, words);
    }
};

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
        for (words) |*word| word.* &= @as(u64, columns) * 0x0001000100010001;
        for (0..16) |row| if (row < self.minimum_v or row > self.maximum_v) {
            words[row / 4] &= ~(@as(u64, 0xffff) << @intCast(row % 4 * 16));
        };
    }
};

const Partition = struct {
    seed: u12,
    bounds: ComponentBounds,
    apertures: [6]Aperture = undefined,

    fn init(section: *const Section, data: ComponentGeometry, faces: u6, seed: u12) ?Partition {
        var result: Partition = .{ .seed = seed, .bounds = ComponentBounds.init(data.bounds, faces, data.rectangular) };
        for (0..6) |face| {
            if (faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
            const bounds = Section.portalBounds(face, data.portals[face]).?;
            const aperture = Aperture.init(face, bounds);
            var words = section.faceWords(face);
            aperture.restrict(&words);
            // A rectangle is cached only if it selects this component's exact boundary mask.
            if (!std.mem.eql(u64, &words, &data.portals[face])) return null;
            result.apertures[face] = aperture;
        }
        return result;
    }

    fn geometry(self: Partition, section: *const Section) ComponentGeometry {
        assert(section.cached_partitions and section.boundary_components == 2);
        var result: ComponentGeometry = .{ .bounds = self.bounds.geometry(), .rectangular = self.bounds.rectangular, .portals = @splat(@splat(0)) };
        for (0..6) |face| {
            if (self.bounds.faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
            result.portals[face] = section.faceWords(face);
            self.apertures[face].restrict(&result.portals[face]);
        }
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

const Cone = struct {
    const scale = 65536;
    minimum: [2]i32 = @splat(scale),
    maximum: [2]i32 = @splat(-scale),

    fn valid(self: Cone) bool {
        return self.minimum[0] <= self.maximum[0] and self.minimum[1] <= self.maximum[1];
    }

    fn merge(self: *Cone, other: Cone) void {
        assert(other.valid());
        for (0..2) |axis| {
            self.minimum[axis] = @min(self.minimum[axis], other.minimum[axis]);
            self.maximum[axis] = @max(self.maximum[axis], other.maximum[axis]);
        }
    }

    fn clip(self: Cone, origin: Bounds, portal: Bounds, direction: usize) Cone {
        assert(direction < 6 and self.valid());
        const axis = direction / 2;
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        const near_depth: i64 = if (direction % 2 == 0) @as(i64, origin.minimum[axis]) - portal.maximum[axis] else @as(i64, portal.minimum[axis]) - origin.maximum[axis];
        const far_depth: i64 = if (direction % 2 == 0) @as(i64, origin.maximum[axis]) - portal.minimum[axis] else @as(i64, portal.maximum[axis]) - origin.minimum[axis];
        if (far_depth < 0) return .{};
        const near = @max(1, near_depth);
        const far = @max(1, far_depth);
        var clipped = self;
        for ([_]usize{ u, v }, 0..) |coordinate, i| {
            const low = @as(i64, portal.minimum[coordinate]) - origin.maximum[coordinate];
            const high = @as(i64, portal.maximum[coordinate]) - origin.minimum[coordinate];
            const low_denominator = if (low < 0) near else far;
            const high_denominator = if (high > 0) near else far;
            const low_numerator = low * scale;
            const high_numerator = high * scale;
            if (low_numerator >= (@as(i64, clipped.maximum[i]) + 1) * low_denominator or
                high_numerator <= (@as(i64, clipped.minimum[i]) - 1) * high_denominator) return .{};
            // Divide only when the portal narrows an inherited cone.
            if (low_numerator >= (@as(i64, clipped.minimum[i]) + 1) * low_denominator)
                clipped.minimum[i] = @intCast(@divFloor(low_numerator, low_denominator));
            if (high_numerator <= (@as(i64, clipped.maximum[i]) - 1) * high_denominator)
                clipped.maximum[i] = @intCast(-@divFloor(-high_numerator, high_denominator));
        }
        return clipped;
    }
};

pub const Traversal = struct {
    const Node = struct {
        cones: [3]Cone = @splat(.{}),
        incoming: u6 = 0,
        // A face can open onto several disconnected spaces. Retain the aperture we reached.
        entries: [3]Entry = undefined,
        visible: bool = false,
        queued: bool = false,
        processed: bool = false,
        initial: ?u6 = null,
        seed_components: ?*const [64]u64 = null,
        next: usize = std.math.maxInt(usize),
        generation: u64 = 0,
    };

    nodes: []Node,
    buckets: []usize,
    disclosed: []usize,
    disclosed_count: usize = 0,
    maximum_size: [3]usize,
    bucket_count: usize = 0,
    generation: u64 = 0,
    grid: Grid = undefined,
    origin: Bounds = undefined,
    octant: u3 = 0,
    allowed: u6 = 0,
    bucket: usize = 0,
    head: usize = 0,
    tail: usize = 0,
    visits: usize = 0,
    edges: usize = 0,
    workspace: Workspace = undefined,

    pub fn init(allocator: std.mem.Allocator, maximum_size: [3]usize) !Traversal {
        const maximum = maximum_size[0] * maximum_size[1] * maximum_size[2];
        assert(maximum > 0);
        const nodes = try allocator.alloc(Node, maximum);
        @memset(nodes, .{});
        return .{ .nodes = nodes, .buckets = try allocator.alloc(usize, maximum_size[0] + maximum_size[1] + maximum_size[2] - 2), .disclosed = try allocator.alloc(usize, maximum), .maximum_size = maximum_size };
    }

    pub fn begin(self: *Traversal, grid: Grid, source: [3]i32, exits: u6, octant: u3) void {
        var origin: Bounds = undefined;
        for (0..3) |axis| {
            origin.minimum[axis] = source[axis] * 16;
            origin.maximum[axis] = origin.minimum[axis] + 16;
        }
        self.beginBounds(grid, origin, octant);
        self.seed(source, exits, null, null);
    }

    pub fn beginBounds(self: *Traversal, grid: Grid, origin: Bounds, octant: u3) void {
        assert(grid.count() <= self.nodes.len);
        for (0..3) |axis| assert(grid.size[axis] <= self.maximum_size[axis]);
        self.bucket_count = grid.size[0] + grid.size[1] + grid.size[2] - 2;
        @memset(self.buckets[0..self.bucket_count], std.math.maxInt(usize));
        self.generation += 1;
        self.disclosed_count = 0;
        self.grid = grid;
        self.origin = origin;
        self.octant = octant;
        self.allowed = 0;
        self.head = 0;
        self.tail = 0;
        self.bucket = 0;
        self.visits = 0;
        self.edges = 0;
        for (0..3) |axis| {
            assert(origin.minimum[axis] < origin.maximum[axis] and grid.size[axis] > 0);
            self.allowed |= @as(u6, 1) << @intCast(self.direction(axis));
        }
    }

    fn direction(self: *const Traversal, axis: usize) usize {
        return axis * 2 + @as(usize, (self.octant >> @intCast(axis)) & 1);
    }

    fn distance(self: *const Traversal, at: [3]i32) usize {
        var result: usize = 0;
        for (0..3) |axis| {
            result += @intCast(if (self.octant & (@as(u3, 1) << @intCast(axis)) != 0) at[axis] - self.grid.minimum[axis] else self.grid.minimum[axis] + @as(i32, @intCast(self.grid.size[axis])) - 1 - at[axis]);
        }
        return result;
    }

    fn enqueue(self: *Traversal, index: usize, rank: usize) void {
        assert(index < self.grid.count());
        const node = &self.nodes[index];
        assert(!node.processed);
        if (node.queued) return;
        // Each octant permits three forward faces. Every edge reaches the next bucket.
        assert(rank < self.bucket_count and rank >= self.bucket and node.generation == self.generation);
        node.next = self.buckets[rank];
        self.buckets[rank] = index;
        node.queued = true;
        self.tail += 1;
    }

    /// Component masks remain borrowed until the next traversal begins.
    pub fn seed(self: *Traversal, at: [3]i32, exits: u6, entry: ?Bounds, components: ?*const [64]u64) void {
        const index = self.grid.index(at).?;
        const node = self.disclose(index);
        if (entry) |portal| {
            assert(components == null);
            const axis = for (0..3) |coordinate| {
                if (portal.minimum[coordinate] == portal.maximum[coordinate]) break coordinate;
            } else unreachable;
            var local = portal;
            for (0..3) |coordinate| {
                local.minimum[coordinate] -= at[coordinate] * 16;
                local.maximum[coordinate] -= at[coordinate] * 16;
            }
            assert(local.minimum[axis] == 0 or local.minimum[axis] == 16);
            const face = axis * 2 + @as(usize, @intFromBool(local.minimum[axis] == 16));
            const mask = @as(u6, 1) << @intCast(face);
            const aperture = Entry.init(face, local, @splat(std.math.maxInt(u64)));
            if (node.incoming & mask == 0) node.entries[axis] = aperture else node.entries[axis].merge(aperture);
            node.incoming |= mask;
        } else {
            node.seed_components = if (node.initial == null or node.seed_components == components) components else null;
            node.initial = (node.initial orelse 0) | exits;
        }
        var possible = false;
        for (&node.cones, 0..) |*cone, axis| {
            var full: Cone = undefined;
            for (0..2) |coordinate| {
                const positive = self.octant & (@as(u3, 1) << @intCast((axis + coordinate + 1) % 3)) != 0;
                full.minimum[coordinate] = if (positive) 0 else -Cone.scale;
                full.maximum[coordinate] = if (positive) Cone.scale else 0;
            }
            const candidate = if (entry) |portal| full.clip(self.origin, portal, self.direction(axis)) else full;
            if (candidate.valid()) {
                cone.merge(candidate);
                possible = true;
            }
        }
        if (exits & self.allowed != 0 and possible) self.enqueue(index, self.distance(at));
    }

    pub fn pending(self: *Traversal) ?usize {
        while (self.bucket < self.bucket_count) : (self.bucket += 1) {
            if (self.buckets[self.bucket] != std.math.maxInt(usize)) return self.buckets[self.bucket];
        }
        return null;
    }

    pub fn pendingBatch(self: *const Traversal, output: []usize) usize {
        var count: usize = 0;
        for (self.buckets[self.bucket..self.bucket_count]) |first| {
            var next = first;
            while (next != std.math.maxInt(usize)) {
                if (count == output.len) return count;
                output[count] = next;
                count += 1;
                next = self.nodes[next].next;
            }
        }
        return count;
    }

    pub fn outgoing(self: *const Traversal, index: usize, section: *const Section) u6 {
        const node = &self.nodes[index];
        if (section.kind == .air) return (if (node.incoming != 0) @as(u6, 63) else node.initial orelse 0) & self.allowed;
        var faces: u6 = node.initial orelse 0;
        for (0..6) |face| {
            if (node.incoming & (@as(u6, 1) << @as(u3, @intCast(face))) != 0) faces |= section.connections[face];
        }
        return faces & self.allowed;
    }

    pub fn advance(self: *Traversal, section: *const Section, neighbors: [6]?*const Section) void {
        const index = self.pending().?;
        const node = &self.nodes[index];
        assert(node.queued and !node.processed and node.visible and node.generation == self.generation);
        const at = self.grid.position(index);
        self.buckets[self.bucket] = node.next;
        self.head += 1;
        self.visits += 1;
        self.nodes[index].processed = true;
        const exits = self.outgoing(index, section);
        for (0..6) |face| {
            if (exits & (@as(u6, 1) << @intCast(face)) == 0) continue;
            var next = at;
            next[face / 2] += if (face % 2 == 0) @as(i32, -1) else 1;
            self.edges += @intFromBool(self.grid.index(next) != null);
        }
        var air = section.kind == .air;
        if (air) for (0..3) |axis| {
            const face = self.direction(axis);
            if (exits & (@as(u6, 1) << @intCast(face)) == 0) continue;
            if (neighbors[face]) |adjacent| {
                if (adjacent.kind != .air) {
                    air = false;
                    break;
                }
            } else {
                var next = at;
                next[axis] += if (face % 2 == 0) @as(i32, -1) else 1;
                assert(self.grid.index(next) == null);
            }
        };
        if (air) {
            self.advanceAir(at, node.cones, exits);
        } else if (section.boundary_components <= 1) {
            var portals: [6][4]u64 = undefined;
            for (0..6) |face| {
                portals[face] = section.faceWords(face);
            }
            section.restrictPortals(&portals, node.incoming, &node.entries, self.octant, if ((node.initial orelse 0) != 0) self.localCamera(at) else null, section.bounds, &self.workspace);
            self.advancePortals(at, node.cones, exits, &portals, neighbors, section);
        } else if (section.cached_partitions) {
            for (section.partitions) |partition| {
                if (partition.bounds.faces & exits == 0) continue;
                var geometry = partition.geometry(section);
                self.advanceComponent(index, at, &geometry, partition.bounds.faces, partition.seed, neighbors, section);
            }
        } else {
            self.workspace.seen = section.solid;
            for (0..64) |word| {
                var unseen = ~self.workspace.seen[word];
                while (unseen != 0) : (unseen = ~self.workspace.seen[word]) {
                    const component = self.workspace.flood(@intCast(word * 64 + @ctz(unseen)));
                    if (component.faces & exits == 0) continue;
                    var geometry = self.workspace.geometry();
                    self.advanceComponent(index, at, &geometry, component.faces, component.seed, neighbors, section);
                }
            }
        }
        assert(self.head <= self.tail and self.tail <= self.grid.count());
    }

    fn advanceAir(self: *Traversal, at: [3]i32, cones: [3]Cone, exits: u6) void {
        for (0..3) |axis| {
            const face = self.direction(axis);
            if (exits & (@as(u6, 1) << @intCast(face)) == 0) continue;
            var next = at;
            next[axis] += if (face % 2 == 0) @as(i32, -1) else 1;
            const target = self.grid.index(next) orelse continue;
            var portal: Bounds = .{ .minimum = .{ at[0] * 16, at[1] * 16, at[2] * 16 }, .maximum = .{ at[0] * 16 + 16, at[1] * 16 + 16, at[2] * 16 + 16 } };
            portal.minimum[axis] = if (face % 2 == 0) portal.minimum[axis] else portal.maximum[axis];
            portal.maximum[axis] = portal.minimum[axis];
            var reached: ?*Node = null;
            for (cones, 0..) |cone, coordinate| {
                if (!cone.valid()) continue;
                const clipped = cone.clip(self.origin, portal, self.direction(coordinate));
                if (!clipped.valid()) continue;
                const destination = reached orelse self.disclose(target);
                reached = destination;
                destination.cones[coordinate].merge(clipped);
            }
            const destination = reached orelse continue;
            assert(!destination.processed);
            destination.entries[axis] = .{ .words = @splat(std.math.maxInt(u64)) };
            destination.incoming |= @as(u6, 1) << @intCast(face ^ 1);
            self.enqueue(target, self.bucket + 1);
        }
    }

    fn advanceComponent(self: *Traversal, index: usize, at: [3]i32, geometry: *ComponentGeometry, faces: u6, component_seed: u12, neighbors: [6]?*const Section, section: *const Section) void {
        const node = &self.nodes[index];
        var initial = node.initial != null;
        if (node.initial != null) {
            if (node.seed_components) |selected| {
                initial = selected[component_seed / 64] & (@as(u64, 1) << @as(u6, @intCast(component_seed % 64))) != 0;
            } else for (0..3) |axis| initial = initial and geometry.bounds.minimum[axis] + at[axis] * 16 < self.origin.maximum[axis] and geometry.bounds.maximum[axis] + at[axis] * 16 > self.origin.minimum[axis];
        }
        var cones: [3]Cone = if (initial) node.cones else @splat(.{});
        var connected: u6 = if (initial) faces & node.initial.? else 0;
        for (0..6) |face| {
            if (node.incoming & faces & (@as(u6, 1) << @intCast(face)) == 0) continue;
            var openings = geometry.portals[face];
            node.entries[face / 2].restrict(&openings);
            var entry = Section.portalBounds(face, openings) orelse continue;
            for (0..3) |axis| {
                entry.minimum[axis] += at[axis] * 16;
                entry.maximum[axis] += at[axis] * 16;
            }
            for (node.cones, 0..) |cone, axis| {
                if (!cone.valid()) continue;
                const clipped = cone.clip(self.origin, entry, self.direction(axis));
                if (!clipped.valid()) continue;
                cones[axis].merge(clipped);
                connected |= faces;
            }
        }
        if (connected & self.allowed == 0) return;
        section.restrictPortals(&geometry.portals, node.incoming, &node.entries, self.octant, if (initial) self.localCamera(at) else null, ComponentBounds.init(geometry.bounds, faces, geometry.rectangular), &self.workspace);
        self.advancePortals(at, cones, connected & self.allowed, &geometry.portals, neighbors, section);
    }

    fn localCamera(self: *const Traversal, at: [3]i32) Bounds {
        var result: Bounds = undefined;
        for (0..3) |axis| {
            result.minimum[axis] = @max(0, self.origin.minimum[axis] - at[axis] * 16);
            result.maximum[axis] = @min(16, self.origin.maximum[axis] - at[axis] * 16);
            assert(result.minimum[axis] < result.maximum[axis]);
        }
        return result;
    }

    fn advancePortals(self: *Traversal, at: [3]i32, cones: [3]Cone, exits: u6, portals: *const [6][4]u64, neighbors: [6]?*const Section, section: *const Section) void {
        assert(exits & ~self.allowed == 0);
        for (0..6) |face| {
            if (exits & (@as(u6, 1) << @as(u3, @intCast(face))) == 0) continue;
            const axis = face / 2;
            const positive = face % 2 != 0;
            const node = &self.nodes[self.grid.index(at).?];
            // A source inside the section bypasses the boundary-to-boundary proof.
            if (node.initial == null and node.incoming != 0 and section.blocked_pairs[face] & node.incoming == node.incoming) continue;
            var next = at;
            next[axis] += if (positive) @as(i32, 1) else -1;
            const target = self.grid.index(next) orelse continue;
            var openings = portals[face];
            var local_portal = Section.portalBounds(face, openings) orelse continue;
            var portal = local_portal;
            for (0..3) |coordinate| {
                portal.minimum[coordinate] += at[coordinate] * 16;
                portal.maximum[coordinate] += at[coordinate] * 16;
            }
            var possible = false;
            var clipped: [3]Cone = undefined;
            var checked: usize = 0;
            while (checked < cones.len) {
                const coordinate = checked;
                checked += 1;
                const cone = cones[coordinate];
                clipped[coordinate] = if (cone.valid()) cone.clip(self.origin, portal, self.direction(coordinate)) else .{};
                if (clipped[coordinate].valid()) {
                    possible = true;
                    break;
                }
            }
            if (!possible) continue;
            const target_node = self.disclose(target);
            const adjacent = neighbors[face] orelse unreachable;
            if (adjacent.kind == .solid) continue;
            var unchanged = adjacent.kind == .air;
            if (!unchanged) {
                for (&openings, adjacent.faceWords(face ^ 1)) |*word, opposite| word.* &= opposite;
                unchanged = std.mem.eql(u64, &openings, &portals[face]);
                if (!unchanged) {
                    local_portal = Section.portalBounds(face, openings) orelse continue;
                    portal = local_portal;
                    for (0..3) |coordinate| {
                        portal.minimum[coordinate] += at[coordinate] * 16;
                        portal.maximum[coordinate] += at[coordinate] * 16;
                    }
                }
            }
            const entry = Entry.init(face, local_portal, openings);
            var connected = false;
            for (cones, 0..) |cone, coordinate| {
                if (!cone.valid()) continue;
                const value = if (unchanged and coordinate < checked) clipped[coordinate] else cone.clip(self.origin, portal, self.direction(coordinate));
                if (!value.valid()) continue;
                target_node.cones[coordinate].merge(value);
                connected = true;
            }
            if (!connected) continue;
            assert(!target_node.processed);
            if (target_node.incoming & (@as(u6, 1) << @intCast(face ^ 1)) == 0) target_node.entries[axis] = entry else target_node.entries[axis].merge(entry);
            target_node.incoming |= @as(u6, 1) << @as(u3, @intCast(face ^ 1));
            self.enqueue(target, self.bucket + 1);
        }
    }

    pub fn visible(self: *const Traversal, index: usize) bool {
        assert(index < self.grid.count());
        return self.nodes[index].generation == self.generation and self.nodes[index].visible;
    }

    fn disclose(self: *Traversal, index: usize) *Node {
        const node = &self.nodes[index];
        if (node.generation != self.generation) node.* = .{ .generation = self.generation };
        if (!node.visible) {
            assert(self.disclosed_count < self.disclosed.len);
            self.disclosed[self.disclosed_count] = index;
            self.disclosed_count += 1;
            node.visible = true;
        }
        return node;
    }
};

fn coordinates(index: u12) [3]i32 {
    return .{ index % 16, index / 256, index / 16 % 16 };
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
        section.build(&solid, &workspace);
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
        section.build(&solid, &workspace);
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
        section.build(&solid, &workspace);
        try std.testing.expectEqual(connected, section.connections);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)));
    };
}

test "interior barriers preserve straight passages at every endpoint height" {
    var workspace: Workspace = undefined;
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
        section.build(&solid, &workspace);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[axis * 2] & (@as(u6, 1) << @intCast(axis * 2 + 1)));
    };
}

test "face pair proofs reject bends in every orientation without changing connectivity" {
    var workspace: Workspace = undefined;
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
        section.build(&solid, &workspace);
        try std.testing.expect(section.connections[from] & (@as(u6, 1) << @intCast(to)) != 0);
        try std.testing.expect(section.blocked_pairs[from] & (@as(u6, 1) << @intCast(to)) != 0);
        try std.testing.expect(section.blocked_pairs[to] & (@as(u6, 1) << @intCast(from)) != 0);
    };
}

test "face pair proofs preserve independently carved straight rays between all faces" {
    var workspace: Workspace = undefined;
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
        section.build(&solid, &workspace);
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[from] & (@as(u6, 1) << @intCast(to)));
        try std.testing.expectEqual(@as(u6, 0), section.blocked_pairs[to] & (@as(u6, 1) << @intCast(from)));
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
    var bits: [64]u64 = @splat(0);
    for (0..16) |y| for (0..16) |z| {
        const index = localIndex(.{ 8, @intCast(y), @intCast(z) });
        bits[index / 64] |= @as(u64, 1) << @as(u6, @intCast(index % 64));
    };
    var section: Section = .{};
    section.build(&bits, &workspace);
    try std.testing.expectEqual(@as(u16, 2), section.components);
    try std.testing.expect(section.cached_partitions);
    try std.testing.expectEqual(@as(u6, 0), section.connections[0] & 2);
    try std.testing.expectEqual(@as(u6, 0), section.component(localIndex(.{ 2, 8, 8 }), &workspace).?.faces & 2);
    try std.testing.expectEqual(@as(u6, 0), section.component(localIndex(.{ 12, 8, 8 }), &workspace).?.faces & 1);
    try std.testing.expectEqualDeep(workspace.geometry(), section.partitions[1].geometry(&section));
}

test "interleaved boundary components retain exact flood traversal when rectangles cannot encode them" {
    var workspace: Workspace = undefined;
    var solid: [64]u64 = @splat(std.math.maxInt(u64));
    for (0..16) |x| for (1..15) |y| for (1..15) |z| {
        const ring = y == 1 or y == 14 or z == 1 or z == 14;
        const center = y >= 6 and y < 10 and z >= 6 and z < 10;
        if (!ring and !center) continue;
        const index = localIndex(.{ @intCast(x), @intCast(y), @intCast(z) });
        solid[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
    };
    var section: Section = .{};
    section.build(&solid, &workspace);
    try std.testing.expectEqual(@as(u16, 2), section.boundary_components);
    try std.testing.expect(!section.cached_partitions);
}

test "packed face extraction agrees with every scalar boundary cell on all axes" {
    var random = std.Random.DefaultPrng.init(0x9a1716);
    for (0..32) |_| {
        var section: Section = .{ .kind = .mixed };
        for (&section.solid) |*word| word.* = random.random().int(u64);
        for (0..6) |face| {
            const words = section.faceWords(face);
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

test "solid neighbor surfaces remain visible and sealed sections stop traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: Grid = .{ .minimum = .{ -2, -2, -2 }, .size = @splat(5) };
    const sections = try arena.allocator().alloc(Section, grid.count());
    var workspace: Workspace = undefined;
    const solid: [64]u64 = @splat(std.math.maxInt(u64));
    for (sections) |*section| section.build(&solid, &workspace);
    const source = grid.index(.{ 0, 0, 0 }).?;
    sections[source] = .{};
    var traversal = try Traversal.init(arena.allocator(), grid.size);
    traversal.begin(grid, .{ 0, 0, 0 }, 63, 0);
    var neighbors: [6]?*const Section = undefined;
    for (0..6) |face| {
        var at: [3]i32 = @splat(0);
        at[face / 2] = if (face % 2 == 0) -1 else 1;
        neighbors[face] = &sections[grid.index(at).?];
    }
    traversal.advance(&sections[source], neighbors);
    try std.testing.expectEqual(null, traversal.pending());
    var visible: usize = 0;
    for (0..grid.count()) |index| visible += @intFromBool(traversal.visible(index));
    try std.testing.expectEqual(@as(usize, 4), visible);
    try std.testing.expectEqual(@as(usize, 1), traversal.visits);
}

const Fixture = struct {
    grid: Grid,
    sections: []Section,
    traversal: Traversal,
    disclosed: []bool,
    workspace: Workspace = undefined,

    fn init(allocator: std.mem.Allocator, grid: Grid) !Fixture {
        var fixture: Fixture = .{ .grid = grid, .sections = try allocator.alloc(Section, grid.count()), .traversal = try .init(allocator, grid.size), .disclosed = try allocator.alloc(bool, grid.count()) };
        const solid: [64]u64 = @splat(std.math.maxInt(u64));
        for (fixture.sections) |*section| section.build(&solid, &fixture.workspace);
        return fixture;
    }

    fn set(self: *Fixture, point: [3]i32, solid: bool) void {
        const at: [3]i32 = .{ @divFloor(point[0], 16), @divFloor(point[1], 16), @divFloor(point[2], 16) };
        const index = localIndex(.{ @mod(point[0], 16), @mod(point[1], 16), @mod(point[2], 16) });
        const section = &self.sections[self.grid.index(at).?];
        const mask = @as(u64, 1) << @as(u6, @intCast(index % 64));
        section.solid[index / 64] = (section.solid[index / 64] & ~mask) | (mask * @intFromBool(solid));
    }

    fn run(self: *Fixture, source: [3]i32) void {
        for (self.sections) |*section| section.build(&section.solid, &self.workspace);
        const at: [3]i32 = .{ @divFloor(source[0], 16), @divFloor(source[1], 16), @divFloor(source[2], 16) };
        const section = &self.sections[self.grid.index(at).?];
        const component = section.component(localIndex(.{ @mod(source[0], 16), @mod(source[1], 16), @mod(source[2], 16) }), &self.workspace).?;
        @memset(self.disclosed, false);
        for (0..8) |octant| {
            self.traversal.begin(self.grid, at, component.faces, @intCast(octant));
            while (self.traversal.pending()) |index| {
                const position = self.grid.position(index);
                var neighbors: [6]?*const Section = @splat(null);
                for (0..6) |face| {
                    var neighbor = position;
                    neighbor[face / 2] += if (face % 2 == 0) @as(i32, -1) else 1;
                    if (self.grid.index(neighbor)) |other| neighbors[face] = &self.sections[other];
                }
                self.traversal.advance(&self.sections[index], neighbors);
            }
            for (self.traversal.disclosed[0..self.traversal.disclosed_count]) |index| self.disclosed[index] = true;
            assert(self.traversal.visits <= self.grid.count());
            assert(self.traversal.edges <= 3 * self.grid.count());
        }
    }

    fn visible(self: *const Fixture, at: [3]i32) bool {
        return self.disclosed[self.grid.index(at).?];
    }
};

test "straight tunnels disclose their far end and a turn does not flood the connected cave" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .{ .minimum = .{ -1, -1, -1 }, .size = .{ 9, 3, 9 } });
    for (0..7 * 16) |z| fixture.set(.{ 8, 8, @intCast(z) }, false);
    fixture.run(.{ 8, 8, 8 });
    try std.testing.expect(fixture.visible(.{ 0, 0, 6 }));
    try std.testing.expect(!fixture.visible(.{ 4, 0, 4 }));
    for (3 * 16 + 9..7 * 16) |z| fixture.set(.{ 8, 8, @intCast(z) }, true);
    for (8..7 * 16) |x| fixture.set(.{ @intCast(x), 8, 3 * 16 + 8 }, false);
    fixture.run(.{ 8, 8, 8 });
    try std.testing.expect(fixture.visible(.{ 0, 0, 3 }));
    try std.testing.expect(!fixture.visible(.{ 6, 0, 3 }));
}

test "a section bend hides its far side until an interior shortcut opens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .{ .minimum = .{ -1, 0, -1 }, .size = .{ 3, 1, 3 } });
    for (0..16) |x| for (8..10) |y| for (8..10) |z| fixture.set(.{ @as(i32, @intCast(x)) - 16, @intCast(y), @intCast(z) }, false);
    for (11..13) |x| for (8..10) |y| for (0..16) |z| fixture.set(.{ @intCast(x), @intCast(y), @as(i32, @intCast(z)) - 16 }, false);
    for ([_]bool{ false, true, false }) |shortcut| {
        for (0..13) |x| for (0..10) |z| for (8..10) |y| {
            const open = z >= 8 or x >= 11 or (shortcut and x > 0 and z > 0);
            fixture.set(.{ @intCast(x), @intCast(y), @intCast(z) }, !open);
        };
        fixture.run(.{ -8, 8, 8 });
        try std.testing.expect(fixture.visible(.{ 0, 0, 0 }));
        try std.testing.expectEqual(shortcut, fixture.visible(.{ 0, 0, -1 }));
    }
}

test "a sealed cavity stays confined to its section after independent neighboring sections are loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), .{ .minimum = .{ -2, -2, -2 }, .size = @splat(5) });
    for (4..12) |y| for (4..12) |z| for (4..12) |x| fixture.set(.{ @intCast(x), @intCast(y), @intCast(z) }, false);
    const air: [64]u64 = @splat(0);
    fixture.sections[fixture.grid.index(.{ -2, 1, 2 }).?].build(&air, &fixture.workspace);
    fixture.sections[fixture.grid.index(.{ 2, -1, -2 }).?].build(&air, &fixture.workspace);
    fixture.run(.{ 8, 8, 8 });
    var visible: usize = 0;
    for (0..fixture.grid.count()) |index| visible += @intFromBool(fixture.traversal.visible(index));
    try std.testing.expectEqual(@as(usize, 1), visible);
    try std.testing.expectEqual(@as(usize, 0), fixture.traversal.edges);
}

test "open sections form one continuous traversal with a linear operation bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: Grid = .{ .minimum = .{ -32, -4, -32 }, .size = .{ 65, 24, 65 } };
    var fixture = try Fixture.init(arena.allocator(), grid);
    @memset(fixture.sections, .{});
    fixture.run(.{ 8, 65, 8 });
    for (fixture.disclosed) |seen| try std.testing.expect(seen);
    try std.testing.expect(fixture.traversal.visits <= grid.count());
    const previous = fixture.traversal.nodes[0].generation;
    fixture.traversal.begin(grid, .{ 0, 4, 0 }, 0, 0);
    try std.testing.expectEqual(null, fixture.traversal.pending());
    try std.testing.expectEqual(@as(usize, 1), fixture.traversal.disclosed_count);
    try std.testing.expectEqual(previous, fixture.traversal.nodes[0].generation);
    try std.testing.expect(!fixture.traversal.visible(0));
}
