package io.github.spotifyhud.client;

import io.github.spotifyhud.client.media.MediaService;
import io.github.spotifyhud.client.media.MediaSnapshot;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.DrawContext;

public final class HudRenderer {
    private final MediaService media;

    public HudRenderer(MediaService media) { this.media = media; }

    public void render(DrawContext context) {
        MediaSnapshot track = media.current();
        if (track.empty() || track.title().isBlank()) return;

        MinecraftClient client = MinecraftClient.getInstance();
        int width = Math.max(170, Math.min(280, Math.max(client.textRenderer.getWidth(track.title()), client.textRenderer.getWidth(track.artist())) + 28));
        int x = 12;
        int y = 12;
        int height = 50;

        context.fill(x, y, x + width, y + height, 0xD9161616);
        context.fill(x, y, x + 4, y + height, 0xFF1DB954);
        context.drawTextWithShadow(client.textRenderer, trim(track.title(), 36), x + 13, y + 9, 0xFFFFFFFF);
        context.drawTextWithShadow(client.textRenderer, trim(track.artist(), 42), x + 13, y + 23, 0xFFB3B3B3);

        if (track.durationMillis() > 0) {
            int barX = x + 13;
            int barY = y + 39;
            int barWidth = width - 26;
            context.fill(barX, barY, barX + barWidth, barY + 2, 0xFF555555);
            double progress = Math.max(0, Math.min(1, (double) track.positionMillis() / track.durationMillis()));
            context.fill(barX, barY, barX + (int) Math.round(barWidth * progress), barY + 2, 0xFF1DB954);
        }
    }

    private static String trim(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, Math.max(0, max - 1)) + "…";
    }
}
