package dev.lightningrod.registry;

import net.minecraft.world.level.block.state.BlockState;

final class LightingApi {
    static int opacity(BlockState state) {
        return state.getLightBlock();
    }
}
