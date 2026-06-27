
#!/bin/sh
# /usr/bin/condition_detect.sh
# Capability detection module - detects system hardware capabilities
# V1.0.1: Added hnat_ready() for HNAT coexistence

OUTPUT_FILE="/tmp/aiqos_capability.json"

# Check if HNAT hardware acceleration is active on usb0
hnat_ready() {
    if [ -f /sys/kernel/debug/hnat/hnat_entry ]; then
        grep -q "usb0" /sys/kernel/debug/hnat/hnat_entry 2>/dev/null && return 0
    fi
    if [ -f /sys/kernel/debug/hnat/all_entry ]; then
        grep -q "state=BIND" /sys/kernel/debug/hnat/all_entry 2>/dev/null && return 0
    fi
    return 1
}

# Detect Wi-Fi hardware
detect_wifi() {
    if [ -d "/sys/class/ieee80211/phy0" ] && command -v iw >/dev/null 2>&1; then
        local wlan_iface=$(iw dev 2>/dev/null | grep -E "^[[:space:]]*Interface" | awk '{print $2}' | head -1)
        if [ -n "$wlan_iface" ]; then
            echo "true"
            return
        fi
    fi
    echo "false"
}

# Detect eBPF support
detect_ebpf() {
    if [ -f "/proc/sys/kernel/unprivileged_bpf_disabled" ]; then
        if [ -f "/proc/sys/net/core/bpf_jit_enable" ]; then
            local jit_enabled=$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null)
            if [ "$jit_enabled" = "1" ]; then
                echo "true"
                return
            fi
        fi
    fi
    echo "false"
}

# Detect Modem
detect_modem() {
    # Method 1: Check uqmi devices
    for dev in /dev/cdc-wdm0 /dev/cdc-wdm1 /dev/cdc-wdm2; do
        if [ -c "$dev" ]; then
            echo "true"
            return
        fi
    done

    # Method 2: Check wwan network interface
    if [ -d "/sys/class/net/wwan0" ]; then
        local carrier=$(cat /sys/class/net/wwan0/carrier 2>/dev/null)
        if [ -n "$carrier" ] && [ "$carrier" != "0" ]; then
            echo "true"
            return
        fi
        echo "true"
        return
    fi

    # Method 3: Check qmodem command
    if command -v qmodem >/dev/null 2>&1; then
        local info=$(timeout 3 qmodem status 2>/dev/null)
        if [ -n "$info" ] && ! echo "$info" | grep -qi "error"; then
            echo "true"
            return
        fi
    fi

    # Method 4: Check USB devices (FM170 etc.)
    if lsusb 2>/dev/null | grep -qi "19d2:0537\|2c7c:0900\|2c7c:030b"; then
        echo "true"
        return
    fi

    # Method 5: Check for usb0 RNDIS interface (H5000M specific)
    if [ -d "/sys/class/net/usb0" ]; then
        echo "true"
        return
    fi

    echo "false"
}

# Detect cake-autorate
detect_cake_autorate() {
    if command -v cake-autorate.sh >/dev/null 2>&1; then
        echo "true"
    elif [ -f "/etc/init.d/cake-autorate" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Detect CAKE qdisc support
detect_cake_qdisc() {
    if lsmod 2>/dev/null | grep -q "sch_cake"; then
        echo "true"
        return
    fi
    if tc qdisc add dev lo root cake 2>/dev/null; then
        tc qdisc del dev lo root cake 2>/dev/null
        echo "true"
    else
        echo "false"
    fi
}

# Detect eqos-mtk (MTK hardware QoS)
detect_eqos_mtk() {
    if [ -f "/etc/init.d/eqos" ] || [ -f "/usr/bin/eqos-mtk" ]; then
        echo "true"
    elif tc qdisc show dev wwan0 2>/dev/null | grep -q "hfsc\|mq\|hrtb"; then
        echo "true"
    else
        echo "false"
    fi
}

# Detect TriTon
detect_triton() {
    if [ -f "/etc/init.d/triton" ] || [ -f "/usr/bin/TriTon.sh" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Generate JSON output
generate_json() {
    local wifi=$(detect_wifi)
    local ebpf=$(detect_ebpf)
    local modem=$(detect_modem)
    local cake=$(detect_cake_autorate)
    local cake_qdisc=$(detect_cake_qdisc)
    local eqos_mtk=$(detect_eqos_mtk)
    local triton=$(detect_triton)
    local hnat_active="false"
    if hnat_ready; then
        hnat_active="true"
    fi

    cat > "$OUTPUT_FILE" << EOF
{
    "wifi_available": $wifi,
    "ebpf_available": $ebpf,
    "modem_available": $modem,
    "cake_autorate_available": $cake,
    "cake_qdisc_available": $cake_qdisc,
    "eqos_mtk_available": $eqos_mtk,
    "triton_available": $triton,
    "hnat_active": $hnat_active,
    "timestamp": $(date '+%s')
}
EOF
    echo "$OUTPUT_FILE generated"
}

# Main entry
if [ "$1" = "json" ]; then
    generate_json
    cat "$OUTPUT_FILE"
elif [ "$1" = "wifi" ]; then
    detect_wifi
elif [ "$1" = "ebpf" ]; then
    detect_ebpf
elif [ "$1" = "modem" ]; then
    detect_modem
elif [ "$1" = "cake" ]; then
    detect_cake_qdisc
elif [ "$1" = "hnat" ]; then
    if hnat_ready; then echo "true"; else echo "false"; fi
else
    generate_json
fi
