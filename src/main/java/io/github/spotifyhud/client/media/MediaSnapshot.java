package io.github.spotifyhud.client.media;

public record MediaSnapshot(
        boolean empty,
        String title,
        String artist,
        String album,
        long positionMillis,
        long durationMillis,
        boolean playing,
        String artwork,
        String player,
        String source
) {
    public static MediaSnapshot empty() {
        return new MediaSnapshot(true, "", "", "", 0, 0, false, "", "", "");
    }
}
