#!/bin/bash

HOSTS_FILE="/share/sys_info/etc/hosts"
NAME="$1"
KEY="/share/sys_info/keys/key"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <name>"
    exit 1
fi

# Try exact match
EXACT_LINE=$(awk -v name="$NAME" '$1 == name { print }' "$HOSTS_FILE")

if [ -n "$EXACT_LINE" ]; then
    HOST=$(echo "$EXACT_LINE" | awk '{print $2}')
    exec echo run | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST"
fi

# Try fuzzy match
FUZZY_MATCHES=($(awk -v name="$NAME" '
    BEGIN { IGNORECASE = 1 }
    $1 ~ name || name ~ $1 { print $1 }
' "$HOSTS_FILE"))

if [ ${#FUZZY_MATCHES[@]} -eq 1 ]; then
    NAME_MATCH=$(echo "${FUZZY_MATCHES[0]}" | awk '{print $1}')
    HOST=$(grep "^$NAME_MATCH " "$HOSTS_FILE" | awk '{print $2}')
    exec echo run | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST"
elif [ ${#FUZZY_MATCHES[@]} -gt 1 ]; then
    echo "[!] Multiple fuzzy matches found:"
    for match in "${FUZZY_MATCHES[@]}"; do
        echo "  - $match"
    done
    exit 1
else
    echo "[!] No matching host found."
    exit 1
fi
