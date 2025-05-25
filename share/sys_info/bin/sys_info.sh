#!/bin/bash
set -e

CONFIG_FILE="${HOME}/.config/sys_info.conf"
REQUIRED_TOOLS=("systemctl" "awk" "cut" "journalctl" "free" "df" "ps" "uptime" "hostname" "uname" "dialog")
AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"
KEY_IDENTIFIER="homeassistant_sys_info_key"

check_requirements() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    # Optional: sensors (lm-sensors)
    if ! command -v sensors &>/dev/null; then
        echo "Note: 'sensors' not found. It provides temperature info."
        read -rp "Shall I install 'lm-sensors' for you? [y/N]: " install_sensors
        if [[ "$install_sensors" =~ ^[Yy]$ ]]; then
            sudo apt install -y lm-sensors
        fi
    fi

    # Optional: battery info
    if ! [ -d /sys/class/power_supply ]; then
        echo "Note: No battery info detected."
    fi

    # Optional: systemd-journal group check
    if ! groups "$USER" | grep -qw "systemd-journal"; then
        echo "User '$USER' is not in the 'systemd-journal' group."
        read -rp "Add '$USER' to 'systemd-journal' group? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] && sudo adduser "$USER" systemd-journal
    fi

    # Handle required tools
    if (( ${#missing[@]} )); then
        echo "Missing tools: ${missing[*]}"
        read -rp "Shall I install the tools for you? [y/N]: " install
        if [[ "$install" =~ ^[Yy]$ ]]; then
            sudo apt install -y "${missing[@]}"
        else
            echo "Please install them manually: sudo apt install ${missing[*]}"
            exit 1
        fi
    fi
}


setup_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"

    use_dialog=false
    command -v dialog &>/dev/null && use_dialog=true

    ask_yes_no() {
        local prompt="$1"
        if $use_dialog; then
            dialog --yesno "$prompt" 7 50
        else
            read -rp "$prompt [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]]
        fi
    }

    ask_checklist() {
        local prompt="$1"
        shift
        local options=("$@")
        if $use_dialog; then
            dialog --separate-output --checklist "$prompt" 0 0 0 "${options[@]}" 3>&1 1>&2 2>&3
        else
            echo "$prompt"
            local selected=()
            for ((i=0; i<${#options[@]}; i+=3)); do
                local opt="${options[i]}"
                read -rp "Include $opt? [y/N]: " answer
                [[ "$answer" =~ ^[Yy]$ ]] && selected+=("$opt")
            done
            printf "%s\n" "${selected[@]}"
        fi
    }

    if [[ -f "$CONFIG_FILE" ]]; then
        if ! ask_yes_no "$CONFIG_FILE already exists. Update config?"; then
            echo "Keeping existing config."
            return
        fi
    fi

    include_battery="false"
    if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
        ask_yes_no "Battery detected. Include battery info in output?" && include_battery="true"
    fi

    mapfile -t all_services < <(systemctl list-unit-files --type=service | awk '{print $1}' | grep '\.service$' | sort)
    local dialog_options=()
    for service in "${all_services[@]}"; do
        dialog_options+=("$service" "" off)
    done

    local selected_services
    selected_services=$(ask_checklist "Select services to monitor:" "${dialog_options[@]}")

    if [ -z "$selected_services" ]; then
        echo "No services selected."
        exit 1
    fi

    {
        echo "#include_battery=${include_battery}"
        echo "$selected_services"
    } > "$CONFIG_FILE"
    echo "Saved selection to $CONFIG_FILE"
}

get_include_battery() {
    grep -q '^#include_battery=true' "$CONFIG_FILE" 2>/dev/null
}

run_status() {
    echo "============== SYSTEM INFORMATION =============="
    echo
    echo "Hostname:       $(hostname)"
    echo "Kernel:         $(uname -r)"
    echo "Uptime:         $(uptime -p)"
    echo "Load Avg:       $(cat /proc/loadavg)"
    echo "Memory:         $(free -m | awk 'NR==2 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    echo "Swap:           $(free -m | awk 'NR==3 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    echo "Disk usage:"
    df -h --output=target,used,size,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
        awk 'NR==1 || $1 !~ "^/(proc|sys|run|dev|snap)"' | column -t
    echo

    if command -v sensors &>/dev/null; then
        echo "Temperatures:"
        sensors | grep -E '°C|Adapter|temp[0-9]' | sed 's/^/  /'
        echo
    fi

    if get_include_battery; then
        battery_path="/sys/class/power_supply/BAT0"
        if [ -d "$battery_path" ]; then
            echo "Battery:"
            echo "  Status:     $(cat "$battery_path/status")"
            echo "  Capacity:   $(cat "$battery_path/capacity")%"
            echo
        fi
    fi
    echo "Top Processes:"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10
    echo

    echo "Recent Journal Errors (Level 3 - ERR):"
    journalctl -p 3 -xb --no-pager | tail -n 50 || true
    echo

    echo "Failed Services and Recent Logs:"
    mapfile -t failed_units < <(systemctl --failed --no-pager --plain | awk '/\.service/ {print $1}')

    if [ ${#failed_units[@]} -eq 0 ]; then
        echo "  None"
    else
        for service in "${failed_units[@]}"; do
            echo "--------------------------------------------------------------------------------"
            echo "Service:        $service"
            echo "Status:         $(systemctl is-active "$service" 2>/dev/null || echo unknown)"
            echo "Description:    $(systemctl show -p Description --value "$service" 2>/dev/null || echo unknown)"
            echo "Recent Logs:"
            journalctl -u "$service" -n 10 --no-pager 2>/dev/null || echo "  (No logs found)"
            echo
        done
    fi


    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No services selected. Run '$0 setup' first."
        return
    fi

    echo "MONITORED SERVICES:"
    grep -v '^#' "$CONFIG_FILE" | while IFS= read -r service; do
        [ -z "$service" ] && continue
        echo "--------------------------------------------------------------------------------"
        echo "Service:        $service"
        echo "Status:         $(systemctl is-active "$service" 2>/dev/null || echo unknown)"
        echo "Description:    $(systemctl show -p Description --value "$service" 2>/dev/null || echo unknown)"
        echo "Recent Logs:"
        journalctl -u "$service" -n 10 --no-pager 2>/dev/null || echo "(No logs found)"
        echo
    done
}

remove_key() {
    if [ ! -f "$AUTHORIZED_KEYS" ]; then
        echo "No authorized_keys file found."
        exit 1
    fi

    match_count=$(grep -c "$KEY_IDENTIFIER" "$AUTHORIZED_KEYS")

    if (( match_count == 0 )); then
        echo "No key with identifier '$KEY_IDENTIFIER' found."
        return
    elif (( match_count > 1 )); then
        echo "Multiple keys with identifier '$KEY_IDENTIFIER' found. Aborting to avoid unintended deletion."
        return
    fi

    cp "$AUTHORIZED_KEYS" "${AUTHORIZED_KEYS}.bak"
    grep -v "$KEY_IDENTIFIER" "$AUTHORIZED_KEYS" > "${AUTHORIZED_KEYS}.tmp" &&
    mv "${AUTHORIZED_KEYS}.tmp" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    echo "Removed SSH key with identifier: $KEY_IDENTIFIER"
}

update_key() {
    if [ ! -f "$AUTHORIZED_KEYS" ]; then
        echo "No authorized_keys file found."
        exit 1
    fi

    match_count=$(grep -c "$KEY_IDENTIFIER" "$AUTHORIZED_KEYS")

    if (( match_count == 0 )); then
        echo "No key with identifier '$KEY_IDENTIFIER' found."
        return
    elif (( match_count > 1 )); then
        echo "Multiple keys with identifier '$KEY_IDENTIFIER' found. Aborting to avoid unintended modification."
        return
    fi

    cp "$AUTHORIZED_KEYS" "${AUTHORIZED_KEYS}.bak"

    while IFS= read -r line; do
        if [[ "$line" == *"$KEY_IDENTIFIER" ]]; then
            cleaned=$(echo "$line" | sed -E 's/^.*ssh-ed25519/ssh-ed25519/')
            echo "$cleaned" >> "${AUTHORIZED_KEYS}.tmp"
        else
            echo "$line" >> "${AUTHORIZED_KEYS}.tmp"
        fi
    done < "$AUTHORIZED_KEYS"

    mv "${AUTHORIZED_KEYS}.tmp" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    echo "Updated SSH key to remove restrictions for: $KEY_IDENTIFIER"
}


# Entry point
check_requirements

case "$1" in
    setup)
        setup_config
        ;;
    run)
        run_status
        ;;
    remove)
        remove_key
        ;;
    update)
        update_key
        ;;
    *)
        echo "Usage: $0 [setup|run|remove|update]"
        exit 1
        ;;
esac

