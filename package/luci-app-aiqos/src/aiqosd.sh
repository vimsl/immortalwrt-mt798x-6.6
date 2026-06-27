
#!/bin/sh /etc/rc.common
# /etc/init.d/aiqosd
# AIQoS main daemon - manages all sub-modules
# V1.0.1: HNAT coexistence - never disables hardware offloading

START=90
STOP=10
USE_PROCD=1

NAME=aiqosd

. /lib/functions.sh
. /lib/functions/procd.sh

# Check if HNAT is active - if so, preserve hardware offloading
hnat_ready() {
    if [ -f /sys/kernel/debug/hnat/hnat_entry ]; then
        grep -q "usb0" /sys/kernel/debug/hnat/hnat_entry 2>/dev/null && return 0
    fi
    if [ -f /sys/kernel/debug/hnat/all_entry ]; then
        grep -q "state=BIND" /sys/kernel/debug/hnat/all_entry 2>/dev/null && return 0
    fi
    return 1
}

# Read UCI configuration
get_config() {
    config_load aiqos
    config_get enabled switches enable_cake "1"
    config_get sinr_enabled switches enable_sinr "1"
    config_get wifi_enabled switches enable_wifi "0"
    config_get ack_enabled switches enable_ack "0"
    config_get night_lock_enabled switches enable_night_lock "0"
    config_get ebpf_enabled switches enable_ebpf "0"
    config_get ai_enabled switches enable_ai "0"
    config_get poll_interval advanced poll_interval "2"
    config_get min_bandwidth advanced min_bandwidth "5"
}

# Ensure hardware offloading stays enabled when HNAT is active
preserve_hnat() {
    if hnat_ready; then
        logger -t aiqosd "HNAT active - preserving hardware flow offloading"
        uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null
        uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null
        uci commit firewall 2>/dev/null
        /etc/init.d/firewall restart 2>/dev/null &
    fi
}

# Start cake-autorate
start_cake_autorate() {
    if [ "$enabled" = "1" ]; then
        if [ -f "/etc/init.d/cake-autorate" ]; then
            logger -t aiqosd "Starting cake-autorate"
            /etc/init.d/cake-autorate start 2>/dev/null
        elif command -v cake-autorate.sh >/dev/null 2>&1; then
            logger -t aiqosd "Starting cake-autorate (direct)"
            cake-autorate.sh start 2>/dev/null
        else
            logger -t aiqosd "WARNING: cake-autorate not found"
        fi
    else
        logger -t aiqosd "cake-autorate disabled, stopping"
        /etc/init.d/cake-autorate stop 2>/dev/null
        killall cake-autorate.sh 2>/dev/null
    fi
}

# Start SINR injector
start_sinr_injector() {
    if [ "$sinr_enabled" = "1" ]; then
        if [ -f "/usr/bin/sinr_injector.sh" ]; then
            logger -t aiqosd "Starting SINR injector"
            start-stop-daemon -S -b -m -p /var/run/sinr_injector.pid \
                -x /usr/bin/sinr_injector.sh
        else
            logger -t aiqosd "WARNING: sinr_injector.sh not found"
        fi
    else
        logger -t aiqosd "SINR injector disabled"
        start-stop-daemon -K -p /var/run/sinr_injector.pid 2>/dev/null
    fi
}

# Start WiFi optimizer
start_wifi_optimizer() {
    if [ "$wifi_enabled" = "1" ]; then
        if /usr/bin/condition_detect.sh wifi | grep -q "true"; then
            if [ -f "/usr/bin/TriTon.sh" ]; then
                logger -t aiqosd "Starting TriTon WiFi optimizer"
                /usr/bin/TriTon.sh start 2>/dev/null
            elif [ -f "/etc/init.d/triton" ]; then
                logger -t aiqosd "Starting TriTon (init.d)"
                /etc/init.d/triton start 2>/dev/null
            else
                logger -t aiqosd "WARNING: TriTon not found"
            fi
        else
            logger -t aiqosd "WiFi optimizer skipped: no WiFi hardware"
        fi
    else
        logger -t aiqosd "WiFi optimizer disabled"
        /usr/bin/TriTon.sh stop 2>/dev/null
        /etc/init.d/triton stop 2>/dev/null
    fi
}

# Start ACK optimizer
start_ack_optimizer() {
    if [ "$ack_enabled" = "1" ]; then
        logger -t aiqosd "Enabling aggressive ACK filter"
        local iface=$(tc qdisc show 2>/dev/null | grep -E "cake.*root" | \
                      awk '{print $5}' | head -1)
        if [ -n "$iface" ]; then
            tc qdisc change dev "$iface" root cake ack-filter aggressive 2>/dev/null
            logger -t aiqosd "ACK filter set to aggressive on $iface"
        else
            logger -t aiqosd "WARNING: No CAKE interface found"
        fi
    else
        logger -t aiqosd "ACK filter disabled (using default)"
        local iface=$(tc qdisc show 2>/dev/null | grep -E "cake.*root" | \
                      awk '{print $5}' | head -1)
        if [ -n "$iface" ]; then
            tc qdisc change dev "$iface" root cake ack-filter 2>/dev/null
        fi
    fi
}

# Start night lock
start_night_lock() {
    if [ "$night_lock_enabled" = "1" ]; then
        if ! crontab -l 2>/dev/null | grep -q "night_lock.sh"; then
            logger -t aiqosd "Installing night lock cron job"
            (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/night_lock.sh") | crontab -
        fi
        logger -t aiqosd "Night lock enabled"
    else
        if crontab -l 2>/dev/null | grep -q "night_lock.sh"; then
            logger -t aiqosd "Removing night lock cron job"
            crontab -l 2>/dev/null | grep -v "night_lock.sh" | crontab -
        fi
        logger -t aiqosd "Night lock disabled"
    fi
}

# Start eBPF
start_ebpf() {
    if [ "$ebpf_enabled" = "1" ]; then
        if /usr/bin/condition_detect.sh ebpf | grep -q "true"; then
            logger -t aiqosd "eBPF support detected, loading programs"
            logger -t aiqosd "eBPF loaded (placeholder - need compiled BPF object)"
        else
            logger -t aiqosd "eBPF skipped: kernel not supported"
        fi
    else
        logger -t aiqosd "eBPF disabled"
    fi
}

# Start AI predictor
start_ai_predictor() {
    if [ "$ai_enabled" = "1" ]; then
        logger -t aiqosd "AI predictor enabled (experimental)"
    else
        logger -t aiqosd "AI predictor disabled"
    fi
}

# ====== procd start ======
start_service() {
    logger -t aiqosd "========== AIQoS Starting =========="

    # Kill any old instances
    killall -9 aiqosd.sh 2>/dev/null
    killall -9 sinr_injector.sh 2>/dev/null
    rm -f /var/run/aiqosd.pid
    rm -f /tmp/sinr_injector.lock
    sleep 1

    # Preserve HNAT hardware acceleration
    preserve_hnat

    get_config

    # Start sub-modules in dependency order
    start_cake_autorate
    sleep 1
    start_sinr_injector
    start_wifi_optimizer
    start_ack_optimizer
    start_night_lock
    start_ebpf
    start_ai_predictor

    echo $$ > /var/run/aiqosd.pid

    logger -t aiqosd "AIQoS started (PID=$$)"
}

# ====== Stop ======
stop_service() {
    logger -t aiqosd "========== AIQoS Stopping =========="

    killall -9 aiqosd.sh 2>/dev/null
    killall -9 sinr_injector.sh 2>/dev/null
    start-stop-daemon -K -p /var/run/sinr_injector.pid 2>/dev/null
    start-stop-daemon -K -p /var/run/aiqosd.pid 2>/dev/null

    /etc/init.d/cake-autorate stop 2>/dev/null
    killall cake-autorate.sh 2>/dev/null

    /usr/bin/TriTon.sh stop 2>/dev/null
    /etc/init.d/triton stop 2>/dev/null

    crontab -l 2>/dev/null | grep -v "night_lock.sh" | crontab - 2>/dev/null

    # Restore default CAKE ack-filter
    local iface=$(tc qdisc show 2>/dev/null | grep -E "cake.*root" | \
                  awk '{print $5}' | head -1)
    if [ -n "$iface" ]; then
        tc qdisc change dev "$iface" root cake ack-filter 2>/dev/null
    fi

    rm -f /var/run/aiqosd.pid
    rm -f /tmp/sinr_injector.lock
    rm -f /tmp/night_lock.lock

    logger -t aiqosd "AIQoS stopped"
}

# ====== Restart ======
reload_service() {
    stop
    sleep 1
    start
}
