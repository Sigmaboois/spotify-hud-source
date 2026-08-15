#!/usr/bin/env bash
# Spotify HUD media bridge for macOS Spotify Desktop.
#
# Stdout is reserved for newline-delimited JSON status messages. Diagnostics go
# to stderr. Commands may be sent as newline-delimited JSON on stdin; see the
# companion README for the protocol.

set -u
set -o pipefail
umask 077

PROTOCOL_VERSION=1
PARENT_PID="${PPID:-}"
PARENT_SIGNATURE=""
WATCH_PARENT=1
INTERVAL_MS=900
POLL_TIMEOUT="0.900"
INCLUDE_ARTWORK=1
ONCE=0
STDIN_CLOSED=0

OSASCRIPT_BIN="/usr/bin/osascript"
TIMEOUT_BIN=""
CURL_BIN=""

STATUS_EMPTY=true
STATUS_TITLE=""
STATUS_ARTIST=""
STATUS_ALBUM=""
STATUS_POSITION=0
STATUS_DURATION=0
STATUS_PLAYING=false
STATUS_ARTWORK=""
STATUS_PLAYER="spotify"
STATUS_SOURCE="spotify-applescript"
STATUS_CAPABILITIES='{"play":false,"pause":false,"playPause":false,"next":false,"previous":false,"seek":false,"seekRelative":false}'

ART_TMP=""
ART_CACHE_URL=""
ART_CACHE_VALUE=""
ART_FAILED_URL=""
ART_RETRY_AT=0
LAST_ARTWORK_SUCCESS_KEY=""
LAST_DIAGNOSTIC=""

FIELD_SEP=$'\037'
MAX_ARTWORK_BYTES=4194304
MAX_SEEK_MILLIS=31536000000

usage() {
    cat >&2 <<'USAGE'
Usage: spotify-media-macos.sh [options]

Options:
  --parent-pid PID      Exit when PID is no longer the same process (default: PPID).
  --no-parent-watch     Do not monitor a parent process.
  --interval-ms MS      Status interval, clamped to 250..10000 (default: 900).
  --no-artwork          Do not download album artwork.
  --once                Print one status and exit.
  -h, --help            Show this help.
USAGE
}

die_usage() {
    printf 'spotify-media-macos: %s\n' "$1" >&2
    usage
    exit 64
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --parent-pid|-ParentProcessId)
            [ "$#" -ge 2 ] || die_usage "$1 requires a PID"
            PARENT_PID=$2
            WATCH_PARENT=1
            shift 2
            ;;
        --no-parent-watch)
            WATCH_PARENT=0
            shift
            ;;
        --interval-ms)
            [ "$#" -ge 2 ] || die_usage "$1 requires milliseconds"
            INTERVAL_MS=$2
            shift 2
            ;;
        --no-artwork)
            INCLUDE_ARTWORK=0
            shift
            ;;
        --once)
            ONCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            die_usage "unknown option: $1"
            ;;
    esac
done

case "$INTERVAL_MS" in
    ''|*[!0-9]*) die_usage "--interval-ms must be an integer" ;;
esac
if [ "$INTERVAL_MS" -lt 250 ]; then INTERVAL_MS=250; fi
if [ "$INTERVAL_MS" -gt 10000 ]; then INTERVAL_MS=10000; fi
POLL_TIMEOUT=$(printf '%d.%03d' "$((INTERVAL_MS / 1000))" "$((INTERVAL_MS % 1000))")

if [ "$WATCH_PARENT" -eq 1 ]; then
    case "$PARENT_PID" in
        ''|*[!0-9]*) die_usage "--parent-pid must be a positive integer" ;;
    esac
    if [ "$PARENT_PID" -le 1 ] || [ "$PARENT_PID" -eq "$$" ]; then
        die_usage "refusing unsafe parent PID $PARENT_PID"
    fi
fi

command_path() {
    command -v "$1" 2>/dev/null || true
}

if [ ! -x "$OSASCRIPT_BIN" ]; then OSASCRIPT_BIN=$(command_path osascript); fi
TIMEOUT_BIN=$(command_path gtimeout)
if [ -z "$TIMEOUT_BIN" ]; then TIMEOUT_BIN=$(command_path timeout); fi
CURL_BIN=$(command_path curl)

cleanup() {
    if [ -n "$ART_TMP" ] && [ -f "$ART_TMP" ]; then
        rm -f -- "$ART_TMP"
    fi
}

trap 'cleanup; exit 0' HUP INT TERM PIPE
trap cleanup EXIT

diagnostic() {
    if [ "$1" != "$LAST_DIAGNOSTIC" ]; then
        printf 'spotify-media-macos: %s\n' "$1" >&2
        LAST_DIAGNOSTIC=$1
    fi
}

clear_diagnostic() {
    LAST_DIAGNOSTIC=""
}

run_timed() {
    local child watcher status
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" --signal=TERM --kill-after=1s 4s "$@"
        return $?
    fi
    # macOS does not include GNU timeout. Keep a local watchdog so an Automation
    # prompt or a wedged Spotify process cannot orphan this bridge indefinitely.
    "$@" <&0 &
    child=$!
    (
        sleep 4
        kill -TERM "$child" 2>/dev/null || exit 0
        sleep 1
        kill -KILL "$child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watcher=$!
    wait "$child"
    status=$?
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return "$status"
}

mac_process_signature() {
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ "$WATCH_PARENT" -eq 1 ]; then
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then exit 0; fi
    PARENT_SIGNATURE=$(mac_process_signature "$PARENT_PID" || true)
fi

parent_is_alive() {
    local current_signature
    [ "$WATCH_PARENT" -eq 0 ] && return 0
    kill -0 "$PARENT_PID" 2>/dev/null || return 1
    if [ -n "$PARENT_SIGNATURE" ]; then
        current_signature=$(mac_process_signature "$PARENT_PID" || true)
        [ -n "$current_signature" ] && [ "$current_signature" = "$PARENT_SIGNATURE" ] || return 1
    fi
    return 0
}

json_escape() {
    local value=$1
    value=$(LC_ALL=C printf '%s' "$value" | tr -d '\001-\010\013\014\016-\037\177')
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\b'/\\b}
    value=${value//$'\f'/\\f}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

set_empty_status() {
    STATUS_EMPTY=true
    STATUS_TITLE=""
    STATUS_ARTIST=""
    STATUS_ALBUM=""
    STATUS_POSITION=0
    STATUS_DURATION=0
    STATUS_PLAYING=false
    STATUS_ARTWORK=""
    STATUS_PLAYER="spotify"
    STATUS_SOURCE="spotify-applescript"
    STATUS_CAPABILITIES='{"play":false,"pause":false,"playPause":false,"next":false,"previous":false,"seek":false,"seekRelative":false}'
    LAST_ARTWORK_SUCCESS_KEY=""
}

emit_status() {
    local title artist album player source
    title=$(json_escape "$STATUS_TITLE")
    artist=$(json_escape "$STATUS_ARTIST")
    album=$(json_escape "$STATUS_ALBUM")
    player=$(json_escape "$STATUS_PLAYER")
    source=$(json_escape "$STATUS_SOURCE")
    printf '{"type":"status","protocolVersion":%d,"empty":%s,"title":"%s","artist":"%s","album":"%s","positionMillis":%d,"durationMillis":%d,"playing":%s,"artwork":"%s","player":"%s","source":"%s","capabilities":%s}\n' \
        "$PROTOCOL_VERSION" "$STATUS_EMPTY" "$title" "$artist" "$album" \
        "$STATUS_POSITION" "$STATUS_DURATION" "$STATUS_PLAYING" "$STATUS_ARTWORK" \
        "$player" "$source" "$STATUS_CAPABILITIES"
}

seconds_to_millis() {
    LC_ALL=C awk -v value="$1" 'BEGIN {
        if (value ~ /^-?[0-9]+([.][0-9]+)?$/) {
            result = value * 1000;
            if (result < 0) result = 0;
            printf "%.0f", result;
        } else print "0";
    }'
}

normalise_integer() {
    case "$1" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

ensure_art_tmp() {
    if [ -z "$ART_TMP" ]; then
        ART_TMP=$(mktemp "${TMPDIR:-/tmp}/spotifyhud-art.XXXXXXXX") || return 1
    fi
    : > "$ART_TMP"
}

valid_artwork_file() {
    local bytes signature
    bytes=$(wc -c < "$ART_TMP" | tr -d '[:space:]')
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bytes" -gt 0 ] && [ "$bytes" -le "$MAX_ARTWORK_BYTES" ] || return 1
    signature=$(od -An -tx1 -N16 "$ART_TMP" 2>/dev/null | tr -d '[:space:]')
    case "$signature" in
        89504e470d0a1a0a*|ffd8ff*|474946383761*|474946383961*|52494646????????57454250*) return 0 ;;
        *) return 1 ;;
    esac
}

download_artwork() {
    local url=$1 now
    now=$(date +%s)
    if [ "$url" = "$ART_FAILED_URL" ] && [ "$now" -lt "$ART_RETRY_AT" ]; then
        return 1
    fi
    [ -n "$CURL_BIN" ] || {
        ART_FAILED_URL=$url
        ART_RETRY_AT=$((now + 30))
        return 1
    }
    case "$url" in https://*|http://*|file://*) ;; *) return 1 ;; esac
    ensure_art_tmp || return 1
    "$CURL_BIN" --location --silent --show-error --fail \
        --proto '=http,https,file' --proto-redir '=http,https,file' \
        --connect-timeout 2 --max-time 6 --max-filesize "$MAX_ARTWORK_BYTES" \
        --output "$ART_TMP" -- "$url" >/dev/null 2>&1 || {
            ART_FAILED_URL=$url
            ART_RETRY_AT=$((now + 30))
            return 1
        }
    if ! valid_artwork_file; then
        ART_FAILED_URL=$url
        ART_RETRY_AT=$((now + 30))
        return 1
    fi
    ART_CACHE_VALUE=$(base64 < "$ART_TMP" | tr -d '\r\n')
    [ -n "$ART_CACHE_VALUE" ] || return 1
    ART_CACHE_URL=$url
    ART_FAILED_URL=""
    ART_RETRY_AT=0
    return 0
}

prepare_artwork() {
    local key=$1 url=$2
    STATUS_ARTWORK=""
    [ "$INCLUDE_ARTWORK" -eq 1 ] || return 0
    [ -n "$url" ] || return 0
    [ "$key" != "$LAST_ARTWORK_SUCCESS_KEY" ] || return 0
    if [ "$url" = "$ART_CACHE_URL" ] && [ -n "$ART_CACHE_VALUE" ]; then
        STATUS_ARTWORK=$ART_CACHE_VALUE
        LAST_ARTWORK_SUCCESS_KEY=$key
        return 0
    fi
    if download_artwork "$url"; then
        STATUS_ARTWORK=$ART_CACHE_VALUE
        LAST_ARTWORK_SUCCESS_KEY=$key
    fi
}

query_spotify() {
    run_timed "$OSASCRIPT_BIN" <<'APPLESCRIPT'
on replaceText(sourceText, searchText, replacementText)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to searchText
    set sourceItems to every text item of (sourceText as text)
    set AppleScript's text item delimiters to replacementText
    set replacedText to sourceItems as text
    set AppleScript's text item delimiters to oldDelimiters
    return replacedText
end replaceText

on scrub(sourceValue)
    set cleaned to sourceValue as text
    set cleaned to my replaceText(cleaned, return, " ")
    set cleaned to my replaceText(cleaned, linefeed, " ")
    set cleaned to my replaceText(cleaned, ASCII character 31, " ")
    return cleaned
end scrub

if application "Spotify" is not running then return "__EMPTY__"

try
    tell application "Spotify"
        set playbackState to player state as text
        if playbackState is "stopped" then return "__EMPTY__"
        set spotifyTrack to current track
        set trackTitle to ""
        set trackArtist to ""
        set trackAlbum to ""
        set trackPosition to 0
        set trackDuration to 0
        set trackArtwork to ""
        try
            set trackTitle to name of spotifyTrack as text
        end try
        try
            set trackArtist to artist of spotifyTrack as text
        end try
        try
            set trackAlbum to album of spotifyTrack as text
        end try
        try
            set trackPosition to ((player position as real) * 1000) as integer
        end try
        try
            set trackDuration to duration of spotifyTrack as integer
        end try
        try
            set trackArtwork to artwork url of spotifyTrack as text
        end try
    end tell
    set separator to ASCII character 31
    return (my scrub(trackTitle)) & separator & (my scrub(trackArtist)) & separator & (my scrub(trackAlbum)) & separator & (trackPosition as text) & separator & (trackDuration as text) & separator & (playbackState as text) & separator & (my scrub(trackArtwork))
on error errorMessage
    return "__ERROR__" & (ASCII character 31) & (my scrub(errorMessage))
end try
APPLESCRIPT
}

split_spotify_result() {
    local rest=$1
    SP_TITLE=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_ARTIST=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_ALBUM=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_POSITION=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_DURATION=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_STATE=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    SP_ART_URL=$rest
}

refresh_status() {
    local result key error_message
    STATUS_ARTWORK=""
    if [ -z "$OSASCRIPT_BIN" ]; then
        set_empty_status
        diagnostic "osascript is unavailable"
        return 1
    fi
    if ! result=$(query_spotify 2>/dev/null); then
        set_empty_status
        diagnostic "Spotify AppleScript query failed (Automation permission may be required)"
        return 1
    fi
    case "$result" in
        __EMPTY__|'')
            set_empty_status
            clear_diagnostic
            return 1
            ;;
        __ERROR__*)
            error_message=${result#*"$FIELD_SEP"}
            set_empty_status
            diagnostic "Spotify AppleScript query failed: $error_message"
            return 1
            ;;
    esac
    split_spotify_result "$result"
    if [ -z "$SP_TITLE" ]; then
        set_empty_status
        return 1
    fi
    STATUS_EMPTY=false
    STATUS_TITLE=$SP_TITLE
    STATUS_ARTIST=$SP_ARTIST
    STATUS_ALBUM=$SP_ALBUM
    STATUS_POSITION=$(normalise_integer "$SP_POSITION")
    STATUS_DURATION=$(normalise_integer "$SP_DURATION")
    if [ "$STATUS_DURATION" -gt 0 ] && [ "$STATUS_POSITION" -gt "$STATUS_DURATION" ]; then
        STATUS_POSITION=$STATUS_DURATION
    fi
    if [ "$SP_STATE" = "playing" ]; then STATUS_PLAYING=true; else STATUS_PLAYING=false; fi
    STATUS_PLAYER="spotify"
    STATUS_SOURCE="spotify-applescript"
    STATUS_CAPABILITIES='{"play":true,"pause":true,"playPause":true,"next":true,"previous":true,"seek":true,"seekRelative":true}'
    key="$SP_TITLE""|""$SP_ARTIST""|""$SP_ALBUM"
    prepare_artwork "$key" "$SP_ART_URL"
    clear_diagnostic
    return 0
}

extract_json_string() {
    local name=$1 line=$2
    printf '%s\n' "$line" | sed -n 's/^.*"'"$name"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p'
}

extract_json_integer() {
    local name=$1 line=$2
    printf '%s\n' "$line" | sed -n 's/^.*"'"$name"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*$/\1/p'
}

valid_absolute_seek() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 11 ] && [ "$1" -le "$MAX_SEEK_MILLIS" ]
}

valid_relative_seek() {
    local absolute=${1#-}
    case "$absolute" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#absolute}" -le 11 ] && [ "$absolute" -le "$MAX_SEEK_MILLIS" ]
}

spotify_simple_control() {
    local action=$1
    run_timed "$OSASCRIPT_BIN" \
        -e 'if application "Spotify" is running then' \
        -e "tell application \"Spotify\" to $action" \
        -e 'end if' >/dev/null 2>&1
}

spotify_seek() {
    local milliseconds=$1 seconds
    seconds=$(LC_ALL=C awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", ms / 1000 }')
    run_timed "$OSASCRIPT_BIN" \
        -e 'if application "Spotify" is running then' \
        -e "tell application \"Spotify\" to set player position to $seconds" \
        -e 'end if' >/dev/null 2>&1
}

spotify_seek_relative() {
    local milliseconds=$1 seconds
    seconds=$(LC_ALL=C awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", ms / 1000 }')
    run_timed "$OSASCRIPT_BIN" \
        -e 'if application "Spotify" is running then' \
        -e 'tell application "Spotify"' \
        -e "set newPosition to (player position) + $seconds" \
        -e 'if newPosition < 0 then set newPosition to 0' \
        -e 'set player position to newPosition' \
        -e 'end tell' \
        -e 'end if' >/dev/null 2>&1
}

handle_control() {
    local line=$1 command value rc
    line=${line%$'\r'}
    [ -n "$line" ] || return 0
    if [[ "$line" == \{* ]]; then
        command=$(extract_json_string command "$line")
        [ -n "$command" ] || command=$(extract_json_string action "$line")
    else
        command=$line
    fi
    case "$command" in
        toggle|play-pause|play_pause) command=playPause ;;
        prev) command=previous ;;
        seekTo) command=seek ;;
        seekBy) command=seekRelative ;;
        refresh) return 0 ;;
        quit|close|shutdown) cleanup; exit 0 ;;
    esac
    case "$command" in
        play|pause|playPause|next|previous) value="" ;;
        seek)
            value=$(extract_json_integer positionMillis "$line")
            valid_absolute_seek "$value" || { diagnostic "ignored seek with invalid positionMillis"; return 1; }
            ;;
        seekRelative)
            value=$(extract_json_integer offsetMillis "$line")
            valid_relative_seek "$value" || { diagnostic "ignored seekRelative with invalid offsetMillis"; return 1; }
            ;;
        *)
            diagnostic "ignored unknown control command"
            return 1
            ;;
    esac
    rc=0
    case "$command" in
        play) spotify_simple_control play || rc=$? ;;
        pause) spotify_simple_control pause || rc=$? ;;
        playPause) spotify_simple_control playpause || rc=$? ;;
        next) spotify_simple_control 'next track' || rc=$? ;;
        previous) spotify_simple_control 'previous track' || rc=$? ;;
        seek) spotify_seek "$value" || rc=$? ;;
        seekRelative) spotify_seek_relative "$value" || rc=$? ;;
    esac
    if [ "$rc" -ne 0 ]; then
        diagnostic "Spotify rejected $command (Automation permission may be required)"
        return "$rc"
    fi
    clear_diagnostic
    return 0
}

refresh_status || true
if ! emit_status; then exit 0; fi
if [ "$ONCE" -eq 1 ]; then exit 0; fi

while parent_is_alive; do
    control_line=""
    if [ "$STDIN_CLOSED" -eq 0 ]; then
        IFS= read -r -t "$POLL_TIMEOUT" control_line
        read_rc=$?
        if [ "$read_rc" -eq 0 ]; then
            handle_control "$control_line" || true
        elif [ "$read_rc" -eq 1 ]; then
            STDIN_CLOSED=1
            sleep "$POLL_TIMEOUT"
        fi
        # Bash reports a timeout as a status greater than 128.
    else
        sleep "$POLL_TIMEOUT"
    fi
    parent_is_alive || break
    refresh_status || true
    if ! emit_status; then break; fi
done

exit 0
