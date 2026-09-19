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
if command -v sshd > /dev/null 2>&1; then
    IS_SERVER="y"
elif command -v ssh > /dev/null 2>&1; then
    IS_SERVER="n"
else 
    echo "If you don't know what's the difference between server and client, use ctrl + c and ask to an AI before running this script."
    read -p "Is this the server or client? (y/n): " IS_SERVER
fi
while getopts "sch" flag; do
    case "${flag}" in
        (s) IS_SERVER="y";;
        (c) IS_SERVER="n";;
        (h) echo "Usage: setup.sh [-s] (server) [-c] (client)"; exit 0;;
    esac
done
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

        echo "✅ Authorized keys found ($(grep -c '^ssh-' "$AUTH_KEYS") key(s))."
    else
        # 4. If no keys exist, ensure PasswordAuthentication is enabled
        echo "⚠️ No authorized keys found"
        echo "Checking if password authentication is configured. It's needed for initial key setup."
        SSHD_CONFIG="/etc/ssh/sshd_config"

        # Check current effective value
        CURRENT_PW_AUTH=$(sudo sshd -T 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}')

        if [ "$CURRENT_PW_AUTH" = "yes" ]; then
            echo "✅ PasswordAuthentication is already enabled."
        else
            echo "❌ PasswordAuthentication is not enabled."
            echo "Config backup saved to $SSHD_CONFIG.bak"
            copy "$SSHD_CONFIG" "$SSHD_CONFIG.bak"
            echo "Enabling PasswordAuthentication in $SSHD_CONFIG"
            # Remove any existing (commented or not) PasswordAuthentication lines
            sudo sed -i '/^[#[:space:]]*PasswordAuthentication/d' "$SSHD_CONFIG"

            # Append the setting
            echo "PasswordAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
            echo "✅ PasswordAuthentication enabled"
            # Test config before restarting
            if sudo sshd -t 2>/dev/null; then
                sudo systemctl restart ssh
                echo "✅ SSH restarted."
                
            else
                echo "❌ sshd config test failed. Restoring backup."
                copy "$SSHD_CONFIG.bak" "$SSHD_CONFIG"
                sudo systemctl restart ssh
                exit 1
            fi
        fi
    fi    
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
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
            if ! command -v qrencode > /dev/null 2>&1; then
                sudo apt install qrencode -y
            fi
            cloudflared tunnel login 2>&1 | tee /dev/tty | grep -oE "https://cloudflare.com[^ ]+" | while read -r url; do 
                echo -e "\n========================================="
                echo "¡SCAN THIS QR CODE TO AUTHENTICATE WITH CLOUDFLARE!"
                echo -e "=========================================\n"
                qrencode -t ansiutf8 "$url"; 
                echo "URL: $url"; 
            done
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
        echo "Starting to compose the container"
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
        echo "$TUNNEL_UUID"
    else
        echo "Now use the client, run a ssh session, use the password an execute again this setup (inside of the server via the ssh session)"
        SSH_USER="$(whoami)"
        SSH_IP="$(hostname -I | awk '{print $1}')"
        SSH_PORT="$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
        SSH_PORT="${SSH_PORT:-22}"
        SSH_INFO="ssh $SSH_USER@$SSH_IP -p $SSH_PORT"
        echo "⚠️ ¡IMPORTANT! You need to remember this to connect from the client"
        echo "🔑 Use exactly this command: $SSH_INFO"

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
        exit 0
    fi
# Is client
else
    read -p "This script should be run in the server first. Did you run it already? (y/n): " RUNNED
    if [ "$RUNNED" != "y" ]; then
        echo "You should do that first, and then you can run this script here, again."
        exit 0
    fi
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
    KEY_PATH="$HOME/.ssh/id_rsa"
    # --- Copy public key to server ---
    echo "If you executed the setup.sh in the server, you recieved a command 'ssh user@ip -p port'"
    echo "Example: admin@192.168.0.100 -p 22"
    echo "now is when you need to remember it"
    read -p "Server user: " SSH_USER
    read -p "Server IP: " SSH_HOST
    read -p "SSH port: " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$KEY_PATH"
    if [ -f "$KEY_PATH" ]; then
        echo "⚠️  Key already exists at $KEY_PATH."
        read -p "Do you want to copy it to the server? (y/n): " COPY_EXISTING
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
        
    # --- Generate key pair if missing ---
    else
        echo "⚠️ Only say no if you know what you're doing. The risks of using only a password are high."
        read -p "Do you want to generate a RSA key pair? VERY RECOMMENDED (y/n): " GENERATE_KEY
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

            echo "Verifying login"
            if ssh -t -i "$KEY_PATH" -p "$SSH_PORT" -o ConnectTimeout=5 "$SSH_USER@$SSH_HOST" "exit 0"; then
                echo "✅ Login successful."
                read -p "Do you want to disable password-based login? Highly recommended (y/n): " DISABLE_PASSWORD
                if [ "$DISABLE_PASSWORD" == "y" ]; then
                    echo "Disabling password-based login"
                    ssh -t -i "$KEY_PATH" -p "$SSH_PORT" -o ConnectTimeout=5 "$SSH_USER@$SSH_HOST" "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-disable-password.conf > /dev/null && sudo sshd -t && sudo systemctl restart ssh"
                fi
            else
                echo "❌ Login failed. Aborting before any further changes."
                exit 1
            fi
            echo "Disabling password-based login"
            
        fi
    fi
    if ! ssh -i "$KEY_PATH" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'docker compose ps --status running | grep -q cloudflare-tunnel'; then
        ssh -i "$KEY_PATH" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'curl -s -O https://raw.githubusercontent.com/facuvatti/ssh-tunnel-cloudflare/main/setup.sh && bash setup.sh 1' | tee tunnel_setup.log
        echo "✅ Tunnel setup logs saved to tunnel_setup.log in the same directory that you run this script."
    else 
        echo "✅ Tunnel already running at $SSH_USER@$SSH_HOST"
    fi
    touch "$HOME/.ssh/config"
    # here should be an execution of playwright to get done all the manual things
    read -p "Have you already done all the steps explained on the README.md? (y/n)" DONE_README
    if [ "$DONE_README" == "y" ]; then
        echo "Domain example: example.dpdns.org (without the prefix 'ssh.')"
        read -p "Domain: " DOMAIN
        if [ -z "$KEY_PATH" ]; then
            IDENTITY_FILE_LINE = ""
        else
            IDENTITY_FILE_LINE="IdentityFile $KEY_PATH"
        fi
        cat << EOF >> "$HOME/.ssh/config"
        Host cloudflare-tunnel
            HostName ssh.$DOMAIN
            User $SSH_USER
            $IDENTITY_FILE_LINE
            Port $SSH_PORT
            ProxyCommand cloudflared access ssh --hostname %h 
EOF
        echo "✅ Client setup complete. Use ssh cloudflare-tunnel to connect over internet."
    else
        echo "You should do that first, and then you can run this script again."
    fi
fi 