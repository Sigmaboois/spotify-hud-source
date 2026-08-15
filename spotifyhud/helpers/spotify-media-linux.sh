#!/usr/bin/env bash
# Spotify HUD media bridge for Linux.
#
# Stdout is reserved for newline-delimited JSON status messages. Diagnostics go
# to stderr. Commands may be sent as newline-delimited JSON on stdin; see the
# companion README for the protocol.

set -u
set -o pipefail
umask 077

PROTOCOL_VERSION=1
PARENT_PID="${PPID:-}"
PARENT_MARKER=""
WATCH_PARENT=1
INTERVAL_MS=900
POLL_TIMEOUT="0.900"
REQUESTED_PLAYER="spotify"
ALLOW_ANY_PLAYER=0
INCLUDE_ARTWORK=1
ONCE=0
STDIN_CLOSED=0

PLAYERCTL_BIN=""
DBUS_SEND_BIN=""
TIMEOUT_BIN=""
CURL_BIN=""
WGET_BIN=""

ACTIVE_BACKEND=""
ACTIVE_PLAYER=""
ACTIVE_SERVICE=""
CURRENT_TRACK_ID=""

STATUS_EMPTY=true
STATUS_TITLE=""
STATUS_ARTIST=""
STATUS_ALBUM=""
STATUS_POSITION=0
STATUS_DURATION=0
STATUS_PLAYING=false
STATUS_ARTWORK=""
STATUS_PLAYER=""
STATUS_SOURCE="mpris"
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
Usage: spotify-media-linux.sh [options]

Options:
  --parent-pid PID      Exit when PID is no longer the same process (default: PPID).
  --no-parent-watch     Do not monitor a parent process.
  --interval-ms MS      Status interval, clamped to 250..10000 (default: 900).
  --player NAME         Select an MPRIS/playerctl player (default: spotify).
  --any-player          Prefer a playing MPRIS player when Spotify is absent.
  --no-artwork          Do not read or download album artwork.
  --once                Print one status and exit.
  -h, --help            Show this help.
USAGE
}

die_usage() {
    printf 'spotify-media-linux: %s\n' "$1" >&2
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
        --player)
            [ "$#" -ge 2 ] || die_usage "$1 requires a player name"
            REQUESTED_PLAYER=$2
            ALLOW_ANY_PLAYER=0
            shift 2
            ;;
        --any-player)
            ALLOW_ANY_PLAYER=1
            shift
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

PLAYERCTL_BIN=$(command_path playerctl)
DBUS_SEND_BIN=$(command_path dbus-send)
TIMEOUT_BIN=$(command_path timeout)
CURL_BIN=$(command_path curl)
WGET_BIN=$(command_path wget)

cleanup() {
    if [ -n "$ART_TMP" ] && [ -f "$ART_TMP" ]; then
        rm -f -- "$ART_TMP"
    fi
}

trap 'cleanup; exit 0' HUP INT TERM PIPE
trap cleanup EXIT

diagnostic() {
    if [ "$1" != "$LAST_DIAGNOSTIC" ]; then
        printf 'spotify-media-linux: %s\n' "$1" >&2
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
    # Minimal distributions may not ship GNU timeout. Keep a local watchdog so
    # a wedged MPRIS client still cannot orphan the helper indefinitely.
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

linux_process_marker() {
    local pid=$1 stat rest
    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r stat < "/proc/$pid/stat" || return 1
    rest=${stat##*) }
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    printf '%s' "${20}"
}

if [ "$WATCH_PARENT" -eq 1 ]; then
    PARENT_MARKER=$(linux_process_marker "$PARENT_PID" 2>/dev/null || true)
    if ! kill -0 "$PARENT_PID" 2>/dev/null; then
        exit 0
    fi
fi

parent_is_alive() {
    local current_marker
    [ "$WATCH_PARENT" -eq 0 ] && return 0
    kill -0 "$PARENT_PID" 2>/dev/null || return 1
    if [ -n "$PARENT_MARKER" ]; then
        current_marker=$(linux_process_marker "$PARENT_PID" 2>/dev/null || true)
        [ -n "$current_marker" ] && [ "$current_marker" = "$PARENT_MARKER" ] || return 1
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
    STATUS_PLAYER=""
    STATUS_SOURCE="mpris"
    STATUS_CAPABILITIES='{"play":false,"pause":false,"playPause":false,"next":false,"previous":false,"seek":false,"seekRelative":false}'
    ACTIVE_BACKEND=""
    ACTIVE_PLAYER=""
    ACTIVE_SERVICE=""
    CURRENT_TRACK_ID=""
    # The consumer clears its previous track on an empty status. Force artwork
    # to be sent again if that track later returns.
    LAST_ARTWORK_SUCCESS_KEY=""
}

emit_status() {
    local title artist album artwork player source
    title=$(json_escape "$STATUS_TITLE")
    artist=$(json_escape "$STATUS_ARTIST")
    album=$(json_escape "$STATUS_ALBUM")
    artwork=$STATUS_ARTWORK
    player=$(json_escape "$STATUS_PLAYER")
    source=$(json_escape "$STATUS_SOURCE")
    printf '{"type":"status","protocolVersion":%d,"empty":%s,"title":"%s","artist":"%s","album":"%s","positionMillis":%d,"durationMillis":%d,"playing":%s,"artwork":"%s","player":"%s","source":"%s","capabilities":%s}\n' \
        "$PROTOCOL_VERSION" "$STATUS_EMPTY" "$title" "$artist" "$album" \
        "$STATUS_POSITION" "$STATUS_DURATION" "$STATUS_PLAYING" "$artwork" \
        "$player" "$source" "$STATUS_CAPABILITIES"
}

lowercase() {
    LC_ALL=C printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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

microseconds_to_millis() {
    LC_ALL=C awk -v value="$1" 'BEGIN {
        if (value ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0f", value / 1000;
        else print "0";
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
    ensure_art_tmp || return 1
    case "$url" in
        https://*|http://*|file://*)
            if [ -n "$CURL_BIN" ]; then
                "$CURL_BIN" --location --silent --show-error --fail \
                    --proto '=http,https,file' --proto-redir '=http,https,file' \
                    --connect-timeout 2 --max-time 6 --max-filesize "$MAX_ARTWORK_BYTES" \
                    --output "$ART_TMP" -- "$url" >/dev/null 2>&1 || {
                        ART_FAILED_URL=$url
                        ART_RETRY_AT=$((now + 30))
                        return 1
                    }
            elif [ -n "$WGET_BIN" ] && [[ "$url" == http://* || "$url" == https://* ]]; then
                # Read at most 4 MiB + one block so a missing Content-Length
                # cannot turn the wget fallback into an unbounded download.
                run_timed "$WGET_BIN" -q -O - -- "$url" 2>/dev/null |
                    dd of="$ART_TMP" bs=4096 count=1025 2>/dev/null || {
                    ART_FAILED_URL=$url
                    ART_RETRY_AT=$((now + 30))
                    return 1
                }
            else
                ART_FAILED_URL=$url
                ART_RETRY_AT=$((now + 30))
                return 1
            fi
            ;;
        *)
            ART_FAILED_URL=$url
            ART_RETRY_AT=$((now + 30))
            return 1
            ;;
    esac
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

select_playerctl_player() {
    local players candidate candidate_lower request_lower chosen status
    [ -n "$PLAYERCTL_BIN" ] || return 1
    players=$(run_timed "$PLAYERCTL_BIN" --list-all 2>/dev/null || true)
    [ -n "$players" ] || return 1
    chosen=""
    request_lower=$(lowercase "$REQUESTED_PLAYER")
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        candidate_lower=$(lowercase "$candidate")
        if [ "$ALLOW_ANY_PLAYER" -eq 0 ]; then
            if [ "$candidate_lower" = "$request_lower" ] || [[ "$candidate_lower" == *"$request_lower"* ]]; then
                chosen=$candidate
                break
            fi
        else
            [ -n "$chosen" ] || chosen=$candidate
            status=$(run_timed "$PLAYERCTL_BIN" --player="$candidate" status 2>/dev/null || true)
            if [ "$status" = "Playing" ]; then
                chosen=$candidate
                break
            fi
        fi
    done <<EOF
$players
EOF
    [ -n "$chosen" ] || return 1
    printf '%s' "$chosen"
}

split_playerctl_metadata() {
    local rest=$1
    PC_TITLE=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    PC_ARTIST=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    PC_ALBUM=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    PC_ART_URL=${rest%%"$FIELD_SEP"*}
    rest=${rest#*"$FIELD_SEP"}
    PC_DURATION=$rest
}

refresh_playerctl() {
    local selected metadata status position duration key format
    selected=$(select_playerctl_player) || return 1
    format="{{title}}${FIELD_SEP}{{artist}}${FIELD_SEP}{{album}}${FIELD_SEP}{{mpris:artUrl}}${FIELD_SEP}{{mpris:length}}"
    metadata=$(run_timed "$PLAYERCTL_BIN" --player="$selected" metadata --format "$format" 2>/dev/null || true)
    split_playerctl_metadata "$metadata"
    [ -n "$PC_TITLE" ] || return 1
    status=$(run_timed "$PLAYERCTL_BIN" --player="$selected" status 2>/dev/null || true)
    position=$(run_timed "$PLAYERCTL_BIN" --player="$selected" position 2>/dev/null || true)
    position=$(seconds_to_millis "$position")
    duration=$(microseconds_to_millis "$PC_DURATION")
    position=$(normalise_integer "$position")
    duration=$(normalise_integer "$duration")
    if [ "$duration" -gt 0 ] && [ "$position" -gt "$duration" ]; then position=$duration; fi

    STATUS_EMPTY=false
    STATUS_TITLE=$PC_TITLE
    STATUS_ARTIST=$PC_ARTIST
    STATUS_ALBUM=$PC_ALBUM
    STATUS_POSITION=$position
    STATUS_DURATION=$duration
    if [ "$status" = "Playing" ]; then STATUS_PLAYING=true; else STATUS_PLAYING=false; fi
    STATUS_PLAYER=$selected
    STATUS_SOURCE="mpris-playerctl"
    STATUS_CAPABILITIES='{"play":true,"pause":true,"playPause":true,"next":true,"previous":true,"seek":true,"seekRelative":true}'
    ACTIVE_BACKEND="playerctl"
    ACTIVE_PLAYER=$selected
    ACTIVE_SERVICE=""
    CURRENT_TRACK_ID=""
    key="$selected$FIELD_SEP$PC_TITLE$FIELD_SEP$PC_ARTIST$FIELD_SEP$PC_ALBUM"
    prepare_artwork "$key" "$PC_ART_URL"
    return 0
}

dbus_list_services() {
    run_timed "$DBUS_SEND_BIN" --session --print-reply \
        --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.ListNames 2>/dev/null |
        sed -n 's/^[[:space:]]*string "\(org\.mpris\.MediaPlayer2\.[^"]*\)"[[:space:]]*$/\1/p'
}

dbus_get_property() {
    run_timed "$DBUS_SEND_BIN" --session --print-reply --reply-timeout=3000 \
        --dest="$1" /org/mpris/MediaPlayer2 \
        org.freedesktop.DBus.Properties.Get \
        string:org.mpris.MediaPlayer2.Player string:"$2" 2>/dev/null
}

dbus_parse_string() {
    local key=$1
    LC_ALL=C awk -v wanted="$key" '
        index($0, "string \"" wanted "\"") { found=1; next }
        found && /variant[[:space:]]+string[[:space:]]+"/ {
            line=$0
            sub(/^.*variant[[:space:]]+string[[:space:]]+"/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line
            exit
        }
        found && /^[[:space:]]*string[[:space:]]+"/ {
            line=$0
            sub(/^[[:space:]]*string[[:space:]]+"/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line
            exit
        }
        found && /dict entry/ { exit }
    '
}

dbus_parse_int64() {
    local key=$1
    LC_ALL=C awk -v wanted="$key" '
        index($0, "string \"" wanted "\"") { found=1; next }
        found && /variant[[:space:]]+(u?int64|u?int32)[[:space:]]+/ {
            line=$0
            sub(/^.*variant[[:space:]]+(u?int64|u?int32)[[:space:]]+/, "", line)
            sub(/[[:space:]].*$/, "", line)
            print line
            exit
        }
        found && /dict entry/ { exit }
    '
}

dbus_parse_object_path() {
    local key=$1
    LC_ALL=C awk -v wanted="$key" '
        index($0, "string \"" wanted "\"") { found=1; next }
        found && /variant[[:space:]]+object path[[:space:]]+"/ {
            line=$0
            sub(/^.*variant[[:space:]]+object path[[:space:]]+"/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line
            exit
        }
        found && /dict entry/ { exit }
    '
}

dbus_unescape() {
    local input=$1 output="" char next
    while [ -n "$input" ]; do
        char=${input:0:1}
        input=${input:1}
        if [ "$char" != "\\" ] || [ -z "$input" ]; then
            output+=$char
            continue
        fi
        next=${input:0:1}
        input=${input:1}
        case "$next" in
            n) output+=$'\n' ;;
            r) output+=$'\r' ;;
            t) output+=$'\t' ;;
            b) output+=$'\b' ;;
            f) output+=$'\f' ;;
            '\') output+='\' ;;
            '"') output+='"' ;;
            *) output+="\\$next" ;;
        esac
    done
    printf '%s' "$output"
}

dbus_simple_string_value() {
    sed -n 's/^.*variant[[:space:]]*string[[:space:]]*"\([^"]*\)".*$/\1/p' | head -n 1
}

dbus_simple_int64_value() {
    sed -n 's/^.*variant[[:space:]]*\(u\{0,1\}int64\|u\{0,1\}int32\)[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*$/\2/p' | head -n 1
}

select_dbus_service() {
    local services service lower request_lower chosen playback
    [ -n "$DBUS_SEND_BIN" ] || return 1
    services=$(dbus_list_services || true)
    [ -n "$services" ] || return 1
    chosen=""
    request_lower=$(lowercase "$REQUESTED_PLAYER")
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        lower=$(lowercase "$service")
        if [ "$ALLOW_ANY_PLAYER" -eq 0 ]; then
            if [ "$lower" = "$request_lower" ] || [[ "$lower" == *"$request_lower"* ]]; then
                chosen=$service
                break
            fi
        else
            [ -n "$chosen" ] || chosen=$service
            playback=$(dbus_get_property "$service" PlaybackStatus | dbus_simple_string_value)
            if [ "$playback" = "Playing" ]; then
                chosen=$service
                break
            fi
        fi
    done <<EOF
$services
EOF
    [ -n "$chosen" ] || return 1
    printf '%s' "$chosen"
}

refresh_dbus() {
    local service metadata status_raw position_raw status position title artist album art_url duration key
    service=$(select_dbus_service) || return 1
    metadata=$(dbus_get_property "$service" Metadata || true)
    [ -n "$metadata" ] || return 1
    title=$(printf '%s\n' "$metadata" | dbus_parse_string xesam:title)
    [ -n "$title" ] || return 1
    artist=$(printf '%s\n' "$metadata" | dbus_parse_string xesam:artist)
    album=$(printf '%s\n' "$metadata" | dbus_parse_string xesam:album)
    art_url=$(printf '%s\n' "$metadata" | dbus_parse_string mpris:artUrl)
    title=$(dbus_unescape "$title")
    artist=$(dbus_unescape "$artist")
    album=$(dbus_unescape "$album")
    art_url=$(dbus_unescape "$art_url")
    duration=$(printf '%s\n' "$metadata" | dbus_parse_int64 mpris:length)
    CURRENT_TRACK_ID=$(printf '%s\n' "$metadata" | dbus_parse_object_path mpris:trackid)
    status_raw=$(dbus_get_property "$service" PlaybackStatus || true)
    status=$(printf '%s\n' "$status_raw" | dbus_simple_string_value)
    position_raw=$(dbus_get_property "$service" Position || true)
    position=$(printf '%s\n' "$position_raw" | dbus_simple_int64_value)
    position=$(microseconds_to_millis "$position")
    duration=$(microseconds_to_millis "$duration")
    position=$(normalise_integer "$position")
    duration=$(normalise_integer "$duration")
    if [ "$duration" -gt 0 ] && [ "$position" -gt "$duration" ]; then position=$duration; fi

    STATUS_EMPTY=false
    STATUS_TITLE=$title
    STATUS_ARTIST=$artist
    STATUS_ALBUM=$album
    STATUS_POSITION=$position
    STATUS_DURATION=$duration
    if [ "$status" = "Playing" ]; then STATUS_PLAYING=true; else STATUS_PLAYING=false; fi
    STATUS_PLAYER=${service#org.mpris.MediaPlayer2.}
    STATUS_SOURCE="mpris-dbus"
    STATUS_CAPABILITIES='{"play":true,"pause":true,"playPause":true,"next":true,"previous":true,"seek":true,"seekRelative":true}'
    ACTIVE_BACKEND="dbus"
    ACTIVE_PLAYER=""
    ACTIVE_SERVICE=$service
    key="$service$FIELD_SEP$title$FIELD_SEP$artist$FIELD_SEP$album"
    prepare_artwork "$key" "$art_url"
    return 0
}

refresh_status() {
    STATUS_ARTWORK=""
    if refresh_playerctl; then
        clear_diagnostic
        return 0
    fi
    if refresh_dbus; then
        clear_diagnostic
        return 0
    fi
    set_empty_status
    if [ -z "$PLAYERCTL_BIN" ] && [ -z "$DBUS_SEND_BIN" ]; then
        diagnostic "install playerctl (preferred) or dbus-send to read MPRIS sessions"
    fi
    return 1
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

ensure_active_backend() {
    [ -n "$ACTIVE_BACKEND" ] && return 0
    refresh_status >/dev/null 2>&1 || true
    [ -n "$ACTIVE_BACKEND" ]
}

playerctl_control() {
    local command=$1 value=${2:-} seconds absolute
    case "$command" in
        play) run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" play ;;
        pause) run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" pause ;;
        playPause) run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" play-pause ;;
        next) run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" next ;;
        previous) run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" previous ;;
        seek)
            seconds=$(LC_ALL=C awk -v ms="$value" 'BEGIN { printf "%.3f", ms / 1000 }')
            run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" position "$seconds"
            ;;
        seekRelative)
            if [ "$value" -lt 0 ]; then
                absolute=$((-value))
                seconds=$(LC_ALL=C awk -v ms="$absolute" 'BEGIN { printf "%.3f-", ms / 1000 }')
            else
                seconds=$(LC_ALL=C awk -v ms="$value" 'BEGIN { printf "%.3f+", ms / 1000 }')
            fi
            run_timed "$PLAYERCTL_BIN" --player="$ACTIVE_PLAYER" position "$seconds"
            ;;
    esac >/dev/null 2>&1
}

dbus_control() {
    local command=$1 value=${2:-} method micros
    case "$command" in
        play|pause|playPause|next|previous)
            case "$command" in
                play) method=Play ;;
                pause) method=Pause ;;
                playPause) method=PlayPause ;;
                next) method=Next ;;
                previous) method=Previous ;;
            esac
            run_timed "$DBUS_SEND_BIN" --session --type=method_call \
                --dest="$ACTIVE_SERVICE" /org/mpris/MediaPlayer2 \
                "org.mpris.MediaPlayer2.Player.$method"
            ;;
        seek)
            [ -n "$CURRENT_TRACK_ID" ] || return 1
            micros=$((value * 1000))
            run_timed "$DBUS_SEND_BIN" --session --type=method_call \
                --dest="$ACTIVE_SERVICE" /org/mpris/MediaPlayer2 \
                org.mpris.MediaPlayer2.Player.SetPosition \
                objpath:"$CURRENT_TRACK_ID" int64:"$micros"
            ;;
        seekRelative)
            micros=$((value * 1000))
            run_timed "$DBUS_SEND_BIN" --session --type=method_call \
                --dest="$ACTIVE_SERVICE" /org/mpris/MediaPlayer2 \
                org.mpris.MediaPlayer2.Player.Seek int64:"$micros"
            ;;
    esac >/dev/null 2>&1
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
    ensure_active_backend || { diagnostic "control requested with no active media session"; return 1; }
    rc=0
    case "$ACTIVE_BACKEND" in
        playerctl) playerctl_control "$command" "$value" || rc=$? ;;
        dbus) dbus_control "$command" "$value" || rc=$? ;;
        *) rc=1 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        diagnostic "media player rejected $command"
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
