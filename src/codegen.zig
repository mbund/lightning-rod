const std = @import("std");
const protocol_support = @import("protocol_support.zig");

// optionalNbt
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .optionalNbt }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// previousMessages
error.Todo1

// chunkBlockEntity
error.Todo1

// entityMetadataItem
error.InvalidCompareTo

// entityMetadata
error.Todo1

// switch
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .fake }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i16
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i16 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// vec3f
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f32 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// void
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .void }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// array
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .fake }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// ItemSoundHolder
error.Todo1

// u16
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u16 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// nbt
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .nbt }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// registryEntryHolder
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .registryEntryHolder }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// optvarint
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// bitflags
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bitflags }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// bitfield
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .fake }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// packedChunkPos
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i32 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// u8
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i32
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i32 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// buffer
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .buffer }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// tags
error.Todo1

// varlong
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varlong }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// option
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .option }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// soundSource
error.Todo4

// vec4f
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f32 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// u64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// particleData
error.InvalidCompareTo

// minecraft_simple_recipe_format
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// f32
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f32 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// u32
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u32 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// registryEntryHolderSet
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .registryEntryHolderSet }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// position
error.Todo1

// minecraft_smelting_format
error.Todo1

// chat_session
error.Todo1

// ingredient
error.Todo1

// bool
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bool }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// restBuffer
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .restBuffer }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// slot
error.Todo2

// string
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// particle
error.Todo1

// f64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// varint
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// ByteArray
error.Todo1

// entityMetadataLoop
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .entityMetadataLoop }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// UUID
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .UUID }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i8
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// command_node
error.Todo1

// ItemSoundEvent
error.Todo1

// game_profile
error.Todo1

// container
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .fake }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// pstring
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .pstring }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// vec3f64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// topBitSetTerminatedArray
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .topBitSetTerminatedArray }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }


pub const handshaking = struct {
    pub const toServer = struct {
        // packet_set_protocol
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .switch_ = .{ ... } } }, .tails = .{ .many = .{ .items = { ... }, .capacity = 16 } } }

        // packet_legacy_server_list_ping
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }


    };
};


