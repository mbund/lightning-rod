package dev.mbund.lightningrod.conformance;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

record Scenario(String fixture, List<String> clients, long finalTick, List<Move> moves, List<PlayerAction> actions, List<Command> commands) {
    record Move(long tick, String client, double x, double y, double z) {}
    record PlayerAction(long tick, String client, String action, int x, int y, int z) {}
    record Command(long tick, String client, String value) {}

    static Scenario read(Path path) throws IOException {
        List<String> lines = Files.readAllLines(path);
        if (lines.isEmpty() || !lines.getFirst().equals("mcc-scenario-v1")) throw new IllegalArgumentException("missing mcc-scenario-v1 header");
        String fixture = null;
        List<String> clients = new ArrayList<>();
        long end = -1;
        List<Move> moves = new ArrayList<>();
        List<PlayerAction> actions = new ArrayList<>();
        List<Command> commands = new ArrayList<>();
        for (String raw : lines.subList(1, lines.size())) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] tokens = line.split(" +");
            switch (tokens[0]) {
                case "fixture" -> { if (tokens.length != 2 || fixture != null) throw new IllegalArgumentException("invalid fixture"); fixture = tokens[1]; }
                case "client" -> { if (tokens.length != 2 || clients.contains(tokens[1])) throw new IllegalArgumentException("invalid client"); clients.add(tokens[1]); }
                case "end" -> { if (tokens.length != 2 || end >= 0) throw new IllegalArgumentException("invalid end"); end = Long.parseLong(tokens[1]); }
                case "send" -> {
                    if (tokens.length < 5) throw new IllegalArgumentException("invalid send");
                    long tick = Long.parseLong(tokens[1]);
                    String client = tokens[3];
                    if (tokens[4].equals("move")) moves.add(new Move(tick, client, number(tokens, "x"), number(tokens, "y"), number(tokens, "z")));
                    if (tokens[4].equals("player_action")) {
                        String[] position = field(tokens, "position").split(",", -1);
                        if (position.length != 3) throw new IllegalArgumentException("invalid player_action position");
                        actions.add(new PlayerAction(tick, client, field(tokens, "action"), Integer.parseInt(position[0]), Integer.parseInt(position[1]), Integer.parseInt(position[2])));
                    }
                    if (tokens[4].equals("command")) commands.add(new Command(tick, client, field(tokens, "value")));
                }
                default -> throw new IllegalArgumentException("unknown scenario record " + tokens[0]);
            }
        }
        if (fixture == null || clients.isEmpty() || end < 0) throw new IllegalArgumentException("incomplete scenario");
        return new Scenario(fixture, List.copyOf(clients), end, List.copyOf(moves), List.copyOf(actions), List.copyOf(commands));
    }

    private static double number(String[] tokens, String name) { return Double.parseDouble(field(tokens, name)); }
    private static String field(String[] tokens, String name) {
        String prefix = name + "=";
        for (String token : tokens) if (token.startsWith(prefix)) return token.substring(prefix.length());
        throw new IllegalArgumentException("missing " + name);
    }
}
