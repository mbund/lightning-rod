const play_decode = @import("play_decode.zig");

pub fn handler(writer: anytype) play_decode.Handler {
    const Pointer = @typeInfo(@TypeOf(writer)).pointer;
    return .{ .context = writer, .callback = Dispatch(Pointer.child).dispatch };
}

fn Dispatch(comptime Writer: type) type {
    return struct {
        fn writer(raw: *anyopaque) *Writer {
            return @ptrCast(@alignCast(raw));
        }

        fn arguments(comptime T: type, raw: *const anyopaque) *const T {
            return @ptrCast(@alignCast(raw));
        }

        fn finish(self: *Writer, result: anyerror!void) play_decode.CallbackStatus {
            result catch |err| {
                self.input_failed(err);
                return .failed;
            };
            return .ok;
        }

        fn dispatch(
            raw: *anyopaque,
            operation: play_decode.Operation,
            raw_arguments: *const anyopaque,
        ) callconv(.c) play_decode.CallbackStatus {
            const self = writer(raw);
            switch (operation) {
                .teleport_confirm => dispatchTeleport(self, raw_arguments),
                .keep_alive_response => dispatchKeepAlive(self, raw_arguments),
                .chunk_batch_received => dispatchChunkBatchReceived(self, raw_arguments),
                .movement => return dispatchMovement(self, raw_arguments),
                .player_input => dispatchPlayerInput(self, raw_arguments),
                .player_sprint => dispatchPlayerSprint(self, raw_arguments),
                .player_loaded => dispatchPlayerLoaded(self, raw_arguments),
                .chat, .command => return dispatchText(self, operation, raw_arguments),
                .block_dig => return dispatchBlockDig(self, raw_arguments),
                .block_place => return dispatchBlockPlace(self, raw_arguments),
                .held_item_slot => return dispatchHeldItem(self, raw_arguments),
                .arm_animation, .attack_entity, .use_item, .close_window => return dispatchInteger(self, operation, raw_arguments),
                .interact_entity => return dispatchInteract(self, raw_arguments),
                .respawn, .ignored => return dispatchSlot(self, operation, raw_arguments),
                .window_click => return dispatchWindowClick(self, raw_arguments),
                .creative_slot => return dispatchCreativeSlot(self, raw_arguments),
            }
            return .ok;
        }

        fn dispatchTeleport(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.TeleportConfirm, raw);
            self.teleport_confirm(value.slot, value.value);
        }

        fn dispatchKeepAlive(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.KeepAliveResponse, raw);
            self.keep_alive_response(value.slot, value.value);
        }

        fn dispatchChunkBatchReceived(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.ChunkBatchReceived, raw);
            self.chunk_batch_received(value.slot, value.chunks_per_tick);
        }

        fn dispatchMovement(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.Movement, raw);
            return finish(self, self.movement(
                value.slot,
                if (value.has_position != 0) value.position else null,
                if (value.has_rotation != 0) value.rotation else null,
                value.on_ground != 0,
            ));
        }

        fn dispatchPlayerInput(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.PlayerInput, raw);
            self.player_input(value.slot, value.shift != 0, value.sprint != 0);
        }

        fn dispatchPlayerSprint(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.PlayerSprint, raw);
            self.player_sprint(value.slot, value.sprinting != 0);
        }

        fn dispatchPlayerLoaded(self: *Writer, raw: *const anyopaque) void {
            const value = arguments(play_decode.Arguments.Slot, raw);
            self.player_loaded(value.slot);
        }

        fn dispatchText(self: *Writer, operation: play_decode.Operation, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.Bytes, raw);
            return finish(self, if (operation == .chat)
                self.chat(value.slot, value.value())
            else
                self.command(value.slot, value.value()));
        }

        fn dispatchBlockDig(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.BlockDig, raw);
            return finish(self, self.block_dig(value.slot, value.status, value.position, value.face, value.sequence));
        }

        fn dispatchBlockPlace(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.BlockPlace, raw);
            return finish(self, self.block_place(
                value.slot,
                value.position,
                value.direction,
                value.cursor_x,
                value.cursor_y,
                value.cursor_z,
                value.sequence,
            ));
        }

        fn dispatchHeldItem(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.HeldItemSlot, raw);
            return finish(self, self.held_item_slot(value.slot, value.value));
        }

        fn dispatchInteger(self: *Writer, operation: play_decode.Operation, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.Integer, raw);
            return finish(self, switch (operation) {
                .arm_animation => self.arm_animation(value.slot, value.value),
                .attack_entity => self.attack_entity(value.slot, value.value),
                .use_item => self.use_item(value.slot, value.value),
                .close_window => self.close_window(value.slot, value.value),
                else => unreachable,
            });
        }

        fn dispatchInteract(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.EntityInteraction, raw);
            return finish(self, self.interact_entity(value.slot, value.entity_id, value.hand));
        }

        fn dispatchSlot(self: *Writer, operation: play_decode.Operation, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.Slot, raw);
            if (operation == .respawn) return finish(self, self.respawn(value.slot));
            self.ignored(value.slot);
            return .ok;
        }

        fn dispatchWindowClick(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.WindowClick, raw);
            return finish(self, self.window_click(
                value.slot,
                value.window_id,
                value.state_id,
                value.protocol_slot,
                value.mouse_button,
                value.mode,
            ));
        }

        fn dispatchCreativeSlot(self: *Writer, raw: *const anyopaque) play_decode.CallbackStatus {
            const value = arguments(play_decode.Arguments.CreativeSlot, raw);
            return finish(self, self.creative_slot(
                value.slot,
                value.inventory_slot,
                value.item_id,
                value.count,
            ));
        }
    };
}
