#!/bin/bash
set -e

CONFIG_FILE="${HOME}/.config/sys_info.conf"
REQUIRED_TOOLS=("systemctl" "awk" "cut" "journalctl" "free" "df" "ps" "uptime" "hostname" "uname" "dialog")
AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"
KEY_IDENTIFIER="homeassistant_sys_info_key"
SCRIPT_URL="https://raw.githubusercontent.com/Bram-diederik/ai-linux-system-info/refs/heads/main/share/sys_info/bin/sys_info.sh"
USE_SUDO_DOCKER=true
SCRIPT_VERSION="2.0-secure"
GITHUB_REPO="Bram-diederik/ai-linux-system-info"
GITHUB_BRANCH="main"

# Security flag - prevents restriction removal
RESTRICTIONS_LOCKED=true

check_requirements() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if ! command -v sensors &>/dev/null; then
        echo "Note: 'sensors' not found. It provides temperature info."
        read -rp "Shall I install 'lm-sensors' for you? [y/N]: " install_sensors
        if [[ "$install_sensors" =~ ^[Yy]$ ]]; then
            sudo apt install -y lm-sensors
        fi
    fi

    if ! [ -d /sys/class/power_supply ]; then
        echo "Note: No battery info detected."
    fi

    if ! groups "$USER" | grep -qw "systemd-journal"; then
        echo "User '$USER' is not in the 'systemd-journal' group."
        read -rp "Add '$USER' to 'systemd-journal' group? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] && sudo adduser "$USER" systemd-journal
    fi

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

load_docker_preference() {
    if [[ -f "$CONFIG_FILE" ]] && grep -q "^#use_sudo_docker=" "$CONFIG_FILE"; then
        if grep -q "^#use_sudo_docker=true" "$CONFIG_FILE"; then
            USE_SUDO_DOCKER=true
        else
            USE_SUDO_DOCKER=false
        fi
    fi
}

docker_cmd() {
    if [[ "$USE_SUDO_DOCKER" == "true" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

# SECURE: Verify SSH restrictions are present
verify_ssh_restrictions() {
    if [[ -f "$AUTHORIZED_KEYS" ]] && grep -q "$KEY_IDENTIFIER" "$AUTHORIZED_KEYS"; then
        local key_line=$(grep "$KEY_IDENTIFIER" "$AUTHORIZED_KEYS")
        
        # Check if restrictions are present
        if ! echo "$key_line" | grep -q 'command=\|no-port-forwarding\|no-X11-forwarding\|restrict'; then
            echo "⚠️  WARNING: SSH key restrictions missing for $KEY_IDENTIFIER!"
            echo "This could be a security risk."
            echo "Remove the key and install again"
        fi
    fi
    return 0
}

setup_config() {
    # SECURE: Always verify restrictions first
    verify_ssh_restrictions || echo "Continuing setup despite restriction warnings..."
    
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

    echo "Docker access configuration:"
    if ask_yes_no "Do you need to use 'sudo' for docker commands?"; then
        USE_SUDO_DOCKER=true
        echo "Will use 'sudo docker' for Docker commands."
    else
        USE_SUDO_DOCKER=false
        echo "Will use 'docker' without sudo (requires user in docker group)."
    fi
    echo

    include_battery="false"
    if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
        ask_yes_no "Battery detected. Include battery info in output?" && include_battery="true"
    fi

    mapfile -t all_services < <(systemctl list-unit-files --type=service | awk '{print $1}' | grep '\.service$' | sort)
    
    local docker_images=()
    if command -v docker &>/dev/null || command -v sudo &>/dev/null; then
        echo "Checking for Docker images..."
        if docker_cmd images &>/dev/null; then
            mapfile -t docker_images < <(docker_cmd images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v "<none>" | sort -u)
            echo "Found ${#docker_images[@]} Docker images."
        else
            echo "Cannot access Docker. Make sure Docker is running and you have proper permissions."
        fi
    fi

    local dialog_options=()
    
    for service in "${all_services[@]}"; do
        dialog_options+=("service:$service" "Systemd Service" off)
    done
    
    for image in "${docker_images[@]}"; do
        dialog_options+=("docker:$image" "Docker Image" off)
    done

    local selected_items
    selected_items=$(ask_checklist "Select services and/or Docker images to monitor:" "${dialog_options[@]}")

    if [ -z "$selected_items" ]; then
        echo "No items selected."
        exit 1
    fi

    {
        echo "#include_battery=${include_battery}"
        echo "#use_sudo_docker=${USE_SUDO_DOCKER}"
        echo "#version=${SCRIPT_VERSION}"
        echo "#last_updated=$(date -Iseconds)"
        echo "$selected_items"
    } > "$CONFIG_FILE"
    echo "Saved selection to $CONFIG_FILE"
}

get_include_battery() {
    grep -q '^#include_battery=true' "$CONFIG_FILE" 2>/dev/null
}

show_vital_info() {
    echo "============== VITAL SYSTEM INFORMATION =============="
    echo
    echo "Hostname:       $(hostname)"
    echo "Kernel:         $(uname -r)"
    echo "Uptime:         $(uptime -p)"
    echo "Load Avg:       $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    echo "Memory:         $(free -m | awk 'NR==2 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    echo "Swap:           $(free -m | awk 'NR==3 {printf "%s/%s MB (%.2f%%)", $3,$2,$3*100/$2 }')"
    
    echo "Disk usage:"
    df -h --output=target,used,size,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR==1 || $1 !~ "^/(proc|sys|run|dev|snap)"' | column -t
}

show_service_info() {
    local service_name="$1"
    
    echo "=== Service Information: $service_name ==="
    echo
    echo "Status:         $(systemctl is-active "$service_name" 2>/dev/null || echo unknown)"
    echo "Description:    $(systemctl show -p Description --value "$service_name" 2>/dev/null || echo unknown)"
    echo "Loaded:         $(systemctl is-enabled "$service_name" 2>/dev/null || echo unknown)"
    echo "Main PID:       $(systemctl show -p MainPID --value "$service_name" 2>/dev/null || echo unknown)"
    
    echo
    echo "Recent Logs (last 20 lines):"
    echo "------------------------------"
    journalctl -u "$service_name" -n 20 --no-pager 2>/dev/null || echo "(No logs found)"
    echo
}

show_docker_info() {
    local docker_name="$1"
    
    echo "=== Docker Information: $docker_name ==="
    echo
    
    local is_container=$(docker_cmd ps -a --filter "name=$docker_name" --format "{{.Names}}" 2>/dev/null | head -1)
    local is_image=$(docker_cmd images --filter "reference=$docker_name" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    
    if [[ -n "$is_container" ]]; then
        echo "Type:           Container"
        echo "Name:           $is_container"
        echo "Status:         $(docker_cmd inspect -f '{{.State.Status}}' "$is_container" 2>/dev/null || echo unknown)"
        echo "Image:          $(docker_cmd inspect -f '{{.Config.Image}}' "$is_container" 2>/dev/null || echo unknown)"
        echo "Created:        $(docker_cmd inspect -f '{{.Created}}' "$is_container" 2>/dev/null | cut -d. -f1 | sed 's/T/ /' || echo unknown)"
        echo "IP Address:     $(docker_cmd inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$is_container" 2>/dev/null || echo unknown)"
        
        echo
        echo "Recent Logs (last 20 lines):"
        echo "------------------------------"
        docker_cmd logs --tail 20 "$is_container" 2>/dev/null || echo "No logs available"
        
    elif [[ -n "$is_image" ]]; then
        echo "Type:           Image"
        echo "Name:           $is_image"
        echo "ID:             $(docker_cmd images --filter "reference=$is_image" --format "{{.ID}}" 2>/dev/null | head -1 || echo unknown)"
        echo "Size:           $(docker_cmd images --filter "reference=$is_image" --format "{{.Size}}" 2>/dev/null | head -1 || echo unknown)"
        echo "Created:        $(docker_cmd images --filter "reference=$is_image" --format "{{.CreatedSince}}" 2>/dev/null | head -1 || echo unknown)"
        
        echo
        echo "Containers using this image:"
        local containers=()
        mapfile -t containers < <(docker_cmd ps -a --filter "ancestor=$is_image" --format "{{.Names}}" 2>/dev/null)
        
        if [ ${#containers[@]} -eq 0 ]; then
            echo "  No containers found using this image"
        else
            for container in "${containers[@]}"; do
                if [[ -n "$container" ]]; then
                    echo "  - $container ($(docker_cmd inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo unknown))"
                fi
            done
        fi
        
    else
        echo "No Docker container or image found with name: $docker_name"
        echo
        echo "Available containers:"
        docker_cmd ps --format "{{.Names}}" 2>/dev/null | sed 's/^/  - /' || true
        echo
        echo "Available images:"
        docker_cmd images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v "<none>" | sed 's/^/  - /' || true
    fi
    echo
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
    
    if command -v docker_cmd &>/dev/null && docker_cmd --version &>/dev/null; then
        echo "Docker Status:"
        echo "  Version:    $(docker_cmd --version | cut -d' ' -f3- | tr -d ',')"
        echo "  Containers: $(docker_cmd ps -q 2>/dev/null | wc -l) running, $(docker_cmd ps -aq 2>/dev/null | wc -l) total"
        echo "  Images:     $(docker_cmd images -q 2>/dev/null | wc -l) total"
        echo
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

    echo "MONITORED ITEMS:"
    grep -v '^#' "$CONFIG_FILE" | while IFS= read -r item; do
        [ -z "$item" ] && continue
        echo "--------------------------------------------------------------------------------"
        
        if [[ "$item" == service:* ]]; then
            local service_name="${item#service:}"
            echo "Service:        $service_name"
            echo "Status:         $(systemctl is-active "$service_name" 2>/dev/null || echo unknown)"
            echo "Description:    $(systemctl show -p Description --value "$service_name" 2>/dev/null || echo unknown)"
            echo "Recent Logs:"
            journalctl -u "$service_name" -n 10 --no-pager 2>/dev/null || echo "(No logs found)"
            echo
        elif [[ "$item" == docker:* ]]; then
            local image_name="${item#docker:}"
            echo "=== Docker Image: $image_name ==="
            
            echo "Image Information:"
            docker_cmd images --filter "reference=$image_name" --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}\t{{.Digest}}" 2>/dev/null || echo "  Image not found"
            echo
            
            echo "Containers using this image:"
            local containers=()
            mapfile -t containers < <(docker_cmd ps -a --filter "ancestor=$image_name" --format "{{.Names}}" 2>/dev/null)
            
            if [ ${#containers[@]} -eq 0 ]; then
                echo "  No containers found using this image"
                echo
                continue
            fi
            
            docker_cmd ps -a --filter "ancestor=$image_name" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.CreatedAt}}" 2>/dev/null
            echo
            
            for container in "${containers[@]}"; do
                if [[ -n "$container" ]]; then
                    echo "--- Container: $container ---"
                    echo "Recent logs (last 20 lines):"
                    docker_cmd logs --tail 20 "$container" 2>/dev/null || echo "  No logs available or container not running"
                    echo
                fi
            done
        else
            echo "Service:        $item"
            echo "Status:         $(systemctl is-active "$item" 2>/dev/null || echo unknown)"
            echo "Description:    $(systemctl show -p Description --value "$item" 2>/dev/null || echo unknown)"
            echo "Recent Logs:"
            journalctl -u "$item" -n 10 --no-pager 2>/dev/null || echo "(No logs found)"
            echo
        fi
    done
}

info() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 info service|docker <name>"
        echo ""
        echo "Examples:"
        echo "  $0 info service nginx"
        echo "  $0 info docker mysql:latest"
        echo "  $0 info docker my-container-name"
        exit 1
    fi
    
    local type="$1"
    local name="$2"
    
    load_docker_preference
    
    show_vital_info
    
    case "$type" in
        service)
            show_service_info "$name"
            ;;
        docker)
            show_docker_info "$name"
            ;;
        *)
            echo "Unknown type: $type. Use 'service' or 'docker'."
            exit 1
            ;;
    esac
}


# SECURE: Safe update script with restriction verification
update_script() {
    echo "🔒 Secure update from GitHub..."
    echo "Verifying current SSH restrictions..."
    
    if ! verify_ssh_restrictions; then
        echo "⚠️  Cannot proceed with update - SSH restrictions are compromised!"
        echo "Please fix SSH restrictions first or run '$0 reapply-restrictions'"
        exit 1
    fi
    
    echo "✅ SSH restrictions verified"
    
    local update_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/share/sys_info/bin/sys_info.sh"
    local temp_script="/tmp/sys_info_new.sh"
    local backup_script="${0}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Download new script
    if command -v curl &>/dev/null; then
        if ! curl -s -f -o "$temp_script" "$update_url"; then
            echo "❌ Failed to download from GitHub"
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q -O "$temp_script" "$update_url"; then
            echo "❌ Failed to download from GitHub"
            exit 1
        fi
    else
        echo "❌ Need curl or wget to update"
        exit 1
    fi
    
    # Make backup
    cp "$0" "$backup_script"
    
    # Replace script
    if cp "$temp_script" "$0"; then
        chmod +x "$0"
        echo "✅ Script updated successfully"
        echo "📋 Backup saved as: $backup_script"
        
        # Verify new script works
        echo "Testing new script..."
        if "$0" --version &>/dev/null || "$0" --help &>/dev/null; then
            echo "✅ New script verified"
        else
            echo "⚠️  New script may have issues, restoring backup..."
            cp "$backup_script" "$0"
            exit 1
        fi
        
        # Final verification of restrictions
        echo "Final security check..."
        if verify_ssh_restrictions; then
            echo "✅ All security checks passed"
        else
            echo "⚠️  Security check failed after update!"
            echo "Run '$0 verify-restrictions' to check"
        fi
    else
        echo "❌ Failed to update script"
        cp "$backup_script" "$0"
        exit 1
    fi
    
    rm -f "$temp_script"
}


# Load docker preference at startup
load_docker_preference

case "$1" in
    setup)
        setup_config
        ;;
    run)
        run_status
        ;;
    info)
        shift
        info "$@"
        ;;
    update-script)
        update_script
        setup_config
        ;;
    --version|-v)
        echo "sys_info.sh version: ${SCRIPT_VERSION}"
        echo "Security: RESTRICTIONS_LOCKED=${RESTRICTIONS_LOCKED}"
        ;;
    *)
        echo "Usage: $0 [COMMAND]"
        echo ""
        echo "🔒 SECURE COMMANDS:"
        echo "  setup              - Configure services and Docker images to monitor"
        echo "  run                - Display full system information and logs"
        echo "  info <type> <name> - Show specific service/docker logs"
        echo "  update-script      - Securely update from GitHub (verifies restrictions)"
        echo "Examples:"
        echo "  $0 info service nginx"
        echo "  $0 info docker mysql:latest"
        exit 1
        ;;
esac
