const std = @import("std");
const protocol_support = @import("protocol_support.zig");

pub const handshaking = struct {
    pub const toServer = struct {
        pub fn read(buffer: []const u8) packet__name {
            return .{ .buffer = buffer };
        }

        pub const packet__name = struct {
            buffer: []const u8,

            pub fn name(self: @This()) !union(enum) {
                set_protocol: packet__set_protocol__params__protocolVersion,
                legacy_server_list_ping: packet__legacy_server_list_ping__params__payload,
                default: packet__params,
            } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return switch (value) {
                    0 => .{ .set_protocol = .{ .buffer = rest } },
                    254 => .{ .legacy_server_list_ping = .{ .buffer = rest } },
                    else => .{ .default = .{ .buffer = rest } },
                };
            }
        };

        pub const packet__set_protocol__params__protocolVersion = struct {
            buffer: []const u8,

            pub fn protocolVersion(self: @This()) !struct { i32, packet__set_protocol__params__serverHost } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__set_protocol__params__serverHost = struct {
            buffer: []const u8,

            pub fn serverHost(self: @This()) !struct { []const u8, packet__set_protocol__params__serverPort } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__set_protocol__params__serverPort = struct {
            buffer: []const u8,

            pub fn serverPort(self: @This()) !struct { u16, packet__set_protocol__params__nextState } {
                const value, const rest = try protocol_support.read_u16(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__set_protocol__params__nextState = struct {
            buffer: []const u8,

            pub fn nextState(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__legacy_server_list_ping__params__payload = struct {
            buffer: []const u8,

            pub fn payload(self: @This()) !struct { u8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) !struct { protocol_support.void, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_void(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
    };
};

pub const status = struct {
    pub const toServer = struct {
        pub fn read(buffer: []const u8) packet__name {
            return .{ .buffer = buffer };
        }

        pub const packet__name = struct {
            buffer: []const u8,

            pub fn name(self: @This()) !union(enum) {
                ping_start: packet__ping_start__params,
                ping: packet__ping__params__time,
                default: packet__params,
            } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return switch (value) {
                    0 => .{ .ping_start = .{ .buffer = rest } },
                    1 => .{ .ping = .{ .buffer = rest } },
                    else => .{ .default = .{ .buffer = rest } },
                };
            }
        };

        pub const packet__ping_start__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__ping__params__time = struct {
            buffer: []const u8,

            pub fn time(self: @This()) !struct { i64, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) !struct { protocol_support.void, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_void(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
    };
};

pub const login = struct {
    pub const toServer = struct {
        pub fn read(buffer: []const u8) packet__name {
            return .{ .buffer = buffer };
        }

        pub const packet__name = struct {
            buffer: []const u8,

            pub fn name(self: @This()) !union(enum) {
                login_start: packet__login_start__params__username,
                encryption_begin: packet__encryption_begin__params__sharedSecret,
                login_plugin_response: packet__login_plugin_response__params__messageId,
                default: packet__params,
            } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return switch (value) {
                    0 => .{ .login_start = .{ .buffer = rest } },
                    1 => .{ .encryption_begin = .{ .buffer = rest } },
                    2 => .{ .login_plugin_response = .{ .buffer = rest } },
                    else => .{ .default = .{ .buffer = rest } },
                };
            }
        };

        pub const packet__login_start__params__username = struct {
            buffer: []const u8,

            pub fn username(self: @This()) !struct { []const u8, packet__login_start__params__playerUUID } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__login_start__params__playerUUID = struct {
            buffer: []const u8,

            pub fn playerUUID(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__encryption_begin__params__sharedSecret = struct {
            buffer: []const u8,

            pub fn sharedSecret(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__login_plugin_response__params__messageId = struct {
            buffer: []const u8,

            pub fn messageId(self: @This()) !struct { i32, packet__login_plugin_response__params__data } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__login_plugin_response__params__data = struct {
            buffer: []const u8,

            pub fn data(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) !struct { protocol_support.void, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_void(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
    };
};

pub const play = struct {
    pub const toServer = struct {
        pub fn read(buffer: []const u8) packet__name {
            return .{ .buffer = buffer };
        }

        pub const packet__name = struct {
            buffer: []const u8,

            pub fn name(self: @This()) !union(enum) {
                teleport_confirm: packet__teleport_confirm__params__teleportId,
                query_block_nbt: packet__query_block_nbt__params__transactionId,
                set_difficulty: packet__set_difficulty__params__newDifficulty,
                message_acknowledgement: packet__message_acknowledgement__params__count,
                chat_command: packet__chat_command__params__command,
                chat_message: packet__chat_message__params__message,
                chat_session_update: packet__chat_session_update__params__sessionUUID,
                client_command: packet__client_command__params__actionId,
                settings: packet__settings__params__locale,
                tab_complete: packet__tab_complete__params__transactionId,
                enchant_item: packet__enchant_item__params__windowId,
                window_click: packet__window_click__params__windowId,
                close_window: packet__close_window__params__windowId,
                custom_payload: packet__custom_payload__params__channel,
                edit_book: packet__edit_book__params__hand,
                query_entity_nbt: packet__query_entity_nbt__params__transactionId,
                use_entity: packet__use_entity__params__target,
                generate_structure: packet__generate_structure__params__location,
                keep_alive: packet__keep_alive__params__keepAliveId,
                lock_difficulty: packet__lock_difficulty__params__locked,
                position: packet__position__params__x,
                position_look: packet__position_look__params__x,
                look: packet__look__params__yaw,
                flying: packet__flying__params__onGround,
                vehicle_move: packet__vehicle_move__params__x,
                steer_boat: packet__steer_boat__params__leftPaddle,
                pick_item: packet__pick_item__params__slot,
                craft_recipe_request: packet__craft_recipe_request__params__windowId,
                abilities: packet__abilities__params__flags,
                block_dig: packet__block_dig__params__status,
                entity_action: packet__entity_action__params__entityId,
                steer_vehicle: packet__steer_vehicle__params__sideways,
                pong: packet__pong__params__id,
                recipe_book: packet__recipe_book__params__bookId,
                displayed_recipe: packet__displayed_recipe__params__recipeId,
                name_item: packet__name_item__params__name,
                resource_pack_receive: packet__resource_pack_receive__params__result,
                advancement_tab: packet__advancement_tab__params,
                select_trade: packet__select_trade__params__slot,
                set_beacon_effect: packet__set_beacon_effect__params__primary_effect,
                held_item_slot: packet__held_item_slot__params__slotId,
                update_command_block: packet__update_command_block__params__location,
                update_command_block_minecart: packet__update_command_block_minecart__params__entityId,
                set_creative_slot: packet__set_creative_slot__params__slot,
                update_jigsaw_block: packet__update_jigsaw_block__params__location,
                update_structure_block: packet__update_structure_block__params__location,
                update_sign: packet__update_sign__params__location,
                arm_animation: packet__arm_animation__params__hand,
                spectate: packet__spectate__params__target,
                block_place: packet__block_place__params__hand,
                use_item: packet__use_item__params__hand,
                default: packet__params,
            } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return switch (value) {
                    0 => .{ .teleport_confirm = .{ .buffer = rest } },
                    1 => .{ .query_block_nbt = .{ .buffer = rest } },
                    2 => .{ .set_difficulty = .{ .buffer = rest } },
                    3 => .{ .message_acknowledgement = .{ .buffer = rest } },
                    4 => .{ .chat_command = .{ .buffer = rest } },
                    5 => .{ .chat_message = .{ .buffer = rest } },
                    6 => .{ .chat_session_update = .{ .buffer = rest } },
                    7 => .{ .client_command = .{ .buffer = rest } },
                    8 => .{ .settings = .{ .buffer = rest } },
                    9 => .{ .tab_complete = .{ .buffer = rest } },
                    10 => .{ .enchant_item = .{ .buffer = rest } },
                    11 => .{ .window_click = .{ .buffer = rest } },
                    12 => .{ .close_window = .{ .buffer = rest } },
                    13 => .{ .custom_payload = .{ .buffer = rest } },
                    14 => .{ .edit_book = .{ .buffer = rest } },
                    15 => .{ .query_entity_nbt = .{ .buffer = rest } },
                    16 => .{ .use_entity = .{ .buffer = rest } },
                    17 => .{ .generate_structure = .{ .buffer = rest } },
                    18 => .{ .keep_alive = .{ .buffer = rest } },
                    19 => .{ .lock_difficulty = .{ .buffer = rest } },
                    20 => .{ .position = .{ .buffer = rest } },
                    21 => .{ .position_look = .{ .buffer = rest } },
                    22 => .{ .look = .{ .buffer = rest } },
                    23 => .{ .flying = .{ .buffer = rest } },
                    24 => .{ .vehicle_move = .{ .buffer = rest } },
                    25 => .{ .steer_boat = .{ .buffer = rest } },
                    26 => .{ .pick_item = .{ .buffer = rest } },
                    27 => .{ .craft_recipe_request = .{ .buffer = rest } },
                    28 => .{ .abilities = .{ .buffer = rest } },
                    29 => .{ .block_dig = .{ .buffer = rest } },
                    30 => .{ .entity_action = .{ .buffer = rest } },
                    31 => .{ .steer_vehicle = .{ .buffer = rest } },
                    32 => .{ .pong = .{ .buffer = rest } },
                    33 => .{ .recipe_book = .{ .buffer = rest } },
                    34 => .{ .displayed_recipe = .{ .buffer = rest } },
                    35 => .{ .name_item = .{ .buffer = rest } },
                    36 => .{ .resource_pack_receive = .{ .buffer = rest } },
                    37 => .{ .advancement_tab = .{ .buffer = rest } },
                    38 => .{ .select_trade = .{ .buffer = rest } },
                    39 => .{ .set_beacon_effect = .{ .buffer = rest } },
                    40 => .{ .held_item_slot = .{ .buffer = rest } },
                    41 => .{ .update_command_block = .{ .buffer = rest } },
                    42 => .{ .update_command_block_minecart = .{ .buffer = rest } },
                    43 => .{ .set_creative_slot = .{ .buffer = rest } },
                    44 => .{ .update_jigsaw_block = .{ .buffer = rest } },
                    45 => .{ .update_structure_block = .{ .buffer = rest } },
                    46 => .{ .update_sign = .{ .buffer = rest } },
                    47 => .{ .arm_animation = .{ .buffer = rest } },
                    48 => .{ .spectate = .{ .buffer = rest } },
                    49 => .{ .block_place = .{ .buffer = rest } },
                    50 => .{ .use_item = .{ .buffer = rest } },
                    else => .{ .default = .{ .buffer = rest } },
                };
            }
        };

        pub const packet__teleport_confirm__params__teleportId = struct {
            buffer: []const u8,

            pub fn teleportId(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__query_block_nbt__params__transactionId = struct {
            buffer: []const u8,

            pub fn transactionId(self: @This()) !struct { i32, packet__query_block_nbt__params__location } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__query_block_nbt__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__set_difficulty__params__newDifficulty = struct {
            buffer: []const u8,

            pub fn newDifficulty(self: @This()) !struct { u8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__message_acknowledgement__params__count = struct {
            buffer: []const u8,

            pub fn count(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_command__params__command = struct {
            buffer: []const u8,

            pub fn command(self: @This()) !struct { []const u8, packet__chat_command__params__timestamp } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__chat_command__params__timestamp = struct {
            buffer: []const u8,

            pub fn timestamp(self: @This()) !struct { i64, packet__chat_command__params__salt } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_command__params__salt = struct {
            buffer: []const u8,

            pub fn salt(self: @This()) !struct { i64, packet__chat_command__params__argumentSignatures } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_command__params__argumentSignatures = struct {
            buffer: []const u8,

            pub fn argumentSignatures(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__chat_message__params__message = struct {
            buffer: []const u8,

            pub fn message(self: @This()) !struct { []const u8, packet__chat_message__params__timestamp } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__chat_message__params__timestamp = struct {
            buffer: []const u8,

            pub fn timestamp(self: @This()) !struct { i64, packet__chat_message__params__salt } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_message__params__salt = struct {
            buffer: []const u8,

            pub fn salt(self: @This()) !struct { i64, packet__chat_message__params__signature } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_message__params__signature = struct {
            buffer: []const u8,

            pub fn signature(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__chat_session_update__params__sessionUUID = struct {
            buffer: []const u8,

            pub fn sessionUUID(self: @This()) !struct { protocol_support.UUID, packet__chat_session_update__params__expireTime } {
                const value, const rest = try protocol_support.read_UUID(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_session_update__params__expireTime = struct {
            buffer: []const u8,

            pub fn expireTime(self: @This()) !struct { i64, packet__chat_session_update__params__publicKey } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__chat_session_update__params__publicKey = struct {
            buffer: []const u8,

            pub fn publicKey(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__client_command__params__actionId = struct {
            buffer: []const u8,

            pub fn actionId(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__locale = struct {
            buffer: []const u8,

            pub fn locale(self: @This()) !struct { []const u8, packet__settings__params__viewDistance } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__settings__params__viewDistance = struct {
            buffer: []const u8,

            pub fn viewDistance(self: @This()) !struct { i8, packet__settings__params__chatFlags } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__chatFlags = struct {
            buffer: []const u8,

            pub fn chatFlags(self: @This()) !struct { i32, packet__settings__params__chatColors } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__chatColors = struct {
            buffer: []const u8,

            pub fn chatColors(self: @This()) !struct { bool, packet__settings__params__skinParts } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__skinParts = struct {
            buffer: []const u8,

            pub fn skinParts(self: @This()) !struct { u8, packet__settings__params__mainHand } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__mainHand = struct {
            buffer: []const u8,

            pub fn mainHand(self: @This()) !struct { i32, packet__settings__params__enableTextFiltering } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__enableTextFiltering = struct {
            buffer: []const u8,

            pub fn enableTextFiltering(self: @This()) !struct { bool, packet__settings__params__enableServerListing } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__settings__params__enableServerListing = struct {
            buffer: []const u8,

            pub fn enableServerListing(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__tab_complete__params__transactionId = struct {
            buffer: []const u8,

            pub fn transactionId(self: @This()) !struct { i32, packet__tab_complete__params__text } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__tab_complete__params__text = struct {
            buffer: []const u8,

            pub fn text(self: @This()) !struct { []const u8, protocol_support.FinalCursor } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__enchant_item__params__windowId = struct {
            buffer: []const u8,

            pub fn windowId(self: @This()) !struct { i8, packet__enchant_item__params__enchantment } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__enchant_item__params__enchantment = struct {
            buffer: []const u8,

            pub fn enchantment(self: @This()) !struct { i8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__windowId = struct {
            buffer: []const u8,

            pub fn windowId(self: @This()) !struct { u8, packet__window_click__params__stateId } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__stateId = struct {
            buffer: []const u8,

            pub fn stateId(self: @This()) !struct { i32, packet__window_click__params__slot } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__slot = struct {
            buffer: []const u8,

            pub fn slot(self: @This()) !struct { i16, packet__window_click__params__mouseButton } {
                const value, const rest = try protocol_support.read_i16(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__mouseButton = struct {
            buffer: []const u8,

            pub fn mouseButton(self: @This()) !struct { i8, packet__window_click__params__mode } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__mode = struct {
            buffer: []const u8,

            pub fn mode(self: @This()) !struct { i32, packet__window_click__params__changedSlots } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__window_click__params__changedSlots = struct {
            buffer: []const u8,

            pub fn changedSlots(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__close_window__params__windowId = struct {
            buffer: []const u8,

            pub fn windowId(self: @This()) !struct { u8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__custom_payload__params__channel = struct {
            buffer: []const u8,

            pub fn channel(self: @This()) !struct { []const u8, packet__custom_payload__params__data } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__custom_payload__params__data = struct {
            buffer: []const u8,

            pub fn data(self: @This()) !struct { protocol_support.restBuffer, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_restBuffer(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__edit_book__params__hand = struct {
            buffer: []const u8,

            pub fn hand(self: @This()) !struct { i32, packet__edit_book__params__pages } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__edit_book__params__pages = struct {
            buffer: []const u8,

            pub fn pages(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__query_entity_nbt__params__transactionId = struct {
            buffer: []const u8,

            pub fn transactionId(self: @This()) !struct { i32, packet__query_entity_nbt__params__entityId } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__query_entity_nbt__params__entityId = struct {
            buffer: []const u8,

            pub fn entityId(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__use_entity__params__target = struct {
            buffer: []const u8,

            pub fn target(self: @This()) !struct { i32, packet__use_entity__params } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__use_entity__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__generate_structure__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__keep_alive__params__keepAliveId = struct {
            buffer: []const u8,

            pub fn keepAliveId(self: @This()) !struct { i64, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__lock_difficulty__params__locked = struct {
            buffer: []const u8,

            pub fn locked(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position__params__x = struct {
            buffer: []const u8,

            pub fn x(self: @This()) !struct { f64, packet__position__params__y } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position__params__y = struct {
            buffer: []const u8,

            pub fn y(self: @This()) !struct { f64, packet__position__params__z } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position__params__z = struct {
            buffer: []const u8,

            pub fn z(self: @This()) !struct { f64, packet__position__params__onGround } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position__params__onGround = struct {
            buffer: []const u8,

            pub fn onGround(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__x = struct {
            buffer: []const u8,

            pub fn x(self: @This()) !struct { f64, packet__position_look__params__y } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__y = struct {
            buffer: []const u8,

            pub fn y(self: @This()) !struct { f64, packet__position_look__params__z } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__z = struct {
            buffer: []const u8,

            pub fn z(self: @This()) !struct { f64, packet__position_look__params__yaw } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__yaw = struct {
            buffer: []const u8,

            pub fn yaw(self: @This()) !struct { f32, packet__position_look__params__pitch } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__pitch = struct {
            buffer: []const u8,

            pub fn pitch(self: @This()) !struct { f32, packet__position_look__params__onGround } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__position_look__params__onGround = struct {
            buffer: []const u8,

            pub fn onGround(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__look__params__yaw = struct {
            buffer: []const u8,

            pub fn yaw(self: @This()) !struct { f32, packet__look__params__pitch } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__look__params__pitch = struct {
            buffer: []const u8,

            pub fn pitch(self: @This()) !struct { f32, packet__look__params__onGround } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__look__params__onGround = struct {
            buffer: []const u8,

            pub fn onGround(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__flying__params__onGround = struct {
            buffer: []const u8,

            pub fn onGround(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__vehicle_move__params__x = struct {
            buffer: []const u8,

            pub fn x(self: @This()) !struct { f64, packet__vehicle_move__params__y } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__vehicle_move__params__y = struct {
            buffer: []const u8,

            pub fn y(self: @This()) !struct { f64, packet__vehicle_move__params__z } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__vehicle_move__params__z = struct {
            buffer: []const u8,

            pub fn z(self: @This()) !struct { f64, packet__vehicle_move__params__yaw } {
                const value, const rest = try protocol_support.read_f64(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__vehicle_move__params__yaw = struct {
            buffer: []const u8,

            pub fn yaw(self: @This()) !struct { f32, packet__vehicle_move__params__pitch } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__vehicle_move__params__pitch = struct {
            buffer: []const u8,

            pub fn pitch(self: @This()) !struct { f32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__steer_boat__params__leftPaddle = struct {
            buffer: []const u8,

            pub fn leftPaddle(self: @This()) !struct { bool, packet__steer_boat__params__rightPaddle } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__steer_boat__params__rightPaddle = struct {
            buffer: []const u8,

            pub fn rightPaddle(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__pick_item__params__slot = struct {
            buffer: []const u8,

            pub fn slot(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__craft_recipe_request__params__windowId = struct {
            buffer: []const u8,

            pub fn windowId(self: @This()) !struct { i8, packet__craft_recipe_request__params__recipe } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__craft_recipe_request__params__recipe = struct {
            buffer: []const u8,

            pub fn recipe(self: @This()) !struct { []const u8, packet__craft_recipe_request__params__makeAll } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__craft_recipe_request__params__makeAll = struct {
            buffer: []const u8,

            pub fn makeAll(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__abilities__params__flags = struct {
            buffer: []const u8,

            pub fn flags(self: @This()) !struct { i8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__block_dig__params__status = struct {
            buffer: []const u8,

            pub fn status(self: @This()) !struct { i32, packet__block_dig__params__location } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__block_dig__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__entity_action__params__entityId = struct {
            buffer: []const u8,

            pub fn entityId(self: @This()) !struct { i32, packet__entity_action__params__actionId } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__entity_action__params__actionId = struct {
            buffer: []const u8,

            pub fn actionId(self: @This()) !struct { i32, packet__entity_action__params__jumpBoost } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__entity_action__params__jumpBoost = struct {
            buffer: []const u8,

            pub fn jumpBoost(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__steer_vehicle__params__sideways = struct {
            buffer: []const u8,

            pub fn sideways(self: @This()) !struct { f32, packet__steer_vehicle__params__forward } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__steer_vehicle__params__forward = struct {
            buffer: []const u8,

            pub fn forward(self: @This()) !struct { f32, packet__steer_vehicle__params__jump } {
                const value, const rest = try protocol_support.read_f32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__steer_vehicle__params__jump = struct {
            buffer: []const u8,

            pub fn jump(self: @This()) !struct { u8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__pong__params__id = struct {
            buffer: []const u8,

            pub fn id(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i32(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__recipe_book__params__bookId = struct {
            buffer: []const u8,

            pub fn bookId(self: @This()) !struct { i32, packet__recipe_book__params__bookOpen } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__recipe_book__params__bookOpen = struct {
            buffer: []const u8,

            pub fn bookOpen(self: @This()) !struct { bool, packet__recipe_book__params__filterActive } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__recipe_book__params__filterActive = struct {
            buffer: []const u8,

            pub fn filterActive(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__displayed_recipe__params__recipeId = struct {
            buffer: []const u8,

            pub fn recipeId(self: @This()) !struct { []const u8, protocol_support.FinalCursor } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__name_item__params__name = struct {
            buffer: []const u8,

            pub fn name(self: @This()) !struct { []const u8, protocol_support.FinalCursor } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__resource_pack_receive__params__result = struct {
            buffer: []const u8,

            pub fn result(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__advancement_tab__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__select_trade__params__slot = struct {
            buffer: []const u8,

            pub fn slot(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__set_beacon_effect__params__primary_effect = struct {
            buffer: []const u8,

            pub fn primary_effect(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__held_item_slot__params__slotId = struct {
            buffer: []const u8,

            pub fn slotId(self: @This()) !struct { i16, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_i16(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__update_command_block__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__update_command_block_minecart__params__entityId = struct {
            buffer: []const u8,

            pub fn entityId(self: @This()) !struct { i32, packet__update_command_block_minecart__params__command } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__update_command_block_minecart__params__command = struct {
            buffer: []const u8,

            pub fn command(self: @This()) !struct { []const u8, packet__update_command_block_minecart__params__track_output } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                const size: usize = @intCast(length);
                return .{ rest[0..size], .{ .buffer = rest[size..] } };
            }
        };

        pub const packet__update_command_block_minecart__params__track_output = struct {
            buffer: []const u8,

            pub fn track_output(self: @This()) !struct { bool, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_bool(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__set_creative_slot__params__slot = struct {
            buffer: []const u8,

            pub fn slot(self: @This()) !struct { i16, packet__set_creative_slot__params__item } {
                const value, const rest = try protocol_support.read_i16(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__set_creative_slot__params__item = struct {
            buffer: []const u8,

            pub fn item(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__update_jigsaw_block__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__update_structure_block__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__update_sign__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__arm_animation__params__hand = struct {
            buffer: []const u8,

            pub fn hand(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__spectate__params__target = struct {
            buffer: []const u8,

            pub fn target(self: @This()) !struct { protocol_support.UUID, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_UUID(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__block_place__params__hand = struct {
            buffer: []const u8,

            pub fn hand(self: @This()) !struct { i32, packet__block_place__params__location } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__block_place__params__location = struct {
            buffer: []const u8,

            pub fn location(self: @This()) noreturn {
                _ = self;
                @panic("todo");
            }
        };
        pub const packet__use_item__params__hand = struct {
            buffer: []const u8,

            pub fn hand(self: @This()) !struct { i32, packet__use_item__params__sequence } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__use_item__params__sequence = struct {
            buffer: []const u8,

            pub fn sequence(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };

        pub const packet__params = struct {
            buffer: []const u8,

            pub fn params(self: @This()) !struct { protocol_support.void, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_void(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
    };
};
