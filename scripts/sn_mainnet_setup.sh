#!/bin/bash

set -e

# Add logging
LOGFILE="supernova_setup.log"
exec 1> >(tee -a "$LOGFILE") 2>&1

# Configuration variables
MONIKER=${MONIKER:-"supernova_node"}
CHAIN_ID="supernova_73405-1"
BINARY_PATH="/usr/local/bin/supernovad"

check_error() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Install dependencies
echo "Installing necessary dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential jq ufw git wget curl

# Configure firewall
echo "Configuring firewall..."
sudo ufw enable
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 26656/tcp # Tendermint P2P
sudo ufw allow 26657/tcp # Tendermint RPC
sudo ufw allow 1317/tcp  # Cosmos SDK REST API
sudo ufw allow 8545/tcp  # EVM HTTP RPC
sudo ufw allow 8546/tcp  # EVM WS RPC
sudo ufw reload

# Setup swap space
echo "Checking for existing swap space..."
if swapon --show | grep -q '/swapfile'; then
    echo "Swap space is already configured. Skipping swap setup."
else
    echo "Setting up swap space..."
    sudo fallocate -l 8G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "Swap space configured successfully."
fi

# Check existing service
if [ -f "/etc/systemd/system/supernova.service" ]; then
    echo "Existing supernova service found..."
    if systemctl is-active --quiet supernova.service; then
        echo "Stopping existing service..."
        sudo systemctl stop supernova.service
        sleep 5
        if systemctl is-active --quiet supernova.service; then
            echo "Error: Failed to stop existing service"
            exit 1
        fi
    fi
    echo "Removing existing service file..."
    sudo systemctl disable supernova.service
    sudo rm /etc/systemd/system/supernova.service
fi

# Determine architecture and check/update Supernova binary
echo "Checking Supernova binary version..."
ARCH=$(dpkg --print-architecture)
LATEST_VERSION=$(curl -s https://api.github.com/repos/AliensZone/supernova/releases/latest | jq -r .tag_name)

CURRENT_VERSION=""
if [ -f "$BINARY_PATH" ]; then
    CURRENT_VERSION=$($BINARY_PATH version)
    CURRENT_NUM=${CURRENT_VERSION#v}
    LATEST_NUM=${LATEST_VERSION#v}

    if [ "$(echo -e "$CURRENT_NUM\n$LATEST_NUM" | sort -V | tail -n1)" = "$CURRENT_NUM" ]; then
        echo "Supernova binary is already at version $CURRENT_VERSION (newer than or equal to latest release $LATEST_VERSION)"
        $BINARY_PATH version
        check_error "Failed to verify binary installation"
    else
        echo "Updating Supernova binary from $CURRENT_VERSION to $LATEST_VERSION..."
        UPDATE_NEEDED=true
    fi
else
    UPDATE_NEEDED=true
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "Supernova binary is up to date ($CURRENT_VERSION)"
elif [ "$UPDATE_NEEDED" = true ]; then
    case $ARCH in
    arm64)
        DOWNLOAD_URL=$(curl -s https://api.github.com/repos/AliensZone/supernova/releases/latest | jq -r '.assets[] | select(.name | test("Linux_arm64")).browser_download_url')
        ;;
    amd64)
        DOWNLOAD_URL=$(curl -s https://api.github.com/repos/AliensZone/supernova/releases/latest | jq -r '.assets[] | select(.name | test("Linux_x86_64")).browser_download_url')
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac

    echo "Downloading latest Supernova binary..."
    wget $DOWNLOAD_URL -O supernova.tar.gz
    tar -xvf supernova.tar.gz
    sudo mv ./bin/supernovad $BINARY_PATH

    NEW_VERSION=$($BINARY_PATH version)
    if [ "$NEW_VERSION" != "$LATEST_VERSION" ]; then
        echo "Error: Version mismatch after installation"
        echo "Expected: $LATEST_VERSION"
        echo "Got: $NEW_VERSION"
        exit 1
    fi
    echo "Successfully updated to version $NEW_VERSION"
fi

# Verify binary is working
$BINARY_PATH version
check_error "Failed to verify binary installation"

# Initialize the node and setup genesis
if [ -f ~/.supernova/config/genesis.json ]; then
    echo "Existing node configuration found..."
    read -p "Do you want to reinitialize the node? This will overwrite existing configuration (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Backing up existing genesis..."
        cp ~/.supernova/config/genesis.json ~/.supernova/config/genesis.json.backup
        echo "Initializing Supernova node..."
        $BINARY_PATH init $MONIKER --chain-id $CHAIN_ID --overwrite
    fi
else
    echo "Initializing Supernova node..."
    $BINARY_PATH init $MONIKER --chain-id $CHAIN_ID
fi

# Setting up genesis
echo "Downloading genesis.json..."
GENESIS_URL="https://raw.githubusercontent.com/AliensZone/supernova-resources/refs/heads/main/mainnet/genesis.json"
GENESIS_HASH="1295ed1a7c2c0657b38336784d59df06b9978d7f749d704a7f3746bdb4ce1a7a"

curl -L $GENESIS_URL -o ~/.supernova/config/genesis.json
check_error "Failed to download genesis file"

DOWNLOADED_HASH=$(sha256sum ~/.supernova/config/genesis.json | awk '{print $1}')
if [ "$GENESIS_HASH" != "$DOWNLOADED_HASH" ]; then
    echo "Genesis hash mismatch!"
    echo "Expected: $GENESIS_HASH"
    echo "Got: $DOWNLOADED_HASH"
    exit 1
fi
echo "Genesis hash verified successfully"

# Ensure database directory exists
echo "Ensuring database directory exists..."
DB_DIR="/root/.supernova/data/db"

if [ ! -d "$DB_DIR" ]; then
    echo "Directory $DB_DIR does not exist. Creating it..."
    sudo mkdir -p "$DB_DIR"
    sudo chmod -R 755 "/root/.supernova"
    echo "Directory created successfully."
else
    echo "Directory $DB_DIR already exists. Skipping creation."
fi

# Configure state sync and general settings
echo "Configuring state sync and node settings..."
LATEST_HEIGHT=$(curl -s https://sync.novascan.io/block | jq -r .result.block.header.height)
BLOCK_HEIGHT=$((LATEST_HEIGHT - 1000))
TRUST_HASH=$(curl -s "https://sync.novascan.io/block?height=$BLOCK_HEIGHT" | jq -r .result.block_id.hash)

# Update config.toml settings
echo "Configuring config.toml..."
sed -i.bak -E \
    "s|^(enable[[:space:]]+=[[:space:]]+).*$|\1true| ; \
    s|^(db_backend[[:space:]]+=[[:space:]]+).*$|\1\"rocksdb\"| ; \
    s|^(db_dir[[:space:]]+=[[:space:]]+).*$|\1\"data/db\"| ; \
    s|^(seeds[[:space:]]+=[[:space:]]+).*$|\1\"2a3cd2768826aed5792593a2d6c8f6b28435a2a7@172.245.233.171:26656\"| ; \
    s|^(rpc_servers[[:space:]]+=[[:space:]]+).*$|\1\"https://sync.novascan.io,https://sync.supernova.zenon.red\"| ; \
    s|^(trust_height[[:space:]]+=[[:space:]]+).*$|\1$BLOCK_HEIGHT| ; \
    s|^(trust_hash[[:space:]]+=[[:space:]]+).*$|\1\"$TRUST_HASH\"| ; \
    s|^(addr_book_strict[[:space:]]+=[[:space:]]+).*$|\1false|" \
    ~/.supernova/config/config.toml

# Update app.toml configurations
echo "Configuring app.toml..."
sed -i.bak -E \
    "s|^(minimum-gas-prices[[:space:]]+=[[:space:]]+).*$|\1\"0stake\"| ; \
    s|^\[json-rpc\][^\[]*enable[[:space:]]*=[[:space:]]*.*|\[json-rpc\]\nenable = false| ; \
    s|^\[memiavl\][^\[]*enable[[:space:]]*=[[:space:]]*.*|\[memiavl\]\nenable = true|" \
    ~/.supernova/config/app.toml

# Create systemd service file
echo "Creating systemd service file..."
cat <<EOF | sudo tee /etc/systemd/system/supernova.service
[Unit]
Description=Supernova Node Service
After=network.target

[Service]
LimitNOFILE=32768
User=root
Group=root
Type=simple
ExecStart=$BINARY_PATH start
ExecStop=/bin/kill -s SIGTERM $MAINPID
Restart=on-failure
TimeoutStopSec=120s
TimeoutStartSec=30s

[Install]
WantedBy=multi-user.target
EOF

# Clean up downloaded files
echo "Cleaning up..."
rm -f supernova.tar.gz
rm -rf ./bin

# Start the service
echo "Starting Supernova node service..."
sudo systemctl daemon-reload
sudo systemctl enable supernova.service
sudo systemctl start supernova.service

# Wait for service to start and verify
sleep 5
for i in {1..3}; do
    if systemctl is-active --quiet supernova.service; then
        echo "Service started successfully"
        break
    elif [ $i -eq 3 ]; then
        echo "Error: Failed to start Supernova service after 3 attempts"
        systemctl status supernova.service
        exit 1
    else
        echo "Attempt $i: Service not running, trying to start again..."
        sudo systemctl restart supernova.service
        sleep 5
    fi
done

# Wait for the node to start responding to status queries
echo "Waiting for node to become responsive..."
for i in {1..12}; do
    if STATUS_OUTPUT=$($BINARY_PATH status 2>&1) && echo "$STATUS_OUTPUT" | jq '.SyncInfo' >/dev/null 2>&1; then
        echo "$STATUS_OUTPUT" | jq '.SyncInfo'
        break
    elif [ $i -eq 12 ]; then
        echo "Warning: Node started but status check failed. Check logs for details."
        echo "Recent logs:"
        sudo journalctl -u supernova.service -n 50 --no-pager
    else
        echo "Waiting for node to respond (attempt $i/12)..."
        sleep 5
    fi
done

echo "Supernova node setup and state sync completed successfully!"
echo "Logs are available in $LOGFILE"
