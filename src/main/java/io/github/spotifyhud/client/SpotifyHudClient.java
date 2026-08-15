package io.github.spotifyhud.client;

import io.github.spotifyhud.client.media.MediaService;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.rendering.v1.hud.HudElementRegistry;
import net.fabricmc.fabric.api.client.rendering.v1.hud.VanillaHudElements;
import net.minecraft.resources.Identifier;

public final class SpotifyHudClient implements ClientModInitializer {
    private static final String MOD_ID = "spotifyhud";
    private MediaService media;

    @Override
    public void onInitializeClient() {
        media = new MediaService();
        media.start();

        HudRenderer renderer = new HudRenderer(media);
        HudElementRegistry.attachElementBefore(
                VanillaHudElements.CHAT,
                Identifier.fromNamespaceAndPath(MOD_ID, "now_playing"),
                (graphics, tickCounter) -> renderer.render(graphics)
        );

        Runtime.getRuntime().addShutdownHook(new Thread(media::close, "Spotify HUD shutdown"));
    }
}
