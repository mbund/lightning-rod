const std = @import("std");
const protocol_support = @import("protocol_support.zig");

// optionalNbt
.{ .native = .optionalNbt }

// previousMessages
error.Todo

// chunkBlockEntity
error.Todo

// entityMetadataItem
error.InvalidCompareTo

// entityMetadata
error.Todo

// switch
.{ .native = .fake }

// i16
.{ .native = .i16 }

// vec3f
.{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

// void
.{ .native = .void }

// array
.{ .native = .fake }

// ItemSoundHolder
error.Todo

// u16
.{ .native = .u16 }

// nbt
.{ .native = .nbt }

// registryEntryHolder
.{ .native = .registryEntryHolder }

// optvarint
.{ .native = .varint }

// bitflags
.{ .native = .bitflags }

// bitfield
.{ .native = .fake }

// packedChunkPos
.{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

// u8
.{ .native = .u8 }

// i32
.{ .native = .i32 }

// buffer
.{ .native = .buffer }

// tags
error.Todo

// varlong
.{ .native = .varlong }

// option
.{ .native = .option }

// soundSource
.{ .mapper = .{ .type = .varint, .mappings = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

// vec4f
.{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

// u64
.{ .native = .u64 }

// particleData
error.InvalidCompareTo

// minecraft_simple_recipe_format
.{ .container = .{ .fields = { .{ ... } } } }

// f32
.{ .native = .f32 }

// u32
.{ .native = .u32 }

// registryEntryHolderSet
.{ .native = .registryEntryHolderSet }

// position
error.Todo

// minecraft_smelting_format
error.Todo

// chat_session
error.Todo

// ingredient
error.Todo

// bool
.{ .native = .bool }

// restBuffer
.{ .native = .restBuffer }

// slot
.{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

// string
.{ .pstring = .{ .countType = .varint } }

// particle
error.Todo

// f64
.{ .native = .f64 }

// varint
.{ .native = .varint }

// i64
.{ .native = .i64 }

// ByteArray
error.Todo

// entityMetadataLoop
.{ .native = .entityMetadataLoop }

// UUID
.{ .native = .UUID }

// i8
.{ .native = .i8 }

// command_node
error.Todo

// ItemSoundEvent
error.Todo

// game_profile
error.Todo

// container
.{ .native = .fake }

// pstring
.{ .native = .pstring }

// vec3f64
.{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

// topBitSetTerminatedArray
.{ .native = .topBitSetTerminatedArray }


pub const handshaking = struct {
    pub const toServer = struct {
        // packet_set_protocol
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_legacy_server_list_ping
        .{ .container = .{ .fields = { .{ ... } } } }


    };
};

pub const status = struct {
    pub const toServer = struct {
        // packet_ping
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_ping_start
        .{ .container = .{ .fields = {  } } }

        // packet
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }


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
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_keep_alive
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_close_window
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_set_creative_slot
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_chat_command
        error.Todo

        // packet_look
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_update_structure_block
        error.Todo

        // packet_client_command
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_pong
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_use_entity
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet_position
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet_recipe_book
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_set_beacon_effect
        error.Todo

        // packet_name_item
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_custom_payload
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_lock_difficulty
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_vehicle_move
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet_flying
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_settings
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet_select_trade
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_update_command_block
        error.Todo

        // packet_update_command_block_minecart
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_set_difficulty
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_resource_pack_receive
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_query_block_nbt
        error.Todo

        // packet_advancement_tab
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_entity_action
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_block_place
        error.Todo

        // packet_window_click
        error.Todo

        // packet_teleport_confirm
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_enchant_item
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_steer_vehicle
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_edit_book
        error.Todo

        // packet_generate_structure
        error.Todo

        // packet_block_dig
        error.Todo

        // packet_arm_animation
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_tab_complete
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_use_item
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_craft_recipe_request
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }

        // packet_position_look
        .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } }

        // packet_abilities
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_query_entity_nbt
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_steer_boat
        .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }

        // packet_chat_message
        error.Todo

        // packet_chat_session_update
        error.Todo

        // packet_spectate
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_pick_item
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet
        error.Todo

        // packet_update_jigsaw_block
        error.Todo

        // packet_held_item_slot
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_message_acknowledgement
        .{ .container = .{ .fields = { .{ ... } } } }

        // packet_update_sign
        error.Todo


    };
};


