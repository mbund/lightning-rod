package dev.lightningrod.registry;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import net.minecraft.SharedConstants;
import net.minecraft.core.Direction;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.lighting.LightEngine;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

public final class LightingSnapshot {
    private static final Direction[] DIRECTIONS = { Direction.WEST, Direction.EAST, Direction.NORTH, Direction.SOUTH, Direction.DOWN, Direction.UP };

    public static void main(String[] args) throws Exception {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        var destination = Path.of(args[0]);
        Files.createDirectories(destination.toAbsolutePath().getParent());
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(destination)))) {
            output.write("LRLIGHT1".getBytes(StandardCharsets.US_ASCII));
            var faces = new ArrayList<VoxelShape>();
            var index = new LinkedHashMap<String, Integer>();
            faces.add(Shapes.empty());
            index.put(Shapes.empty().toAabbs().toString(), 0);
            int[][] stateFaces = new int[Block.BLOCK_STATE_REGISTRY.size()][6];
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                int id = Block.getId(state);
                for (int d = 0; d < 6; d++) {
                    var face = LightEngine.getOcclusionShape(state, DIRECTIONS[d]);
                    var key = face.toAabbs().toString();
                    Integer at = index.get(key);
                    if (at == null) {
                        at = faces.size();
                        faces.add(face);
                        index.put(key, at);
                    }
                    stateFaces[id][d] = at;
                }
            }
            output.writeInt(stateFaces.length);
            output.writeInt(faces.size());
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                output.writeByte(LightingApi.opacity(state));
                output.writeByte(state.getLightEmission());
                for (int face : stateFaces[Block.getId(state)]) output.writeShort(face);
            }
            for (var a : faces) for (var b : faces) output.writeBoolean(Shapes.faceShapeOccludes(a, b));
        }
    }
}
