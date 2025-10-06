const std = @import("std");
const protocol_support = @import("protocol_support.zig");

// optionalNbt
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .optionalNbt }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// previousMessages
error.Todo

// chunkBlockEntity
error.Todo

// entityMetadataItem
error.InvalidCompareTo

// entityMetadata
error.Todo

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
error.Todo

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
error.Todo

// varlong
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varlong }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// option
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .option }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// soundSource
error.Todo

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
error.Todo

// minecraft_smelting_format
error.Todo

// chat_session
error.Todo

// ingredient
error.Todo

// bool
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bool }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// restBuffer
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .restBuffer }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// slot
error.Todo

// string
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// particle
error.Todo

// f64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// varint
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i64
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// ByteArray
error.Todo

// entityMetadataLoop
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .entityMetadataLoop }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// UUID
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .UUID }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// i8
.{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

// command_node
error.Todo

// ItemSoundEvent
error.Todo

// game_profile
error.Todo

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
        error.Todo

        // packet_legacy_server_list_ping
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }


    };
};

pub const status = struct {
    pub const toServer = struct {
        // packet_ping
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_ping_start
        error.Todo

        // packet
        error.Todo


    };
};

pub const login = struct {
    pub const toServer = struct {
        // packet_encryption_begin
        error.Todo

        // packet_login_start
        error.Todo

        // packet_login_plugin_response
        error.Todo

        // packet
        error.Todo


    };
};

pub const play = struct {
    pub const toServer = struct {
        // packet_displayed_recipe
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_keep_alive
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i64 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_close_window
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_set_creative_slot
        error.Todo

        // packet_chat_command
        error.Todo

        // packet_look
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f32 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_update_structure_block
        error.Todo

        // packet_client_command
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_pong
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i32 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_use_entity
        error.Todo

        // packet_position
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_recipe_book
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_set_beacon_effect
        error.Todo

        // packet_name_item
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_custom_payload
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_lock_difficulty
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bool }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_vehicle_move
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_flying
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bool }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_settings
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .pstring = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_select_trade
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_update_command_block
        error.Todo

        // packet_update_command_block_minecart
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_set_difficulty
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .u8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_resource_pack_receive
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_query_block_nbt
        error.Todo

        // packet_advancement_tab
        error.Todo

        // packet_entity_action
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_block_place
        error.Todo

        // packet_window_click
        error.Todo

        // packet_teleport_confirm
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_enchant_item
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i8 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_steer_vehicle
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f32 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_edit_book
        error.Todo

        // packet_generate_structure
        error.Todo

        // packet_block_dig
        error.Todo

        // packet_arm_animation
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_tab_complete
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_use_item
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_craft_recipe_request
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i8 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_position_look
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .f64 }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_abilities
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i8 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_query_entity_nbt
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_steer_boat
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .bool }, .next = .{ .always = .{ ... } } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_chat_message
        error.Todo

        // packet_chat_session_update
        error.Todo

        // packet_spectate
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .UUID }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_pick_item
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet
        error.Todo

        // packet_update_jigsaw_block
        error.Todo

        // packet_held_item_slot
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .i16 }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_message_acknowledgement
        .{ .head = .{ .name = { 67, 117, 114, 115, 111, 114 }, .readType = .{ .native = .varint }, .next = .{ .none = void } }, .tails = .{ .one = .{ .name = { ... }, .readType = .{ ... }, .next = .{ ... } } } }

        // packet_update_sign
        error.Todo


    };
};


