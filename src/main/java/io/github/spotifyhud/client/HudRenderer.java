package io.github.spotifyhud.client;

import io.github.spotifyhud.client.media.MediaService;
import io.github.spotifyhud.client.media.MediaSnapshot;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;

public final class HudRenderer {
    private final MediaService media;

    public HudRenderer(MediaService media) {
        this.media = media;
    }

    public void render(GuiGraphicsExtractor graphics) {
        MediaSnapshot track = media.current();
        if (track.empty() || track.title().isBlank()) return;

        Minecraft client = Minecraft.getInstance();
        String title = trim(track.title(), 36);
        String artist = trim(track.artist(), 42);

        int width = Math.max(
                170,
                Math.min(280, Math.max(client.font.width(title), client.font.width(artist)) + 28)
        );
        int x = 12;
        int y = 12;
        int height = 50;

        graphics.fill(x, y, x + width, y + height, 0xD9161616);
        graphics.fill(x, y, x + 4, y + height, 0xFF1DB954);
        graphics.text(client.font, title, x + 13, y + 9, 0xFFFFFFFF, true);
        graphics.text(client.font, artist, x + 13, y + 23, 0xFFB3B3B3, true);

        if (track.durationMillis() > 0) {
            int barX = x + 13;
            int barY = y + 39;
            int barWidth = width - 26;
            graphics.fill(barX, barY, barX + barWidth, barY + 2, 0xFF555555);

            double progress = Math.max(
                    0,
                    Math.min(1, (double) track.positionMillis() / track.durationMillis())
            );
            graphics.fill(
                    barX,
                    barY,
                    barX + (int) Math.round(barWidth * progress),
                    barY + 2,
                    0xFF1DB954
            );
        }
    }

    private static String trim(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, Math.max(0, max - 1)) + "…";
    }
}
