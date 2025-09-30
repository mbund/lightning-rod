const codegen_support = @import("codegen_support.zig");
const codegen = @This();
pub const varint = codegen_support.varint;
pub const varlong = codegen_support.varlong;
pub const optvarint = codegen.varint;
pub const pstring = codegen_support.pstring;
pub const buffer = codegen_support.buffer;
pub const @"u8" = codegen_support.@"u8";
pub const @"u16" = codegen_support.@"u16";
pub const @"u32" = codegen_support.@"u32";
pub const @"u64" = codegen_support.@"u64";
pub const @"i8" = codegen_support.@"i8";
pub const @"i16" = codegen_support.@"i16";
pub const @"i32" = codegen_support.@"i32";
pub const @"i64" = codegen_support.@"i64";
pub const @"bool" = codegen_support.@"bool";
pub const @"f32" = codegen_support.@"f32";
pub const @"f64" = codegen_support.@"f64";
pub const UUID = codegen_support.UUID;
pub const option = codegen_support.option;
pub const entityMetadataLoop = codegen_support.entityMetadataLoop;
pub const topBitSetTerminatedArray = codegen_support.topBitSetTerminatedArray;
pub const bitfield = codegen_support.bitfield;
pub const bitflags = codegen_support.bitflags;
pub const container = codegen_support.container;
pub const @"switch" = codegen_support.@"switch";
pub const @"void" = codegen_support.@"void";
pub const array = codegen_support.array;
pub const restBuffer = codegen_support.restBuffer;
pub const nbt = codegen_support.nbt;
pub const optionalNbt = codegen_support.optionalNbt;
pub const registryEntryHolder = codegen_support.registryEntryHolder;
pub const registryEntryHolderSet = codegen_support.registryEntryHolderSet;
pub const ByteArray = "<buffer>";
pub const string = "<pstring>";
pub const vec3f = struct {
    x: codegen.@"f32",
    y: codegen.@"f32",
    z: codegen.@"f32",
};
pub const vec4f = struct {
    x: codegen.@"f32",
    y: codegen.@"f32",
    z: codegen.@"f32",
    w: codegen.@"f32",
};
pub const vec3f64 = struct {
    x: codegen.@"f64",
    y: codegen.@"f64",
    z: codegen.@"f64",
};
pub const ItemSoundEvent = struct {
    soundName: codegen.string,
    fixedRange: "<option>",
};
pub const ItemSoundHolder = "<registryEntryHolder>";
pub const slot = struct {
    present: codegen.@"bool",
    anon: "<switch>",
};
pub const particle = struct {
    particleId: codegen.varint,
    data: "<particleData>",
};
pub const particleData = "<switch>";
pub const ingredient = "<array>";
pub const position = "<bitfield>";
pub const packedChunkPos = struct {
    z: codegen.@"i32",
    x: codegen.@"i32",
};
pub const soundSource = "<mapper>";
pub const previousMessages = "<array>";
pub const entityMetadataItem = "<switch>";
pub const entityMetadata = "<entityMetadataLoop>";
pub const minecraft_simple_recipe_format = struct {
    category: codegen.varint,
};
pub const minecraft_smelting_format = struct {
    group: codegen.string,
    category: codegen.varint,
    ingredient: codegen.ingredient,
    result: codegen.slot,
    experience: codegen.@"f32",
    cookTime: codegen.varint,
};
pub const tags = "<array>";
pub const chunkBlockEntity = struct {
    anon: "<bitfield>",
    y: codegen.@"i16",
    type: codegen.varint,
    nbtData: codegen.optionalNbt,
};
pub const chat_session = "<option>";
pub const game_profile = struct {
    name: codegen.string,
    properties: "<array>",
};
pub const command_node = struct {
    flags: "<bitfield>",
    children: "<array>",
    redirectNode: "<switch>",
    extraNodeData: "<switch>",
};
pub const handshaking = struct {
    pub const toClient = struct {
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
    pub const toServer = struct {
        pub const packet_set_protocol = struct {
            protocolVersion: codegen.varint,
            serverHost: codegen.string,
            serverPort: codegen.@"u16",
            nextState: codegen.varint,
        };
        pub const packet_legacy_server_list_ping = struct {
            payload: codegen.@"u8",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
};
pub const status = struct {
    pub const toClient = struct {
        pub const packet_server_info = struct {
            response: codegen.string,
        };
        pub const packet_ping = struct {
            time: codegen.@"i64",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
    pub const toServer = struct {
        pub const packet_ping_start = struct {
        };
        pub const packet_ping = struct {
            time: codegen.@"i64",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
};
pub const login = struct {
    pub const toClient = struct {
        pub const packet_disconnect = struct {
            reason: codegen.string,
        };
        pub const packet_encryption_begin = struct {
            serverId: codegen.string,
            publicKey: "<buffer>",
            verifyToken: "<buffer>",
        };
        pub const packet_success = struct {
            uuid: codegen.UUID,
            username: codegen.string,
            properties: "<array>",
        };
        pub const packet_compress = struct {
            threshold: codegen.varint,
        };
        pub const packet_login_plugin_request = struct {
            messageId: codegen.varint,
            channel: codegen.string,
            data: codegen.restBuffer,
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
    pub const toServer = struct {
        pub const packet_login_start = struct {
            username: codegen.string,
            playerUUID: "<option>",
        };
        pub const packet_encryption_begin = struct {
            sharedSecret: "<buffer>",
            verifyToken: "<buffer>",
        };
        pub const packet_login_plugin_response = struct {
            messageId: codegen.varint,
            data: "<option>",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
};
pub const play = struct {
    pub const toClient = struct {
        pub const packet_spawn_entity = struct {
            entityId: codegen.varint,
            objectUUID: codegen.UUID,
            type: codegen.varint,
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            pitch: codegen.@"i8",
            yaw: codegen.@"i8",
            headPitch: codegen.@"i8",
            objectData: codegen.varint,
            velocityX: codegen.@"i16",
            velocityY: codegen.@"i16",
            velocityZ: codegen.@"i16",
        };
        pub const packet_spawn_entity_experience_orb = struct {
            entityId: codegen.varint,
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            count: codegen.@"i16",
        };
        pub const packet_named_entity_spawn = struct {
            entityId: codegen.varint,
            playerUUID: codegen.UUID,
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"i8",
            pitch: codegen.@"i8",
        };
        pub const packet_animation = struct {
            entityId: codegen.varint,
            animation: codegen.@"u8",
        };
        pub const packet_statistics = struct {
            entries: "<array>",
        };
        pub const packet_advancements = struct {
            reset: codegen.@"bool",
            advancementMapping: "<array>",
            identifiers: "<array>",
            progressMapping: "<array>",
        };
        pub const packet_block_break_animation = struct {
            entityId: codegen.varint,
            location: codegen.position,
            destroyStage: codegen.@"i8",
        };
        pub const packet_tile_entity_data = struct {
            location: codegen.position,
            action: codegen.varint,
            nbtData: codegen.optionalNbt,
        };
        pub const packet_block_action = struct {
            location: codegen.position,
            byte1: codegen.@"u8",
            byte2: codegen.@"u8",
            blockId: codegen.varint,
        };
        pub const packet_block_change = struct {
            location: codegen.position,
            type: codegen.varint,
        };
        pub const packet_boss_bar = struct {
            entityUUID: codegen.UUID,
            action: codegen.varint,
            title: "<switch>",
            health: "<switch>",
            color: "<switch>",
            dividers: "<switch>",
            flags: "<switch>",
        };
        pub const packet_difficulty = struct {
            difficulty: codegen.@"u8",
            difficultyLocked: codegen.@"bool",
        };
        pub const packet_tab_complete = struct {
            transactionId: codegen.varint,
            start: codegen.varint,
            length: codegen.varint,
            matches: "<array>",
        };
        pub const packet_declare_commands = struct {
            nodes: "<array>",
            rootIndex: codegen.varint,
        };
        pub const packet_face_player = struct {
            feet_eyes: codegen.varint,
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            isEntity: codegen.@"bool",
            entityId: "<switch>",
            entity_feet_eyes: "<switch>",
        };
        pub const packet_nbt_query_response = struct {
            transactionId: codegen.varint,
            nbt: codegen.optionalNbt,
        };
        pub const packet_multi_block_change = struct {
            chunkCoordinates: "<bitfield>",
            records: "<array>",
        };
        pub const packet_close_window = struct {
            windowId: codegen.@"u8",
        };
        pub const packet_open_window = struct {
            windowId: codegen.varint,
            inventoryType: codegen.varint,
            windowTitle: codegen.string,
        };
        pub const packet_window_items = struct {
            windowId: codegen.@"u8",
            stateId: codegen.varint,
            items: "<array>",
            carriedItem: codegen.slot,
        };
        pub const packet_craft_progress_bar = struct {
            windowId: codegen.@"u8",
            property: codegen.@"i16",
            value: codegen.@"i16",
        };
        pub const packet_set_slot = struct {
            windowId: codegen.@"i8",
            stateId: codegen.varint,
            slot: codegen.@"i16",
            item: codegen.slot,
        };
        pub const packet_set_cooldown = struct {
            itemID: codegen.varint,
            cooldownTicks: codegen.varint,
        };
        pub const packet_chat_suggestions = struct {
            action: codegen.varint,
            entries: "<array>",
        };
        pub const packet_custom_payload = struct {
            channel: codegen.string,
            data: codegen.restBuffer,
        };
        pub const packet_hide_message = struct {
            id: codegen.varint,
            signature: "<switch>",
        };
        pub const packet_kick_disconnect = struct {
            reason: codegen.string,
        };
        pub const packet_profileless_chat = struct {
            message: codegen.string,
            type: codegen.varint,
            name: codegen.string,
            target: "<option>",
        };
        pub const packet_entity_status = struct {
            entityId: codegen.@"i32",
            entityStatus: codegen.@"i8",
        };
        pub const packet_explosion = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            radius: codegen.@"f32",
            affectedBlockOffsets: "<array>",
            playerMotionX: codegen.@"f32",
            playerMotionY: codegen.@"f32",
            playerMotionZ: codegen.@"f32",
        };
        pub const packet_unload_chunk = struct {
            chunkX: codegen.@"i32",
            chunkZ: codegen.@"i32",
        };
        pub const packet_game_state_change = struct {
            reason: codegen.@"u8",
            gameMode: codegen.@"f32",
        };
        pub const packet_open_horse_window = struct {
            windowId: codegen.@"u8",
            nbSlots: codegen.varint,
            entityId: codegen.@"i32",
        };
        pub const packet_keep_alive = struct {
            keepAliveId: codegen.@"i64",
        };
        pub const packet_map_chunk = struct {
            x: codegen.@"i32",
            z: codegen.@"i32",
            heightmaps: codegen.nbt,
            chunkData: "<buffer>",
            blockEntities: "<array>",
            skyLightMask: "<array>",
            blockLightMask: "<array>",
            emptySkyLightMask: "<array>",
            emptyBlockLightMask: "<array>",
            skyLight: "<array>",
            blockLight: "<array>",
        };
        pub const packet_world_event = struct {
            effectId: codegen.@"i32",
            location: codegen.position,
            data: codegen.@"i32",
            global: codegen.@"bool",
        };
        pub const packet_world_particles = struct {
            particleId: codegen.varint,
            longDistance: codegen.@"bool",
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            offsetX: codegen.@"f32",
            offsetY: codegen.@"f32",
            offsetZ: codegen.@"f32",
            particleData: codegen.@"f32",
            particles: codegen.@"i32",
            data: "<particleData>",
        };
        pub const packet_update_light = struct {
            chunkX: codegen.varint,
            chunkZ: codegen.varint,
            skyLightMask: "<array>",
            blockLightMask: "<array>",
            emptySkyLightMask: "<array>",
            emptyBlockLightMask: "<array>",
            skyLight: "<array>",
            blockLight: "<array>",
        };
        pub const packet_login = struct {
            entityId: codegen.@"i32",
            isHardcore: codegen.@"bool",
            gameMode: codegen.@"u8",
            previousGameMode: codegen.@"i8",
            worldNames: "<array>",
            dimensionCodec: codegen.nbt,
            worldType: codegen.string,
            worldName: codegen.string,
            hashedSeed: codegen.@"i64",
            maxPlayers: codegen.varint,
            viewDistance: codegen.varint,
            simulationDistance: codegen.varint,
            reducedDebugInfo: codegen.@"bool",
            enableRespawnScreen: codegen.@"bool",
            isDebug: codegen.@"bool",
            isFlat: codegen.@"bool",
            death: "<option>",
            portalCooldown: codegen.varint,
        };
        pub const packet_map = struct {
            itemDamage: codegen.varint,
            scale: codegen.@"i8",
            locked: codegen.@"bool",
            icons: "<option>",
            columns: codegen.@"u8",
            rows: "<switch>",
            x: "<switch>",
            y: "<switch>",
            data: "<switch>",
        };
        pub const packet_trade_list = struct {
            windowId: codegen.varint,
            trades: "<array>",
            villagerLevel: codegen.varint,
            experience: codegen.varint,
            isRegularVillager: codegen.@"bool",
            canRestock: codegen.@"bool",
        };
        pub const packet_rel_entity_move = struct {
            entityId: codegen.varint,
            dX: codegen.@"i16",
            dY: codegen.@"i16",
            dZ: codegen.@"i16",
            onGround: codegen.@"bool",
        };
        pub const packet_entity_move_look = struct {
            entityId: codegen.varint,
            dX: codegen.@"i16",
            dY: codegen.@"i16",
            dZ: codegen.@"i16",
            yaw: codegen.@"i8",
            pitch: codegen.@"i8",
            onGround: codegen.@"bool",
        };
        pub const packet_entity_look = struct {
            entityId: codegen.varint,
            yaw: codegen.@"i8",
            pitch: codegen.@"i8",
            onGround: codegen.@"bool",
        };
        pub const packet_vehicle_move = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"f32",
            pitch: codegen.@"f32",
        };
        pub const packet_open_book = struct {
            hand: codegen.varint,
        };
        pub const packet_open_sign_entity = struct {
            location: codegen.position,
            isFrontText: codegen.@"bool",
        };
        pub const packet_craft_recipe_response = struct {
            windowId: codegen.@"i8",
            recipe: codegen.string,
        };
        pub const packet_abilities = struct {
            flags: codegen.@"i8",
            flyingSpeed: codegen.@"f32",
            walkingSpeed: codegen.@"f32",
        };
        pub const packet_player_chat = struct {
            senderUuid: codegen.UUID,
            index: codegen.varint,
            signature: "<option>",
            plainMessage: codegen.string,
            timestamp: codegen.@"i64",
            salt: codegen.@"i64",
            previousMessages: codegen.previousMessages,
            unsignedChatContent: "<option>",
            filterType: codegen.varint,
            filterTypeMask: "<switch>",
            type: codegen.varint,
            networkName: codegen.string,
            networkTargetName: "<option>",
        };
        pub const packet_end_combat_event = struct {
            duration: codegen.varint,
        };
        pub const packet_enter_combat_event = struct {
        };
        pub const packet_death_combat_event = struct {
            playerId: codegen.varint,
            message: codegen.string,
        };
        pub const packet_player_remove = struct {
            players: "<array>",
        };
        pub const packet_player_info = struct {
            action: "<bitflags>",
            data: "<array>",
        };
        pub const packet_position = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"f32",
            pitch: codegen.@"f32",
            flags: codegen.@"i8",
            teleportId: codegen.varint,
        };
        pub const packet_unlock_recipes = struct {
            action: codegen.varint,
            craftingBookOpen: codegen.@"bool",
            filteringCraftable: codegen.@"bool",
            smeltingBookOpen: codegen.@"bool",
            filteringSmeltable: codegen.@"bool",
            blastFurnaceOpen: codegen.@"bool",
            filteringBlastFurnace: codegen.@"bool",
            smokerBookOpen: codegen.@"bool",
            filteringSmoker: codegen.@"bool",
            recipes1: "<array>",
            recipes2: "<switch>",
        };
        pub const packet_entity_destroy = struct {
            entityIds: "<array>",
        };
        pub const packet_remove_entity_effect = struct {
            entityId: codegen.varint,
            effectId: codegen.varint,
        };
        pub const packet_resource_pack_send = struct {
            url: codegen.string,
            hash: codegen.string,
            forced: codegen.@"bool",
            promptMessage: "<option>",
        };
        pub const packet_respawn = struct {
            dimension: codegen.string,
            worldName: codegen.string,
            hashedSeed: codegen.@"i64",
            gamemode: codegen.@"i8",
            previousGamemode: codegen.@"u8",
            isDebug: codegen.@"bool",
            isFlat: codegen.@"bool",
            copyMetadata: codegen.@"bool",
            death: "<option>",
            portalCooldown: codegen.varint,
        };
        pub const packet_entity_head_rotation = struct {
            entityId: codegen.varint,
            headYaw: codegen.@"i8",
        };
        pub const packet_camera = struct {
            cameraId: codegen.varint,
        };
        pub const packet_held_item_slot = struct {
            slot: codegen.@"i8",
        };
        pub const packet_update_view_position = struct {
            chunkX: codegen.varint,
            chunkZ: codegen.varint,
        };
        pub const packet_update_view_distance = struct {
            viewDistance: codegen.varint,
        };
        pub const packet_scoreboard_display_objective = struct {
            position: codegen.@"i8",
            name: codegen.string,
        };
        pub const packet_entity_metadata = struct {
            entityId: codegen.varint,
            metadata: codegen.entityMetadata,
        };
        pub const packet_attach_entity = struct {
            entityId: codegen.@"i32",
            vehicleId: codegen.@"i32",
        };
        pub const packet_entity_velocity = struct {
            entityId: codegen.varint,
            velocityX: codegen.@"i16",
            velocityY: codegen.@"i16",
            velocityZ: codegen.@"i16",
        };
        pub const packet_entity_equipment = struct {
            entityId: codegen.varint,
            equipments: "<topBitSetTerminatedArray>",
        };
        pub const packet_experience = struct {
            experienceBar: codegen.@"f32",
            level: codegen.varint,
            totalExperience: codegen.varint,
        };
        pub const packet_update_health = struct {
            health: codegen.@"f32",
            food: codegen.varint,
            foodSaturation: codegen.@"f32",
        };
        pub const packet_scoreboard_objective = struct {
            name: codegen.string,
            action: codegen.@"i8",
            displayText: "<switch>",
            type: "<switch>",
        };
        pub const packet_set_passengers = struct {
            entityId: codegen.varint,
            passengers: "<array>",
        };
        pub const packet_teams = struct {
            team: codegen.string,
            mode: codegen.@"i8",
            name: "<switch>",
            friendlyFire: "<switch>",
            nameTagVisibility: "<switch>",
            collisionRule: "<switch>",
            formatting: "<switch>",
            prefix: "<switch>",
            suffix: "<switch>",
            players: "<switch>",
        };
        pub const packet_scoreboard_score = struct {
            itemName: codegen.string,
            action: codegen.varint,
            scoreName: codegen.string,
            value: "<switch>",
        };
        pub const packet_spawn_position = struct {
            location: codegen.position,
            angle: codegen.@"f32",
        };
        pub const packet_update_time = struct {
            age: codegen.@"i64",
            time: codegen.@"i64",
        };
        pub const packet_entity_sound_effect = struct {
            soundId: codegen.varint,
            soundEvent: "<switch>",
            soundCategory: codegen.soundSource,
            entityId: codegen.varint,
            volume: codegen.@"f32",
            pitch: codegen.@"f32",
            seed: codegen.@"i64",
        };
        pub const packet_stop_sound = struct {
            flags: codegen.@"i8",
            source: "<switch>",
            sound: "<switch>",
        };
        pub const packet_sound_effect = struct {
            sound: codegen.ItemSoundHolder,
            soundCategory: codegen.soundSource,
            x: codegen.@"i32",
            y: codegen.@"i32",
            z: codegen.@"i32",
            volume: codegen.@"f32",
            pitch: codegen.@"f32",
            seed: codegen.@"i64",
        };
        pub const packet_system_chat = struct {
            content: codegen.string,
            isActionBar: codegen.@"bool",
        };
        pub const packet_playerlist_header = struct {
            header: codegen.string,
            footer: codegen.string,
        };
        pub const packet_collect = struct {
            collectedEntityId: codegen.varint,
            collectorEntityId: codegen.varint,
            pickupItemCount: codegen.varint,
        };
        pub const packet_entity_teleport = struct {
            entityId: codegen.varint,
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"i8",
            pitch: codegen.@"i8",
            onGround: codegen.@"bool",
        };
        pub const packet_entity_update_attributes = struct {
            entityId: codegen.varint,
            properties: "<array>",
        };
        pub const packet_feature_flags = struct {
            features: "<array>",
        };
        pub const packet_entity_effect = struct {
            entityId: codegen.varint,
            effectId: codegen.varint,
            amplifier: codegen.@"i8",
            duration: codegen.varint,
            hideParticles: codegen.@"i8",
            factorCodec: "<option>",
        };
        pub const packet_select_advancement_tab = struct {
            id: "<option>",
        };
        pub const packet_server_data = struct {
            motd: codegen.string,
            iconBytes: "<option>",
            enforcesSecureChat: codegen.@"bool",
        };
        pub const packet_declare_recipes = struct {
            recipes: "<array>",
        };
        pub const packet_tags = struct {
            tags: "<array>",
        };
        pub const packet_acknowledge_player_digging = struct {
            sequenceId: codegen.varint,
        };
        pub const packet_clear_titles = struct {
            reset: codegen.@"bool",
        };
        pub const packet_initialize_world_border = struct {
            x: codegen.@"f64",
            z: codegen.@"f64",
            oldDiameter: codegen.@"f64",
            newDiameter: codegen.@"f64",
            speed: codegen.varint,
            portalTeleportBoundary: codegen.varint,
            warningBlocks: codegen.varint,
            warningTime: codegen.varint,
        };
        pub const packet_action_bar = struct {
            text: codegen.string,
        };
        pub const packet_world_border_center = struct {
            x: codegen.@"f64",
            z: codegen.@"f64",
        };
        pub const packet_world_border_lerp_size = struct {
            oldDiameter: codegen.@"f64",
            newDiameter: codegen.@"f64",
            speed: codegen.varint,
        };
        pub const packet_world_border_size = struct {
            diameter: codegen.@"f64",
        };
        pub const packet_world_border_warning_delay = struct {
            warningTime: codegen.varint,
        };
        pub const packet_world_border_warning_reach = struct {
            warningBlocks: codegen.varint,
        };
        pub const packet_ping = struct {
            id: codegen.@"i32",
        };
        pub const packet_set_title_subtitle = struct {
            text: codegen.string,
        };
        pub const packet_set_title_text = struct {
            text: codegen.string,
        };
        pub const packet_set_title_time = struct {
            fadeIn: codegen.@"i32",
            stay: codegen.@"i32",
            fadeOut: codegen.@"i32",
        };
        pub const packet_simulation_distance = struct {
            distance: codegen.varint,
        };
        pub const packet_chunk_biomes = struct {
            biomes: "<array>",
        };
        pub const packet_damage_event = struct {
            entityId: codegen.varint,
            sourceTypeId: codegen.varint,
            sourceCauseId: codegen.varint,
            sourceDirectId: codegen.varint,
            sourcePosition: "<option>",
        };
        pub const packet_hurt_animation = struct {
            entityId: codegen.varint,
            yaw: codegen.@"f32",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
    pub const toServer = struct {
        pub const packet_teleport_confirm = struct {
            teleportId: codegen.varint,
        };
        pub const packet_query_block_nbt = struct {
            transactionId: codegen.varint,
            location: codegen.position,
        };
        pub const packet_chat_command = struct {
            command: codegen.string,
            timestamp: codegen.@"i64",
            salt: codegen.@"i64",
            argumentSignatures: "<array>",
            messageCount: codegen.varint,
            acknowledged: "<buffer>",
        };
        pub const packet_chat_message = struct {
            message: codegen.string,
            timestamp: codegen.@"i64",
            salt: codegen.@"i64",
            signature: "<option>",
            offset: codegen.varint,
            acknowledged: "<buffer>",
        };
        pub const packet_set_difficulty = struct {
            newDifficulty: codegen.@"u8",
        };
        pub const packet_message_acknowledgement = struct {
            count: codegen.varint,
        };
        pub const packet_edit_book = struct {
            hand: codegen.varint,
            pages: "<array>",
            title: "<option>",
        };
        pub const packet_query_entity_nbt = struct {
            transactionId: codegen.varint,
            entityId: codegen.varint,
        };
        pub const packet_pick_item = struct {
            slot: codegen.varint,
        };
        pub const packet_name_item = struct {
            name: codegen.string,
        };
        pub const packet_select_trade = struct {
            slot: codegen.varint,
        };
        pub const packet_set_beacon_effect = struct {
            primary_effect: "<option>",
            secondary_effect: "<option>",
        };
        pub const packet_update_command_block = struct {
            location: codegen.position,
            command: codegen.string,
            mode: codegen.varint,
            flags: codegen.@"u8",
        };
        pub const packet_update_command_block_minecart = struct {
            entityId: codegen.varint,
            command: codegen.string,
            track_output: codegen.@"bool",
        };
        pub const packet_update_structure_block = struct {
            location: codegen.position,
            action: codegen.varint,
            mode: codegen.varint,
            name: codegen.string,
            offset_x: codegen.@"i8",
            offset_y: codegen.@"i8",
            offset_z: codegen.@"i8",
            size_x: codegen.@"i8",
            size_y: codegen.@"i8",
            size_z: codegen.@"i8",
            mirror: codegen.varint,
            rotation: codegen.varint,
            metadata: codegen.string,
            integrity: codegen.@"f32",
            seed: codegen.varint,
            flags: codegen.@"u8",
        };
        pub const packet_tab_complete = struct {
            transactionId: codegen.varint,
            text: codegen.string,
        };
        pub const packet_client_command = struct {
            actionId: codegen.varint,
        };
        pub const packet_settings = struct {
            locale: codegen.string,
            viewDistance: codegen.@"i8",
            chatFlags: codegen.varint,
            chatColors: codegen.@"bool",
            skinParts: codegen.@"u8",
            mainHand: codegen.varint,
            enableTextFiltering: codegen.@"bool",
            enableServerListing: codegen.@"bool",
        };
        pub const packet_enchant_item = struct {
            windowId: codegen.@"i8",
            enchantment: codegen.@"i8",
        };
        pub const packet_window_click = struct {
            windowId: codegen.@"u8",
            stateId: codegen.varint,
            slot: codegen.@"i16",
            mouseButton: codegen.@"i8",
            mode: codegen.varint,
            changedSlots: "<array>",
            cursorItem: codegen.slot,
        };
        pub const packet_close_window = struct {
            windowId: codegen.@"u8",
        };
        pub const packet_custom_payload = struct {
            channel: codegen.string,
            data: codegen.restBuffer,
        };
        pub const packet_use_entity = struct {
            target: codegen.varint,
            mouse: codegen.varint,
            x: "<switch>",
            y: "<switch>",
            z: "<switch>",
            hand: "<switch>",
            sneaking: codegen.@"bool",
        };
        pub const packet_generate_structure = struct {
            location: codegen.position,
            levels: codegen.varint,
            keepJigsaws: codegen.@"bool",
        };
        pub const packet_keep_alive = struct {
            keepAliveId: codegen.@"i64",
        };
        pub const packet_lock_difficulty = struct {
            locked: codegen.@"bool",
        };
        pub const packet_position = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            onGround: codegen.@"bool",
        };
        pub const packet_position_look = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"f32",
            pitch: codegen.@"f32",
            onGround: codegen.@"bool",
        };
        pub const packet_look = struct {
            yaw: codegen.@"f32",
            pitch: codegen.@"f32",
            onGround: codegen.@"bool",
        };
        pub const packet_flying = struct {
            onGround: codegen.@"bool",
        };
        pub const packet_vehicle_move = struct {
            x: codegen.@"f64",
            y: codegen.@"f64",
            z: codegen.@"f64",
            yaw: codegen.@"f32",
            pitch: codegen.@"f32",
        };
        pub const packet_steer_boat = struct {
            leftPaddle: codegen.@"bool",
            rightPaddle: codegen.@"bool",
        };
        pub const packet_craft_recipe_request = struct {
            windowId: codegen.@"i8",
            recipe: codegen.string,
            makeAll: codegen.@"bool",
        };
        pub const packet_abilities = struct {
            flags: codegen.@"i8",
        };
        pub const packet_block_dig = struct {
            status: codegen.varint,
            location: codegen.position,
            face: codegen.@"i8",
            sequence: codegen.varint,
        };
        pub const packet_entity_action = struct {
            entityId: codegen.varint,
            actionId: codegen.varint,
            jumpBoost: codegen.varint,
        };
        pub const packet_steer_vehicle = struct {
            sideways: codegen.@"f32",
            forward: codegen.@"f32",
            jump: codegen.@"u8",
        };
        pub const packet_displayed_recipe = struct {
            recipeId: codegen.string,
        };
        pub const packet_recipe_book = struct {
            bookId: codegen.varint,
            bookOpen: codegen.@"bool",
            filterActive: codegen.@"bool",
        };
        pub const packet_resource_pack_receive = struct {
            result: codegen.varint,
        };
        pub const packet_held_item_slot = struct {
            slotId: codegen.@"i16",
        };
        pub const packet_set_creative_slot = struct {
            slot: codegen.@"i16",
            item: codegen.slot,
        };
        pub const packet_update_jigsaw_block = struct {
            location: codegen.position,
            name: codegen.string,
            target: codegen.string,
            pool: codegen.string,
            finalState: codegen.string,
            jointType: codegen.string,
        };
        pub const packet_update_sign = struct {
            location: codegen.position,
            isFrontText: codegen.@"bool",
            text1: codegen.string,
            text2: codegen.string,
            text3: codegen.string,
            text4: codegen.string,
        };
        pub const packet_arm_animation = struct {
            hand: codegen.varint,
        };
        pub const packet_spectate = struct {
            target: codegen.UUID,
        };
        pub const packet_block_place = struct {
            hand: codegen.varint,
            location: codegen.position,
            direction: codegen.varint,
            cursorX: codegen.@"f32",
            cursorY: codegen.@"f32",
            cursorZ: codegen.@"f32",
            insideBlock: codegen.@"bool",
            sequence: codegen.varint,
        };
        pub const packet_use_item = struct {
            hand: codegen.varint,
            sequence: codegen.varint,
        };
        pub const packet_advancement_tab = struct {
            action: codegen.varint,
            tabId: "<switch>",
        };
        pub const packet_pong = struct {
            id: codegen.@"i32",
        };
        pub const packet_chat_session_update = struct {
            sessionUUID: codegen.UUID,
            expireTime: codegen.@"i64",
            publicKey: "<buffer>",
            signature: "<buffer>",
        };
        pub const packet = struct {
            name: "<mapper>",
            params: "<switch>",
        };
    };
};
