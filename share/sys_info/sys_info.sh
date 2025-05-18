#!/bin/bash

set -e

CONFIG_FILE="${HOME}/.config/sys_info.conf"
REQUIRED_TOOLS=("jq" "systemctl" "awk" "cut" "journalctl" "free" "df" "ps" "uptime" "hostname" "uname" "dialog")

check_requirements() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if ! command -v sensors &>/dev/null; then
        echo "Note: 'sensors' not found. Run 'sudo apt install lm-sensors' to include temperature info."
    fi

    if ! [ -d /sys/class/power_supply ]; then
        echo "Note: No battery info detected."
    fi

    if ! groups "$USER" | grep -qw "systemd-journal"; then
        echo "User '$USER' is not in the 'systemd-journal' group."
        read -rp "Add '$USER' to 'systemd-journal' group? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            sudo adduser $USER systemd-journal
        fi
    fi

    if (( ${#missing[@]} )); then
        echo "Missing tools: ${missing[*]}"
        echo "Install them with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

setup_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"

    use_dialog=false
    if command -v dialog &>/dev/null; then
        use_dialog=true
    fi

    ask_yes_no() {
        local prompt="$1"
        if $use_dialog; then
            dialog --yesno "$prompt" 7 50
            return $?
        else
            read -rp "$prompt [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]]
            return $?
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
            selected=()
            for ((i=0; i<${#options[@]}; i+=3)); do
                opt="${options[i]}"
                echo "- $opt"
                read -rp "Include $opt? [y/N]: " answer
                [[ "$answer" =~ ^[Yy]$ ]] && selected+=("$opt")
            done
            printf "%s\n" "${selected[@]}"
        fi
    }

    # Battery presence check
    include_battery="false"
    if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
        if ask_yes_no "Battery detected. Include battery info in output?"; then
            include_battery="true"
        fi
    fi

    # Service selection
    mapfile -t all_services < <(systemctl list-unit-files --type=service | awk '{print $1}' | grep '\.service$' | sort)

    dialog_options=()
    for service in "${all_services[@]}"; do
        dialog_options+=("$service" "" off)
    done

    selected_services=$(ask_checklist "Select services to monitor:" "${dialog_options[@]}")

    if [ -z "$selected_services" ]; then
        echo "No services selected."
        exit 1
    fi

    echo "#include_battery=${include_battery}" > "$CONFIG_FILE"
    echo "$selected_services" | tr ' ' '\n' >> "$CONFIG_FILE"
    echo "Saved selection to $CONFIG_FILE"
}

get_include_battery() {
    grep -q '^#include_battery=true' "$CONFIG_FILE" 2>/dev/null && return 0 || return 1
}

collect_system_info_json() {
    local disk_json
    disk_json=$(df -h --output=source,target,used,size,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
        awk 'NR>1 && $2 !~ "^/(proc|sys|run|dev|snap)" {printf "{\"source\":\"%s\",\"mount\":\"%s\",\"used\":\"%s\",\"size\":\"%s\",\"percent\":\"%s\"},", $1,$2,$3,$4,$5}' |
        sed 's/,$//')

    local top_processes_json
    top_processes_json=$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10 |
        awk 'NR>1 {
            printf "{\"pid\":%s,\"ppid\":%s,\"cmd\":\"", $1, $2;
            for (i=3; i<=NF-2; i++) printf "%s ", $i;
            printf "\",\"mem\":%s,\"cpu\":%s},", $(NF-1), $NF
        }' | sed 's/,$//')

    local temperatures_json="[]"
    if command -v sensors &>/dev/null; then
        local temps_raw
        temps_raw=$(sensors 2>/dev/null)
        temperatures_json=$(echo "$temps_raw" | awk -F ':' '/°C/ {gsub(/[[:space:]]+/,"",$1); gsub(/[[:space:]]+/,"",$2); printf "{\"label\":\"%s\",\"temp\":\"%s\"},", $1, $2}' | sed 's/,$//')
    fi

    local battery_json="{}"
    local battery_path
    battery_path=$(find /sys/class/power_supply -name 'BAT*' -print -quit 2>/dev/null)
    if [ -n "$battery_path" ]; then
        battery_json=$(jq -n \
            --arg status "$(cat "$battery_path/status" 2>/dev/null)" \
            --arg capacity "$(cat "$battery_path/capacity" 2>/dev/null)" \
            '{status: $status, capacity_percentage: ($capacity | tonumber)}')
    fi

    jq -n \
        --arg hostname "$(hostname)" \
        --arg kernel "$(uname -r)" \
        --arg uptime "$(uptime -p)" \
        --arg loadavg "$(cat /proc/loadavg)" \
        --arg memory "$(free -m | awk 'NR==2 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')" \
        --arg swap "$(free -m | awk 'NR==3 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')" \
        --arg failed_services "$(systemctl --failed --no-pager --plain || true)" \
        --arg journal_errors "$(journalctl -p 3 -xb --no-pager | tail -n 50 || true)" \
        --argjson disk "[$disk_json]" \
        --argjson top_processes "[$top_processes_json]" \
        --argjson temperatures "[$temperatures_json]" \
        --argjson battery "$battery_json" \
        '{
            hostname: $hostname,
            kernel: $kernel,
            uptime: $uptime,
            load_average: $loadavg,
            memory: $memory,
            swap: $swap,
            disk: $disk,
            battery: $battery,
            temperatures: $temperatures,
            top_processes: $top_processes,
            failed_services: $failed_services,
            journalctl_errors: $journal_errors
        }'
}

run_status() {
    echo "============== SYSTEM INFORMATION =============="
    echo

    uptime="$(uptime -p)"
    hostname="$(hostname)"
    kernel="$(uname -r)"
    loadavg="$(cat /proc/loadavg)"
    meminfo="$(free -m | awk 'NR==2 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    swapinfo="$(free -m | awk 'NR==3 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    diskinfo="$(df -h --output=target,used,size,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
        awk 'NR==1 || $1 !~ "^/(proc|sys|run|dev|snap)"' | column -t)"
    top_procs="$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)"
    failed_services="$(systemctl --failed --no-pager --plain || true)"
    journal_errors="$(journalctl -p 3 -xb --no-pager | tail -n 50 || true)"

    echo "Hostname:       $hostname"
    echo "Kernel:         $kernel"
    echo "Uptime:         $uptime"
    echo "Load Avg:       $loadavg"
    echo "Memory:         $meminfo"
    echo "Swap:           $swapinfo"
    echo "Disk usage:"
    echo "$diskinfo"
    echo

    if command -v sensors &>/dev/null; then
        echo "Temperatures:"
        echo "--------------------------------------------------------------------------------"
        sensors | grep -E '°C|Adapter|temp[0-9]' | sed 's/^/  /'
        echo
    fi

    if get_include_battery; then
        battery_path="/sys/class/power_supply/BAT0"
        if [ -d "$battery_path" ]; then
            battery_status=$(cat "$battery_path/status")
            battery_capacity=$(cat "$battery_path/capacity")
            echo "Battery:"
            echo "--------------------------------------------------------------------------------"
            echo "  Status:     $battery_status"
            echo "  Capacity:   $battery_capacity%"
            echo
        fi
    fi

    echo "Failed Services:"
    echo "--------------------------------------------------------------------------------"
    echo "$failed_services"
    echo
    echo "Top Processes:"
    echo "--------------------------------------------------------------------------------"
    echo "$top_procs"
    echo
    echo "Recent Journal Errors (Level 3 - ERR):"
    echo "--------------------------------------------------------------------------------"
    echo "$journal_errors"
    echo

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No services selected. Run '$0 setup' first."
        return
    fi

    echo "============== MONITORED SERVICES =============="
    echo
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

run_json() {
    echo "{"
    echo '"system":'
    collect_system_info_json
    echo ','
    echo '"services":'
    collect_services_json
    echo "}"
}

collect_services_json() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[]"
        return
    fi

    echo "["
    local first=true
    grep -v '^#' "$CONFIG_FILE" | while IFS= read -r service; do
        [ -z "$service" ] && continue
        if ! systemctl status "$service" &>/dev/null; then
            continue
        fi

        local description=$(systemctl show -p Description --value "$service")
        local status=$(systemctl is-active "$service")
        local logs=$(journalctl -u "$service" -n 10 --no-pager 2>/dev/null | sed 's/"/\\"/g' | jq -R -s '.')

        $first || echo ","
        first=false

        jq -n \
            --arg name "$service" \
            --arg description "$description" \
            --arg status "$status" \
            --arg logs "$logs" \
            '{
                service: $name,
                description: $description,
                status: $status,
                logs: ($logs | fromjson)
            }'
    done
    echo "]"
}

# Main entrypoint
check_requirements

case "$1" in
    setup)
        check_requirements
        setup_config
        ;;
    json)
        run_json
        ;;
    run|"")
        run_status
        ;;
    *)
        echo "Usage: $0 [setup|run|json]"
        exit 1
        ;;
esac
