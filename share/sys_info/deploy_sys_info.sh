#!/bin/bash

set -e

KEY_DIR="/share/sys_info"
KEY_PATH="$KEY_DIR/key"
HOSTS_FILE="$KEY_DIR/hosts"
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
else
    echo "[+] SSH key already exists at $KEY_PATH"
fi

# Step 2: Copy public key to remote
echo "[+] Installing SSH key on remote: $REMOTE"
ssh-copy-id -i "$KEY_PATH.pub" "$REMOTE"

# Step 3: Ensure /home/$USER/bin exists on remote
echo "[+] Ensuring ~/bin exists on remote"
ssh -i "$KEY_PATH" "$REMOTE" 'mkdir -p ~/bin'

# Step 4: Copy the sys_info.sh script to remote
echo "[+] Copying sys_info.sh to /home/$USER/bin"
scp -i "$KEY_PATH" sys_info.sh "$REMOTE:/home/$USER/bin/sys_info.sh"
ssh -i "$KEY_PATH" "$REMOTE" 'chmod +x /home/$USER/bin/sys_info.sh'

# Step 5: Run setup
echo "[+] Running sys_info setup on remote"
ssh -t -i "$KEY_PATH" "$REMOTE" "/home/$USER/bin/sys_info.sh setup"

# Step 6: Restrict key
echo "[+] Restricting SSH key in authorized_keys..."
REMOTE_KEY=$(< "$KEY_PATH.pub")
FORCE_CMD="command=\"/home/$USER/bin/sys_info.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,restrict"

ssh -i "$KEY_PATH" "$REMOTE" "
    mkdir -p /home/$USER/.ssh &&
    grep -v 'homeassistant_sys_info_key' /home/$USER/.ssh/authorized_keys > /home/$USER/.ssh/authorized_keys.tmp &&
    echo '$FORCE_CMD $REMOTE_KEY' >> /home/$USER/.ssh/authorized_keys.tmp &&
    mv /home/$USER/.ssh/authorized_keys.tmp /home/$USER/.ssh/authorized_keys &&
    chmod 600 /home/$USER/.ssh/authorized_keys
"

# Step 7: Save host alias
echo "[+] Saving connection under name: $NAME"
# Remove any previous entries matching the same NAME or HOST
sed -i "/^$NAME\s/d" "$HOSTS_FILE"
sed -i "/\s$USER@$HOST$/d" "$HOSTS_FILE"

# Add the new entry
echo "$NAME $USER@$HOST" >> "$HOSTS_FILE"

echo "[✓] Setup complete. You can now use ./get_sys_info.sh $NAME"
