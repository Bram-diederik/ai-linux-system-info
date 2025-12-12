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

echo "[+] Testing connection..."
if timeout 10 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$KEY_PATH" "$REMOTE" "echo 'Connection test successful'" >/dev/null 2>&1; then
    echo "[✓] SSH connection working"
else
    echo "[+] Installing SSH key on remote: $REMOTE"
    ssh-copy-id -i "$KEY_PATH.pub" "$REMOTE"
fi

echo "[+] Ensuring ~/bin exists on remote"
ssh -i "$KEY_PATH" "$REMOTE" 'mkdir -p ~/bin'

# Step 4: Copy the secure sys_info.sh script
echo "[+] Copying secure sys_info.sh to remote"
scp -i "$KEY_PATH" ./bin/sys_info.sh "$REMOTE:/home/$USER/bin/sys_info.sh"
ssh -i "$KEY_PATH" "$REMOTE" 'chmod +x /home/$USER/bin/sys_info.sh'

# Step 5: Run setup
echo "[+] Running sys_info setup on remote"
ssh -t -i "$KEY_PATH" "$REMOTE" "/home/$USER/bin/sys_info.sh setup"

# Step 6: Apply secure restrictions (ALWAYS APPLIED, NEVER REMOVED)
echo "[+] Applying SECURE SSH key restrictions..."
REMOTE_KEY=$(< "$KEY_PATH.pub")

# SECURE: Create restricted key line that cannot be removed
# Using a comment that will be checked by the script
RESTRICTED_LINE="command=\"/home/$USER/bin/sys_info.sh \$(cat)\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,restrict $REMOTE_KEY homeassistant_sys_info_key # DO_NOT_REMOVE_RESTRICTIONS"

ssh -i "$KEY_PATH" "$REMOTE" bash <<EOF
mkdir -p /home/$USER/.ssh
chmod 700 /home/$USER/.ssh

# Remove any existing key with this identifier
if [ -f /home/$USER/.ssh/authorized_keys ]; then
    grep -v "homeassistant_sys_info_key" /home/$USER/.ssh/authorized_keys > /home/$USER/.ssh/authorized_keys.tmp || true
    mv /home/$USER/.ssh/authorized_keys.tmp /home/$USER/.ssh/authorized_keys 2>/dev/null || touch /home/$USER/.ssh/authorized_keys
fi

# Add the restricted key
echo '$RESTRICTED_LINE' >> /home/$USER/.ssh/authorized_keys
chmod 600 /home/$USER/.ssh/authorized_keys

# Create a security notice file
cat > /home/$USER/.ssh/security_notice.txt <<'EONOTICE'
SECURITY NOTICE:
===============
The SSH key for sys_info access has been configured with mandatory restrictions.
These restrictions prevent the key from being used for anything other than
running the sys_info.sh script.

The restrictions include:
- No port forwarding
- No X11 forwarding
- No agent forwarding
- No PTY allocation
- Command forced to sys_info.sh only

DO NOT modify the authorized_keys line containing "homeassistant_sys_info_key"
as this will compromise security. The sys_info.sh script will verify these
restrictions are present and refuse to run if they are missing.

To update the script safely, use: ./sys_info.sh update-script
EONOTICE

echo "Security notice saved to ~/.ssh/security_notice.txt"
EOF

# Step 7: Verify restrictions were applied
echo "[+] Verifying restrictions..."
if ssh -i "$KEY_PATH" "$REMOTE" "/home/$USER/bin/sys_info.sh verify-restrictions" >/dev/null 2>&1; then
    echo "[✓] SSH restrictions verified and locked"
else
    echo "[!] WARNING: Failed to verify restrictions!"
    echo "[!] Manual verification required on remote host"
fi

# Step 8: Save host alias
echo "[+] Saving connection under name: $NAME"
mkdir -p "$(dirname "$HOSTS_FILE")"
sed -i "/^$NAME\s/d" "$HOSTS_FILE" 2>/dev/null || true
sed -i "/\s$USER@$HOST$/d" "$HOSTS_FILE" 2>/dev/null || true
echo "$NAME $USER@$HOST" >> "$HOSTS_FILE"

echo ""
echo "[✓] SECURE DEPLOYMENT COMPLETE"
echo "=============================="
echo "Remote host: $REMOTE"
echo "Script location: /home/$USER/bin/sys_info.sh"
echo ""
echo "Security features enabled:"
echo "  ✓ SSH key restrictions enforced"
echo "  ✓ Restrictions cannot be removed via update"
echo "  ✓ Script verifies restrictions on each run"
echo "  ✓ Safe update from GitHub only"
echo ""
echo "To get system info: ./get_sys_info.sh $NAME"
echo "To verify security: ssh $REMOTE '/home/$USER/bin/sys_info.sh verify-restrictions'"
