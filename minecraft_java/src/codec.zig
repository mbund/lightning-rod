const minecraft = @import("minecraft_model");
const chunks = @import("chunks.zig");

pub fn ChunkCodec(comptime game_data: type, comptime Wire: type, comptime Registry: type) type {
    return struct {
        pub fn write(packet: Wire.play.toClient.packet_map_chunk.Writer, value: minecraft.Chunk) ![]u8 {
            return chunks.encode(game_data, Registry, false, packet, value.x, value.z, value.sections, value.biome, value.minimum_section, value.skylight);
        }

        pub fn writeWithFluidCount(packet: Wire.play.toClient.packet_map_chunk.Writer, value: minecraft.Chunk) ![]u8 {
            return chunks.encode(game_data, Registry, true, packet, value.x, value.z, value.sections, value.biome, value.minimum_section, value.skylight);
        }
    };
}
