#!/bin/bash

set -euo pipefail

# Configuration
HOSTS_FILE="/share/sys_info/etc/hosts"
KEY="/share/sys_info/keys/key"
DEBUG=0
THRESHOLD=3

debug() {
    [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*" || true
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <hostname> [info] [service|docker] [name]"
    echo ""
    echo "Examples:"
    echo "  $0 server1"
    echo "  $0 server1 info service nginx"
    echo "  $0 server1 info docker mysql:latest"
    echo "  $0 server1 info docker my-container"
    exit 1
fi

input="$1"
shift
best_name=""
best_target=""
best_distance=999

debug "Input hostname: '$input'"

normalize() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]' | tr -d '[:space:]'
}

normalized=$(normalize "$input")
debug "Normalized input: '$normalized'"

# First try exact match
if grep -q "^$input " "$HOSTS_FILE"; then
    target=$(awk -v name="$input" '$1 == name {print $2}' "$HOSTS_FILE")
    echo "→ Connecting to $input (exact match)"
    
    # Build the command to send via stdin (for $(cat))
    if [ $# -ge 1 ] && [ "$1" = "info" ]; then
        
        if [ $# -lt 2 ]; then
            echo "Error: 'info' command requires type and name arguments"
            echo "Usage: $0 <hostname> info service|docker <name>"
            exit 1
        fi
        
        type="$2"
        name="$3"
        
        if [[ "$type" != "service" && "$type" != "docker" ]]; then
            echo "Error: Type must be 'service' or 'docker', got '$type'"
            exit 1
        fi
        
        echo "→ Running info command for $type: $name"
        
        # For $(cat), we need to send the command via stdin
        # The format should be exactly what sys_info.sh expects as arguments
        cmd="info $type $name"
        debug "Sending via stdin: '$cmd'"
        
        # Send command via stdin (for $(cat) to read)
        echo "$cmd" | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$target"
    else
        echo "run" | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$target"
    fi
   exit 0
fi

# Levenshtein distance function
levenshtein() {
    awk -v str1="$1" -v str2="$2" '
    BEGIN {
        len1 = length(str1)
        len2 = length(str2)
        
        for (i = 0; i <= len1; i++) d[i,0] = i
        for (j = 0; j <= len2; j++) d[0,j] = j
        
        for (i = 1; i <= len1; i++) {
            char1 = substr(str1, i, 1)
            for (j = 1; j <= len2; j++) {
                char2 = substr(str2, j, 1)
                cost = (char1 == char2) ? 0 : 1
                d[i,j] = min3(d[i-1,j] + 1,
                              d[i,j-1] + 1,
                              d[i-1,j-1] + cost)
            }
        }
        print d[len1,len2]
    }
    function min3(a, b, c) {
        return (a < b) ? (a < c ? a : c) : (b < c ? b : c)
    }'
}

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    name="${line%% *}"
    target="${line#* }"
    [[ "$name" == "$target" ]] && continue

    normalized_name=$(normalize "$name")
    dist=$(levenshtein "$normalized" "$normalized_name")
    debug "Comparing '$normalized' to '$normalized_name' → distance: $dist"

    if (( dist < best_distance )); then
        best_name="$name"
        best_target="$target"
        best_distance=$dist
        debug "→ New best match: $best_name (distance $best_distance)"
    fi
done < "$HOSTS_FILE"

if (( best_distance <= THRESHOLD )); then
    echo "→ Connecting to $best_name (fuzzy match, distance $best_distance)"
    
    if [ $# -ge 1 ] && [ "$1" = "info" ]; then
        
        if [ $# -lt 2 ]; then
            echo "Error: 'info' command requires type and name arguments"
            echo "Usage: $0 <hostname> info service|docker <name>"
            exit 1
        fi
        
        type="$2"
        name="$3"
        
        if [[ "$type" != "service" && "$type" != "docker" ]]; then
            echo "Error: Type must be 'service' or 'docker', got '$type'"
            exit 1
        fi
        
        echo "→ Running info command for $type: $name"
        
        cmd="info $type $name"
        debug "Sending via stdin: '$cmd'"
        
        exec echo "$cmd" | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$best_target"
    else
        exec echo "run" | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$best_target"
    fi
else
    debug "No fuzzy match under threshold. Best was '$best_name' at $best_distance"
    echo "[!] No matching host found for '$input'."
    
    echo ""
    echo "Available hosts:"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        name="${line%% *}"
        echo "  - $name"
    done < "$HOSTS_FILE"
    
    exit 1
fi

