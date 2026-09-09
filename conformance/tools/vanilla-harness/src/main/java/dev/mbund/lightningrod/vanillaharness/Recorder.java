package dev.mbund.lightningrod.vanillaharness;
import java.io.IOException; import java.nio.charset.StandardCharsets; import java.nio.file.Files; import java.nio.file.Path; import java.util.ArrayList; import java.util.HexFormat; import java.util.List;
/** Captures the Vanilla server's wire boundary for Zig canonical comparison. */
public final class Recorder {
 private static final Recorder INSTANCE = new Recorder(); private final List<String> packets = new ArrayList<>(); private Path output; private boolean enabled, written;
 public static Recorder instance() { return INSTANCE; }
 public void configure() { String value = System.getProperty("mcc.output"); if (value != null && !value.isBlank()) { output = Path.of(value); enabled = true; } }
 public synchronized void inbound(byte[] bytes) { record("serverbound", bytes); }
 public synchronized void outbound(byte[] bytes) { record("clientbound", bytes); }
 private void record(String direction, byte[] bytes) { if (enabled && !written) packets.add("packet 0 " + direction + " client " + HexFormat.of().formatHex(bytes)); }
 public synchronized void write() { if (!enabled || written) return; written = true; try { if (output.getParent()!=null) Files.createDirectories(output.getParent()); List<String> text=new ArrayList<>(); text.add("mcc-capture-v1"); text.add("minecraft 1.21.8"); text.addAll(packets); Files.writeString(output,String.join("\n",text)+"\n",StandardCharsets.UTF_8); } catch(IOException e) { throw new IllegalStateException("cannot write Vanilla capture",e); } }
}
