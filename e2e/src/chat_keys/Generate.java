// Makes the chat keys the e2e session server hands clients in place of Mojang's: a key standing
// in for Mojang's own, and for each player a key pair it signs as Mojang signs player
// certificates. Run from this directory with `java Generate.java alice bob carol mallory`.
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.time.Instant;
import java.util.Base64;
import java.util.UUID;

public class Generate {
    // Far past any test run, so no client finds its key lapsed or due for refresh.
    static final Instant EXPIRES = Instant.parse("2099-01-01T00:00:00Z");
    static final Instant REFRESH = Instant.parse("2098-12-31T00:00:00Z");

    public static void main(String[] names) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        KeyPair mojang = generator.generateKeyPair();
        String services = Base64.getEncoder().encodeToString(mojang.getPublic().getEncoded());
        Files.writeString(Path.of("publickeys.json"), "{\"profilePropertyKeys\":[{\"publicKey\":\"" + services + "\"}],\"playerCertificateKeys\":[{\"publicKey\":\"" + services + "\"}]}\n");
        for (String name : names) {
            // The UUID the session server gives the player, as vanilla gives offline players theirs.
            UUID uuid = UUID.nameUUIDFromBytes(("OnlinePlayer:" + name).getBytes(StandardCharsets.UTF_8));
            KeyPair player = generator.generateKeyPair();
            byte[] key = player.getPublic().getEncoded();
            // ProfilePublicKey.Data.signedPayload: the UUID, the expiry in milliseconds and the key.
            ByteBuffer payload = ByteBuffer.allocate(24 + key.length);
            payload.putLong(uuid.getMostSignificantBits()).putLong(uuid.getLeastSignificantBits()).putLong(EXPIRES.toEpochMilli()).put(key);
            Signature signer = Signature.getInstance("SHA1withRSA");
            signer.initSign(mojang.getPrivate());
            signer.update(payload.array());
            String signature = Base64.getEncoder().encodeToString(signer.sign());
            // Mojang's labels say RSA; the contents are PKCS#8 and X.509, as the client reads them.
            String privateKey = "-----BEGIN RSA PRIVATE KEY-----\\n" + Base64.getEncoder().encodeToString(player.getPrivate().getEncoded()) + "\\n-----END RSA PRIVATE KEY-----\\n";
            String publicKey = "-----BEGIN RSA PUBLIC KEY-----\\n" + Base64.getEncoder().encodeToString(key) + "\\n-----END RSA PUBLIC KEY-----\\n";
            Files.writeString(Path.of(name + ".json"), "{\"keyPair\":{\"privateKey\":\"" + privateKey + "\",\"publicKey\":\"" + publicKey + "\"},\"publicKeySignature\":\"" + signature + "\",\"publicKeySignatureV2\":\"" + signature + "\",\"expiresAt\":\"" + EXPIRES + "\",\"refreshedAfter\":\"" + REFRESH + "\"}\n");
        }
    }
}
