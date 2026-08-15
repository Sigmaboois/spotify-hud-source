package io.github.spotifyhud.client.media;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.fabricmc.loader.api.FabricLoader;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicReference;

public final class MediaService implements AutoCloseable {
    private final AtomicReference<MediaSnapshot> current = new AtomicReference<>(MediaSnapshot.empty());
    private volatile Process process;
    private volatile BufferedWriter writer;
    private volatile boolean closed;

    public MediaSnapshot current() { return current.get(); }

    public void start() {
        Thread.ofPlatform().daemon().name("Spotify HUD media bridge").start(this::runLoop);
    }

    private void runLoop() {
        while (!closed) {
            try {
                runHelper();
            } catch (Exception ignored) {
                current.set(MediaSnapshot.empty());
            }
            if (!closed) {
                try { Thread.sleep(1500); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void runHelper() throws Exception {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String resource;
        List<String> command;
        long pid = ProcessHandle.current().pid();
        if (os.contains("win")) {
            resource = "/spotifyhud/helpers/spotify-media-windows.ps1";
            Path helper = install(resource, ".ps1");
            command = List.of("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper.toString(), "-ParentProcessId", Long.toString(pid));
        } else if (os.contains("mac")) {
            resource = "/spotifyhud/helpers/spotify-media-macos.sh";
            Path helper = install(resource, ".sh");
            command = List.of("/bin/bash", helper.toString(), "--parent-pid", Long.toString(pid));
        } else {
            resource = "/spotifyhud/helpers/spotify-media-linux.sh";
            Path helper = install(resource, ".sh");
            command = List.of("/bin/bash", helper.toString(), "--parent-pid", Long.toString(pid));
        }

        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectError(ProcessBuilder.Redirect.DISCARD);
        process = builder.start();
        writer = new BufferedWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while (!closed && (line = reader.readLine()) != null) accept(line);
        } finally {
            writer = null;
            if (process != null) process.destroy();
            process = null;
        }
    }

    private static Path install(String resource, String suffix) throws IOException {
        Path dir = FabricLoader.getInstance().getGameDir().resolve("spotifyhud");
        Files.createDirectories(dir);
        Path target = dir.resolve("media-helper" + suffix);
        try (InputStream in = MediaService.class.getResourceAsStream(resource)) {
            if (in == null) throw new FileNotFoundException(resource);
            Files.copy(in, target, StandardCopyOption.REPLACE_EXISTING);
        }
        target.toFile().setExecutable(true, true);
        return target;
    }

    private void accept(String line) {
        try {
            JsonObject json = JsonParser.parseString(line).getAsJsonObject();
            if (!"status".equals(string(json, "type"))) return;
            current.set(new MediaSnapshot(
                    bool(json, "empty", false), string(json, "title"), string(json, "artist"), string(json, "album"),
                    number(json, "positionMillis"), number(json, "durationMillis"), bool(json, "playing", false),
                    string(json, "artwork"), string(json, "player"), string(json, "source")));
        } catch (RuntimeException ignored) { }
    }

    public void playPause() { send("playPause"); }
    public void next() { send("next"); }
    public void previous() { send("previous"); }

    private void send(String command) {
        BufferedWriter out = writer;
        if (out == null) return;
        try {
            synchronized (this) {
                out.write("{\"type\":\"command\",\"command\":\"" + command + "\"}\n");
                out.flush();
            }
        } catch (IOException ignored) { }
    }

    private static String string(JsonObject o, String k) { return o.has(k) && !o.get(k).isJsonNull() ? o.get(k).getAsString() : ""; }
    private static long number(JsonObject o, String k) { try { return o.has(k) ? o.get(k).getAsLong() : 0; } catch (RuntimeException e) { return 0; } }
    private static boolean bool(JsonObject o, String k, boolean d) { try { return o.has(k) ? o.get(k).getAsBoolean() : d; } catch (RuntimeException e) { return d; } }

    @Override public void close() {
        closed = true;
        Process p = process;
        if (p != null) p.destroy();
    }
}
