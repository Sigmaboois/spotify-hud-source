package io.github.spotifyhud.client;

import io.github.spotifyhud.client.media.MediaService;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.rendering.v1.HudRenderCallback;

public final class SpotifyHudClient implements ClientModInitializer {
    private MediaService media;

    @Override
    public void onInitializeClient() {
        media = new MediaService();
        media.start();
        HudRenderer renderer = new HudRenderer(media);
        HudRenderCallback.EVENT.register((context, tickCounter) -> renderer.render(context));
        Runtime.getRuntime().addShutdownHook(new Thread(media::close, "Spotify HUD shutdown"));
    }
}
