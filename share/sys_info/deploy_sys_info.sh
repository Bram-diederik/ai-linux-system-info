#!/bin/bash

set -e
KEY_DIR="$(pwd)/keys"
KEY_PATH="$KEY_DIR/key"
HOSTS_FILE="$(pwd)/etc/hosts"

NAME="$1"
REMOTE="$2"

if [ -z "$NAME" ] || [ -z "$REMOTE" ]; then
    echo "Usage: $0 <name> <user@host>"
    exit 1
fi

if [[ "$REMOTE" == *@* ]]; then
    USER="${REMOTE%@*}"
    HOST="${REMOTE#*@}"
else
    echo "[!] REMOTE must be in user@host format"
    exit 1
fi

mkdir -p "$KEY_DIR"

# Step 1: Ensure key exists
if [ ! -f "$KEY_PATH" ]; then
    echo "[+] Generating SSH key..."
    ssh-keygen -C "homeassistant_sys_info_key" -t ed25519 -N "" -f "$KEY_PATH"
fi

echo "[+] Connecting to exising system"
if echo 'update-script' | ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH"  "$REMOTE"; then
    # Success path: The SSH command and the remote script succeeded.
    exit 
else
   echo "[+] Installing SSH key on remote: $REMOTE"
   echo "[#] ssh-copy-id -i \"$KEY_PATH\" \"$REMOTE\""
   ssh-copy-id -o PubkeyAuthentication=no -i "$KEY_PATH.pub" "$REMOTE"
   sleep 1
   echo "[+] Ensuring ~/bin exists on remote"
   ssh -i "$KEY_PATH" "$REMOTE" 'mkdir -p ~/bin'
   sleep 1

   # Step 4: Copy the secure sys_info.sh script
   echo "[+] Coping secure sys_info.sh to remote"
   scp -i "$KEY_PATH" ./bin/sys_info.sh "$REMOTE:/home/$USER/bin/sys_info.sh"
   sleep 1
   ssh -i "$KEY_PATH" "$REMOTE" 'chmod +x /home/$USER/bin/sys_info.sh'

   sleep 1
   # Step 5: Run setup
   echo "[+] Running sys_info setup on remote"
   ssh -t -i "$KEY_PATH" "$REMOTE" "/home/$USER/bin/sys_info.sh setup"

fi
   # Step 6: Restrict key
   echo "[+] Restricting SSH key in authorized_keys..."
   REMOTE_KEY=$(< "$KEY_PATH.pub")
   FORCE_LINE='command="/home/'"$USER"'/bin/sys_info.sh $(cat)",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,restrict '"$REMOTE_KEY"''
   ssh -i "$KEY_PATH" "$REMOTE" bash <<EOF
mkdir -p /home/$USER/.ssh
grep -v 'homeassistant_sys_info_key' /home/$USER/.ssh/authorized_keys > /home/$USER/.ssh/authorized_keys.tmp
echo '$FORCE_LINE' >> /home/$USER/.ssh/authorized_keys.tmp
mv /home/$USER/.ssh/authorized_keys.tmp /home/$USER/.ssh/authorized_keys
chmod 600 /home/$USER/.ssh/authorized_keys
EOF

# Step 8: Save host alias
echo "[+] Saving connection under name: $NAME"
mkdir -p "$(dirname "$HOSTS_FILE")"
sed -i "/^$NAME\s/d" "$HOSTS_FILE" 2>/dev/null || true
sed -i "/\s$USER@$HOST$/d" "$HOSTS_FILE" 2>/dev/null || true
echo "$NAME $USER@$HOST" >> "$HOSTS_FILE"

echo ""
echo "[✓] DEPLOYMENT COMPLETE"
echo "To get system info: ./get_sys_info.sh $NAME"
