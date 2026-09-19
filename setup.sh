#!/bin/bash
FIRST_SIGINT=0
cleanup() {
    echo ""
    if [ "$FIRST_SIGINT" -eq 0 ]; then
        FIRST_SIGINT=1
        echo "You used CTRL + C to stop the script."
        # If a compose stack was started, leave it running — but tell the user.
        if [ "$COMPOSE_STARTED" = "1" ]; then
            echo "ℹ️  Docker Compose services were already started; they were NOT torn down. To stop them interrupt again."
            read -p "Do you want to stop them now? (y/n): " STOP_COMPOSE
            if [ "$STOP_COMPOSE" == "y" ]; then
                echo "Stopping Docker Compose services..."
                docker compose down
            else
                echo "ℹ️  Docker Compose services were left running."
            fi
        fi
        exit 130
    else
        if [ "$COMPOSE_STARTED" = "1" ]; then
            echo "Stopping Docker Compose services..."
            cd ./docker
            docker compose down
        else
            echo "bye!"
        fi
    fi
}   
trap cleanup SIGINT

COMPOSE_STARTED=0

echo "If you don't know what's the difference between server and client, use ctrl + c and ask to an AI before running this script."
read -p "Is this the server or client? (y/n): " IS_SERVER
TERMUX=$(echo "$PREFIX" | grep -q "com.termux" && echo 1 || echo 0)

if [ "$IS_SERVER" == "y" ]; then
    if TERMUX -eq 1; then
        echo "Your phone isn't a server"
        exit 1
    fi
    echo "🔐 Checking SSH server status..."
    # 1. Install openssh-server if sshd is not present
    if ! command -v sshd > /dev/null 2>&1; then
        echo "sshd not found. Installing openssh-server..."
        sudo apt-get update
        sudo apt-get install -y openssh-server
        echo "✅ openssh-server installed."
    else
        echo "✅ sshd already installed at $(command -v sshd)"
    fi
    # 2. Ensure SSH service is enabled and running
    if sudo systemctl is-active --quiet ssh; then
        echo "✅ SSH service is already running."
    else
        echo "Starting and enabling SSH service..."
        sudo systemctl enable ssh
        sudo systemctl start ssh
        echo "✅ SSH service started."
    fi
    # 3. Check if any authorized keys exist for this user
    AUTH_KEYS="$HOME/.ssh/authorized_keys"
    HAS_KEYS=0

    if [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ]; then
        HAS_KEYS=1
        echo "✅ Authorized keys found ($(grep -c '^ssh-' "$AUTH_KEYS") key(s))."
    else
        echo "⚠️  No authorized keys found. Password authentication is needed for initial key setup."
    fi

    # 4. If no keys exist, ensure PasswordAuthentication is enabled

    if [ "$HAS_KEYS" -eq 0 ]; then
        SSHD_CONFIG="/etc/ssh/sshd_config"

        # Check current effective value
        CURRENT_PW_AUTH=$(sudo sshd -T 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}')

        if [ "$CURRENT_PW_AUTH" = "yes" ]; then
            echo "✅ PasswordAuthentication is already enabled."
        else
            echo "Enabling PasswordAuthentication in sshd_config..."

            # Remove any existing (commented or not) PasswordAuthentication lines
            sudo sed -i '/^[#[:space:]]*PasswordAuthentication/d' "$SSHD_CONFIG"

            # Append the setting
            echo "PasswordAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null

            # Test config before restarting
            if sudo sshd -t 2>/dev/null; then
                sudo systemctl restart ssh
                echo "✅ PasswordAuthentication enabled and SSH restarted."
            else
                echo "❌ sshd config test failed. Restoring not needed (we only added a line)."
                echo "   Check with: sudo sshd -t"
                exit 1
            fi
        fi
    else
        echo "Keys exist; leaving PasswordAuthentication unchanged."
    fi    

    cd ./cloudflared
    
    if command -v cloudflared > /dev/null 2>&1; then
        echo "cloudflared ya está instalado en $(command -v cloudflared)"
    else
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null

        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null

        sudo apt-get update
        sudo apt-get install -y cloudflared
    fi
    CERT_FILE="./cert.pem"
    if [ -f "$CERT_FILE" ]; then
        echo "Authentication file found!"
    else
        echo "Authenticate in a navigator, this wont go on until you log in."
        cloudflared tunnel login
    fi
    DEFAULT_NAME="my-tunnel"
    read -p "Tunnel name: " TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-$DEFAULT_NAME}"
    echo "Creating tunnel with name: $TUNNEL_NAME"
    cloudflared tunnel create "$TUNNEL_NAME" 
    TUNNEL_UUID="$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2 == name {print $1}' | head -n 1)"
    if [ -z "$TUNNEL_UUID" ]; then
    echo "Tunnel UUID not found: $TUNNEL_NAME"
    exit 1
    fi
    echo "Tunnel UUID: $TUNNEL_UUID"
    CONFIG_FILE="./config.yaml"
    if [ -f "$CONFIG_FILE" ]; then
        sed -i "s/<TUNNEL_UUID>/$TUNNEL_UUID/g" "$CONFIG_FILE"
    else
        echo "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    cd ../docker
    COMPOSE_STARTED=1
    docker compose up -d
    sleep 3
    if docker compose ps --status running | grep -q cloudflare-tunnel; then
        echo "Cloudflared is running via Docker Compose."
    else
        echo "Container failed to start. Logs:"
        docker compose logs cloudflared
        exit 1
    fi
    # --- Recolectar datos ---
    SSH_USER="$(whoami)"
    SSH_IP="$(hostname -I | awk '{print $1}')"
    SSH_PORT="$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
    SSH_PORT="${SSH_PORT:-22}"   # si no hay línea Port, es el 22 por defecto

    # --- Construir el bloque de info ---
    SSH_INFO="$SSH_USER@$SSH_IP -p $SSH_PORT"
    echo "⚠️ ¡IMPORTANT! You need to remember this to connect from the client"
    echo "🔑 SSH connection info: $SSH_INFO"

    if command -v wl-copy > /dev/null 2>&1; then
        printf '%s' "$SSH_INFO" | wl-copy
        echo "📋 Copied to clipboard (Wayland)."
    elif command -v xclip > /dev/null 2>&1; then
        printf '%s' "$SSH_INFO" | xclip -selection clipboard
        echo "📋 Copied to clipboard (X11, xclip)."
    elif command -v xsel > /dev/null 2>&1; then
        printf '%s' "$SSH_INFO" | xsel --clipboard --input
        echo "📋 Copied to clipboard (X11, xsel)."
    fi
else
    echo "🔑 Checking SSH client status..."
    # 1. Install openssh-client if ssh is not present
    if ! command -v ssh > /dev/null 2>&1; then
        echo "ssh not found. Installing openssh-client..."
        if echo $PREFIX | grep -o "com.termux" > /dev/null 2>&1; then
            (pkg update && pkg install openssh)
        else
            sudo apt-get update
            sudo apt-get install -y openssh-client
        fi
        echo "✅ openssh-client installed."
    else
        echo "✅ ssh already installed at $(command -v ssh)"
    fi
    if ! command -v cloudflared > /dev/null 2>&1; then
        echo "cloudflared not found. Installing..."
        if TERMUX -eq 1; then
            pkg update && pkg upgrade -y
            pkg install cloudflared -y
        else
            sudo apt-get update
            sudo apt-get install -y cloudflared
        fi
    else
        echo "✅ cloudflared already installed at $(command -v cloudflared)"
    fi
    # --- Key path ---
    KEY_PATH="$HOME/.ssh/id_rsa"
    # --- Copy public key to server ---
    echo "If you executed the setup.sh in the server, you recieved 'user@ip -p port'"
    echo "Example: admin@192.168.0.100 -p 22"
    echo "now is when you need to remember it"
    read -p "Remote user: " SSH_USER
    read -p "Remote IP: " SSH_HOST
    read -p "Remote SSH port: " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$KEY_PATH"
    # --- Generate key pair if missing ---
    if [ -f "$KEY_PATH" ]; then
        echo "⚠️  Key already exists at $KEY_PATH."
        read -p "Do you want to copy it to a server? (y/n): " COPY_EXISTING
        if [ "$COPY_EXISTING" == "y" ]; then

            if [ -z "$SSH_USER" ] || [ -z "$SSH_HOST" ]; then
                echo "❌ User and host cannot be empty."
                exit 1
            fi
            if ssh-copy-id -i "${KEY_PATH}.pub" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST"; then
                echo "✅ Public key copied to server."
            else
                echo "❌ Failed to copy public key."
                exit 1
            fi
        else
            echo "Nothing was changed."
            exit 0
        fi
        
    else
        read -p "Do you want to generate a new key pair? (is it safer than using only a password) (y/n): " GENERATE_KEY
        if [ "$GENERATE_KEY" == "y" ]; then
            echo "Generating RSA key pair..."
            ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -C "$SSH_USER@$SSH_HOST"
            echo "✅ Key generated at $KEY_PATH"
            chmod 644 "${KEY_PATH}.pub"
            echo "✅ Client-side permissions set (700 for .ssh, 600 for private key)."


            if [ -z "$SSH_USER" ] || [ -z "$SSH_HOST" ]; then
                echo "❌ User and host cannot be empty."
                exit 1
            fi
            echo "Copying public key to $SSH_USER@$SSH_HOST..."
            if ssh-copy-id -i "${KEY_PATH}.pub" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST"; then
                echo "✅ Public key copied to server."
            else
                echo "❌ Failed to copy public key. Check your password and server details."
                exit 1
            fi

            # --- Verify key-based login works ---
            echo "Verifying key-based login..."
            if ssh -i "$KEY_PATH" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 \
                "$SSH_USER@$SSH_HOST" "echo ok" > /dev/null 2>&1; then
                echo "✅ Key-based login works."
            else
                echo "❌ Key-based login failed. Aborting before any further changes."
                exit 1
            fi

            echo "If you want to disable password authentication, (recommended for safety), run in a local session of the server (I don't recommend doing it on a remote ssh session):"
            echo "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-disable-password.conf > /dev/null && sudo sshd -t && sudo systemctl restart ssh"
            echo "And try logging in again with the generated key."
        else
            echo "Nothing was changed."
            exit 0
        fi
    fi
    touch config
    read -p "Domain: " DOMAIN
    cat << EOF >> config
    Host cloudflare-tunnel
        HostName ssh.$DOMAIN
        User $SSH_USER
        IdentityFile $KEY_PATH
        Port $SSH_PORT
        ProxyCommand cloudflared access ssh --hostname %h 
EOF
    
    echo "✅ Client setup complete. Use ssh cloudflare-tunnel to connect"
fi 