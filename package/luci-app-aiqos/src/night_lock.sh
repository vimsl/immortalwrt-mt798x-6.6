#!/bin/sh
# /usr/bin/night_lock.sh
# Night cell locking script
# Cron: 0 3 * * * /usr/bin/night_lock.sh

LOCK_FILE="/tmp/night_lock.lock"
LOG_FILE="/var/log/night_lock.log"
BACKUP_DIR="/tmp/night_lock_backup"
TIMEOUT=30
MODEM_DEV=""
AT_PORT=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    logger -t night_lock "$1"
}

cleanup() {
    resume_qmodem
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

detect_modem() {
    for dev in /dev/cdc-wdm0 /dev/cdc-wdm1 /dev/cdc-wdm2; do
        if [ -c "$dev" ]; then
            MODEM_DEV="$dev"
            log "Found uqmi device: $dev"
            break
        fi
    done
    for port in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB0; do
        if [ -c "$port" ]; then
            AT_PORT="$port"
            log "Found AT port: $port"
            break
        fi
    done
    if [ -z "$MODEM_DEV" ] && pgrep -x "ModemManager" >/dev/null 2>&1; then
        log "Using ModemManager fallback"
        return 0
    fi
    if [ -z "$MODEM_DEV" ] && [ -z "$AT_PORT" ]; then
        log "ERROR: No modem device or AT port found"
        return 1
    fi
    return 0
}

QMODEM_PID=""
pause_qmodem() {
    if [ -f "/tmp/sinr_injector.lock" ]; then
        log "sinr_injector running, waiting..."
        local wait=0
        while [ -f "/tmp/sinr_injector.lock" ] && [ "$wait" -lt 10 ]; do
            sleep 1; wait=$((wait + 1))
        done
    fi
    QMODEM_PID=$(pgrep -f "qmodem" 2>/dev/null | head -1)
    if [ -n "$QMODEM_PID" ]; then
        local state=$(cat /proc/$QMODEM_PID/status 2>/dev/null | grep "^State:" | awk '{print $2}')
        log "qmodem state before STOP: $state"
        kill -STOP "$QMODEM_PID" 2>/dev/null
        sleep 1
        local new_state=$(cat /proc/$QMODEM_PID/status 2>/dev/null | grep "^State:" | awk '{print $2}')
        if [ "$new_state" = "T" ] || [ "$new_state" = "t" ]; then
            log "Paused qmodem (PID=$QMODEM_PID)"
        else
            log "WARNING: qmodem STOP may not have taken effect (state=$new_state)"
            QMODEM_PID=""
        fi
    fi
}

resume_qmodem() {
    if [ -n "$QMODEM_PID" ]; then
        kill -CONT "$QMODEM_PID" 2>/dev/null
        sleep 1
        local state=$(cat /proc/$QMODEM_PID/status 2>/dev/null | grep "^State:" | awk '{print $2}')
        if [ "$state" = "S" ] || [ "$state" = "R" ]; then
            log "Resumed qmodem (PID=$QMODEM_PID)"
        else
            log "WARNING: qmodem may not have recovered (state=$state)"
        fi
        QMODEM_PID=""
    fi
}

send_at() {
    local cmd="$1"
    pause_qmodem
    if [ -n "$AT_PORT" ]; then
        echo -e "${cmd}\r" > "$AT_PORT" 2>/dev/null
        sleep 1
        cat "$AT_PORT" 2>/dev/null | head -5
    elif [ -n "$MODEM_DEV" ]; then
        uqmi -d "$MODEM_DEV" --send-at "$cmd" > /dev/null 2>&1 &
        local pid=$!
        local elapsed=0
        while [ "$elapsed" -lt 5 ]; do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            sleep 1; elapsed=$((elapsed + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        wait "$pid" 2>/dev/null
    elif pgrep -x "ModemManager" >/dev/null 2>&1; then
        mmcli -m 0 --command="$cmd" 2>/dev/null
    fi
    resume_qmodem
}

get_signal() {
    if [ -n "$MODEM_DEV" ]; then
        local tmpout=$(mktemp)
        uqmi -d "$MODEM_DEV" --get-signal-info > "$tmpout" 2>/dev/null &
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
        local sinr=$(echo "$info" | grep -o '"sinr":[0-9.e+-]*' | head -1 | cut -d: -f2)
        local rsrp=$(echo "$info" | grep -o '"rsrp":-*[0-9]*' | head -1 | cut -d: -f2)
        echo "sinr=${sinr:-0} rsrp=${rsrp:-0}"
    fi
}

backup_current() {
    mkdir -p "$BACKUP_DIR"
    get_signal > "$BACKUP_DIR/signal_before.txt" 2>/dev/null
    send_at "AT+COPS?" > "$BACKUP_DIR/cops_before.txt" 2>/dev/null
    log "Backup completed"
}

scan_cells() {
    log "Scanning cells..."
    local cell_info=$(send_at "AT+GTCCINFO?")
    if [ -z "$cell_info" ] || echo "$cell_info" | grep -q "ERROR"; then
        log "Cell scan failed, using default target"
        echo "312 5078 78"
        return
    fi
    local best_pci="" best_freq="" best_band="" best_sinr=-999
    while IFS=, read -r rat pci freq band rsrp rsrq sinr; do
        sinr=$(echo "$sinr" | sed 's/[^0-9.-]//g')
        if [ -n "$sinr" ] && [ "$(echo "$sinr > $best_sinr" | bc 2>/dev/null)" = "1" ]; then
            best_sinr="$sinr"; best_pci="$pci"; best_freq="$freq"; best_band="$band"
        fi
    done <<SCANEOF
$(echo "$cell_info" | grep "+GTCCINFO:")
SCANEOF
    if [ -n "$best_pci" ]; then
        log "Best cell: PCI=$best_pci Freq=$best_freq Band=$best_band SINR=$best_sinr"
        echo "$best_pci $best_freq $best_band"
    else
        log "No valid cell found, using default"
        echo "312 5078 78"
    fi
}

lock_cell() {
    local target_pci="$1" target_freq="$2" target_band="$3"
    log "Locking to PCI=${target_pci}, Freq=${target_freq}"
    send_at "AT+GTRNDIS=0,1"
    sleep 2
    send_at "AT+GTCELLLOCK=1,1,0,${target_freq},${target_pci},1,${target_band}"
    send_at "AT+CFUN=15"
    log "Lock command sent, modem rebooting..."
}

watchdog() {
    local start_time=$(date +%s) success=0
    log "Watchdog started (timeout=${TIMEOUT}s)"
    while [ $(($(date +%s) - start_time)) -lt "$TIMEOUT" ]; do
        local reg=$(send_at "AT+COPS?")
        if echo "$reg" | grep -q "+COPS: 0,0"; then sleep 2; continue; fi
        if [ -n "$reg" ] && ! echo "$reg" | grep -q "ERROR"; then
            log "Network registered: $reg"; success=1; break
        fi
        sleep 2
    done
    if [ "$success" -eq 0 ]; then
        log "ERROR: Network registration timeout!"
        return 1
    fi
    send_at "AT+GTRNDIS=1,1"
    sleep 3
    local signal=$(get_signal)
    log "Signal after lock: $signal"
    return 0
}

rollback() {
    log "ROLLBACK: Restoring previous configuration"
    send_at "AT+GTCELLLOCK=0"; send_at "AT+GTFREQLOCK=0,0"
    send_at "AT+CFUN=15"; sleep 8
    send_at "AT+GTRNDIS=1,1"; sleep 3
    local signal=$(get_signal)
    log "Rollback completed, signal: $signal"
}

main() {
    log "========== Night Lock Started =========="
    if ! detect_modem; then log "ERROR: Modem not available, exit"; exit 1; fi
    backup_current
    local signal=$(get_signal)
    log "Current signal: $signal"
    local sinr=$(echo "$signal" | grep -o "sinr=[0-9.-]*" | cut -d= -f2)
    sinr=$(echo "$sinr" | sed 's/[^0-9.-]//g')
    local sinr_int=$(printf "%.0f" "$sinr" 2>/dev/null || echo 0)
    if [ "$sinr_int" -gt 15 ]; then
        log "Signal already good (SINR=${sinr}dB), skip locking"; exit 0
    fi
    local cell_info=$(scan_cells)
    local target_pci=$(echo "$cell_info" | awk '{print $1}')
    local target_freq=$(echo "$cell_info" | awk '{print $2}')
    local target_band=$(echo "$cell_info" | awk '{print $3}')
    lock_cell "$target_pci" "$target_freq" "$target_band"
    if watchdog; then log "Night lock SUCCESS: PCI=${target_pci}"
    else log "Night lock FAILED: rolling back"; rollback; fi
    log "========== Night Lock Finished =========="
}

main
