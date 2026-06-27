#!/bin/sh
# /usr/bin/sinr_injector.sh
# SINR injection daemon - reads 5G signal quality, outputs coefficient for cake-autorate
# V1.0.1: Added SINR range validation (-30~40 dB)

SINR_FILE="/tmp/aiqos_sinr_coeff"
SINR_LOCK="/tmp/sinr_injector.lock"
LOG_FILE="/var/log/sinr_injector.log"
LOG_MAX_SIZE=102400
BASE_INTERVAL=${SINR_INJECTOR_INTERVAL:-2}
UQMI_TIMEOUT=3
BACKOFF_MAX=15
CONSECUTIVE_TIMEOUTS=0
MAX_TIMEOUTS=5

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    local size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
        tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (was ${size} bytes)"
    fi
}

check_night_lock() {
    if [ -f "/tmp/night_lock.lock" ]; then
        log "night_lock running, skipping this cycle"
        return 1
    fi
    return 0
}

create_lock() {
    echo $$ > "$SINR_LOCK"
}

remove_lock() {
    rm -f "$SINR_LOCK"
}

detect_modem() {
    for dev in /dev/cdc-wdm0 /dev/cdc-wdm1 /dev/cdc-wdm2; do
        if [ -c "$dev" ]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

uqmi_safe() {
    local tmpout=$(mktemp)
    uqmi "$@" > "$tmpout" 2>/dev/null &
    local pid=$!
    local elapsed=0
    while [ "$elapsed" -lt "$UQMI_TIMEOUT" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$tmpout"
        return 1
    fi
    wait "$pid" 2>/dev/null
    local ret=$?
    cat "$tmpout"
    rm -f "$tmpout"
    return "$ret"
}

get_sinr_uqmi() {
    local dev=$(detect_modem)
    [ -z "$dev" ] && return 1

    local info=$(uqmi_safe -d "$dev" --get-signal-info)
    local ret=$?
    if [ "$ret" -ne 0 ] || [ -z "$info" ]; then
        return 1
    fi

    if [ $((RANDOM % 50)) -eq 0 ]; then
        log "uqmi raw: $info"
    fi

    local sinr=""
    sinr=$(echo "$info" | grep -oP '"sinr"\s*:\s*-?[0-9]+\.?[0-9]*' | head -1 | grep -oP ':\s*-?[0-9]+\.?[0-9]*' | tr -d ': ')

    if [ -z "$sinr" ] || [ "$sinr" = "null" ]; then
        local rsrp=$(echo "$info" | grep -oP '"rsrp"\s*:\s*-?[0-9]+' | head -1 | grep -oP ':\s*-?[0-9]+' | tr -d ': ')
        if [ -n "$rsrp" ] && [ "$rsrp" != "null" ]; then
            sinr=$(echo "scale=1; ($rsrp + 140) / 5" | bc 2>/dev/null)
        fi
    fi

    # Range validation: SINR -30 ~ 40 dB
    if [ -n "$sinr" ]; then
        local sinr_int=$(printf "%.0f" "$sinr" 2>/dev/null)
        if [ -n "$sinr_int" ] && [ "$sinr_int" -ge -30 ] && [ "$sinr_int" -le 40 ]; then
            echo "$sinr"
            return 0
        else
            log "WARNING: SINR out of range: $sinr (expected -30~40)"
            return 1
        fi
    fi
    return 1
}

get_sinr_qmodem() {
    if command -v qmodem >/dev/null 2>&1; then
        local tmpout=$(mktemp)
        qmodem signal > "$tmpout" 2>/dev/null &
        local pid=$!
        local elapsed=0
        while [ "$elapsed" -lt 3 ]; do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            sleep 1; elapsed=$((elapsed + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        wait "$pid" 2>/dev/null
        local info=$(cat "$tmpout")
        rm -f "$tmpout"
        local sinr=$(echo "$info" | grep -i "sinr" | awk '{print $NF}' | sed 's/[^0-9.-]//g')
        echo "$sinr"
    fi
}

get_sinr_sysfs() {
    if [ -f /sys/class/net/wwan0/carrier ]; then
        local rssi=$(cat /sys/class/net/wwan0/rssi 2>/dev/null)
        if [ -n "$rssi" ]; then
            echo "scale=1; ($rssi + 140) / 5" | bc 2>/dev/null
        fi
    fi
}

get_sinr() {
    local sinr=$(get_sinr_uqmi)
    if [ -z "$sinr" ] || [ "$sinr" = "null" ]; then
        sinr=$(get_sinr_qmodem)
    fi
    if [ -z "$sinr" ] || [ "$sinr" = "null" ]; then
        sinr=$(get_sinr_sysfs)
    fi
    echo "$sinr"
}

sinr_to_coeff() {
    local sinr=$1
    if [ -z "$sinr" ] || [ "$sinr" = "null" ] || [ -z "$(echo "$sinr" | grep -E '^[0-9.+-]+$')" ]; then
        echo "1.0"
        return
    fi
    local sinr_int=$(printf "%.0f" "$sinr" 2>/dev/null)
    [ -z "$sinr_int" ] && { echo "1.0"; return; }

    if [ "$sinr_int" -ge 20 ]; then echo "1.0"
    elif [ "$sinr_int" -ge 15 ]; then echo "0.8"
    elif [ "$sinr_int" -ge 10 ]; then echo "0.6"
    elif [ "$sinr_int" -ge 5 ]; then echo "0.4"
    elif [ "$sinr_int" -ge 0 ]; then echo "0.2"
    else echo "0.1"
    fi
}

ewma_filter() {
    local current=$1
    local alpha=0.3
    local last=""
    if [ -f "$SINR_FILE" ]; then
        last=$(cat "$SINR_FILE" 2>/dev/null | head -1)
    fi
    if [ -z "$last" ] || [ -z "$(echo "$last" | grep -E '^[0-9.]+$')" ]; then
        echo "$current"
        return
    fi
    echo "scale=3; $alpha * $current + (1-$alpha) * $last" | bc 2>/dev/null || echo "$current"
}

main() {
    log "SINR Injector started (interval=${BASE_INTERVAL}s)"
    create_lock

    local dev=$(detect_modem)
    if [ -z "$dev" ]; then
        log "WARNING: No modem device found, will retry..."
    else
        log "Modem device: $dev"
    fi

    local counter=0
    while true; do
        if ! check_night_lock; then
            sleep 5
            continue
        fi
        local raw_sinr=$(get_sinr)
        local sinr_ret=$?

        if [ "$sinr_ret" -ne 0 ] || [ -z "$raw_sinr" ] || [ "$raw_sinr" = "null" ]; then
            CONSECUTIVE_TIMEOUTS=$((CONSECUTIVE_TIMEOUTS + 1))
            if [ "$CONSECUTIVE_TIMEOUTS" -ge "$MAX_TIMEOUTS" ]; then
                log "WARNING: ${CONSECUTIVE_TIMEOUTS} consecutive timeouts"
            fi
        else
            CONSECUTIVE_TIMEOUTS=0
        fi

        local coeff=$(sinr_to_coeff "$raw_sinr")
        local smoothed=$(ewma_filter "$coeff")
        local timestamp=$(date '+%s')
        echo "$smoothed $raw_sinr $timestamp" > "$SINR_FILE"

        counter=$((counter + 1))
        if [ $((counter % 5)) -eq 0 ]; then
            log "SINR=${raw_sinr}dB -> coeff=${smoothed} (timeouts=${CONSECUTIVE_TIMEOUTS})"
        fi

        local sleep_time=$BASE_INTERVAL
        if [ "$CONSECUTIVE_TIMEOUTS" -ge "$MAX_TIMEOUTS" ]; then
            sleep_time=$((BACKOFF_MAX < BASE_INTERVAL * CONSECUTIVE_TIMEOUTS ? BACKOFF_MAX : BASE_INTERVAL * CONSECUTIVE_TIMEOUTS))
        fi
        local jitter=$((RANDOM % 3))
        sleep_time=$((sleep_time + jitter))
        sleep "$sleep_time"
    done
}

trap 'remove_lock; log "SINR Injector stopped"; exit 0' INT TERM
main
