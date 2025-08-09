#!/usr/bin/env bash

# Ask yes/no helper. Default is "n" unless provided otherwise.
ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local ans
  while true; do
    read -rp "$prompt " ans || exit 1
    if [ -z "$ans" ]; then ans="$default"; fi
    case "$ans" in
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p $SYSTEMD_USER_DIR
ZOND_DIR="$HOME/zond-testnetv1"

# First, check to make sure this is Ubuntu 24.04, and if it's not, exit the script
if [[ ! -f /etc/os-release ]] || [[ "$(grep '^VERSION_ID=' /etc/os-release | cut -d '"' -f2)" != "24.04" ]] || [[ "$(grep '^ID=' /etc/os-release | cut -d '=' -f2)" != "ubuntu" ]]; then
    echo "This script requires Ubuntu 24.04 LTS. Detected: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d '"' -f2)"
    exit 1
fi

# Installing dependencies
sudo apt update -y
sudo apt install -y build-essential git curl screen

# Check for gobrew first, then install gobrew if it's not installed
if ! command -v gobrew &> /dev/null; then
    echo "Installing gobrew..."
    curl -sL https://raw.githubusercontent.com/kevincobain2000/gobrew/master/git.io.sh | bash
else
    echo "gobrew is already installed."
fi

# Modify these next two lines so that they're inserted at the end of ~/.bashrc
if ! grep -q 'gobrew/current/bin' ~/.bashrc; then
    echo 'export PATH="$HOME/.gobrew/current/bin:$HOME/.gobrew/bin:$PATH"' >> ~/.bashrc
    echo 'export GOPATH="$HOME/.gobrew/current/go"' >> ~/.bashrc

    export PATH="$HOME/.gobrew/current/bin:$HOME/.gobrew/bin:$PATH"
    export GOPATH="$HOME/.gobrew/current/go"
    echo "Added gobrew settings to ~/.bashrc"
else
    echo "gobrew settings already in ~/.bashrc"
fi

gobrew use 1.22.12

# Check to see if this folder is already created and ask the user if they want to delete it's contents and start fresh. If not, exit.
if [ -d ~/zond-testnetv1 ]; then
    if ask_yes_no "Directory ~/zond-testnetv1 already exists. Delete contents and continue? [y/N]:"; then
        rm -rf ~/zond-testnetv1
    else
        echo "Exiting as requested."
        exit 0
    fi
fi

mkdir -p ~/zond-testnetv1 && cd ~/zond-testnetv1/

git clone --depth 1 https://github.com/theQRL/go-zond.git
git clone --depth 1 https://github.com/theQRL/qrysm.git

cd go-zond/
make all
cp build/bin/{gzond,clef} ../
cd ~/zond-testnetv1/

cd qrysm
go build -o=../qrysmctl ./cmd/qrysmctl
go build -o=../beacon-chain ./cmd/beacon-chain
go build -o=../validator ./cmd/validator
cd ~/zond-testnetv1/

wget https://github.com/theQRL/go-zond-metadata/raw/refs/heads/main/testnet/testnetv1/genesis.ssz
wget https://raw.githubusercontent.com/theQRL/go-zond-metadata/refs/heads/main/testnet/testnetv1/config.yml

# Save the gzond command to 1-gzond.sh
cat > 1-gzond.sh << 'EOF'
#!/bin/bash
./gzond \
  --nat=extip:0.0.0.0 \
  --testnet \
  --http \
  --http.api "web3,net,zond,engine" \
  --datadir=gzonddata console \
  --syncmode=full \
  --snapshot=false
EOF
chmod +x 1-gzond.sh

# Save the beacon-chain command to 2-beacon-chain.sh
cat > 2-beacon-chain.sh << 'EOF'
#!/bin/bash
./beacon-chain \
  --datadir=beacondata \
  --min-sync-peers=0 \
  --genesis-state=genesis.ssz \
  --bootstrap-node= \
  --chain-config-file=config.yml \
  --config-file=config.yml \
  --chain-id=32382 \
  --execution-endpoint=http://localhost:8551 \
  --accept-terms-of-use \
  --jwt-secret=gzonddata/gzond/jwtsecret \
  --contract-deployment-block=0 \
  --minimum-peers-per-subnet=0 \
  --p2p-static-id \
  --suggested-fee-recipient=Z20e526833d2ab5bd20de64cc00f2c2c7a07060bf \
  --bootstrap-node "enr:-MK4QM50zz3VrN3RgofTTWvFJaZx8fqPrebXtRPrfPma95LABun96pdS48x2vbs3tjjsba6hoTfJP60Jx5g68cjIGjGGAZiJNUY3h2F0dG5ldHOIAAAAAAAAAACEZXRoMpB0w1LqIAAAif__________gmlkgnY0gmlwhC0g6p2Jc2VjcDI1NmsxoQJXCfi0hbGBlSV7exFKsa4iPU41kqSjXvxoTJd9bYwjGohzeW5jbmV0cwCDdGNwgjLIg3VkcIIu4A" \
  --bootstrap-node "enr:-MK4QKoucVoW4hO3nKFPXj1gyYq5_8T1NCpioRMTeFrOdX3IQk6j11_jeYCJ0r3FysBTv831YcuK1wKXfZJE81go7uWGAZiJNeqGh2F0dG5ldHOIAAAAAAAAAACEZXRoMpB0w1LqIAAAif__________gmlkgnY0gmlwhC1MJ0KJc2VjcDI1NmsxoQPp77MwBxOSTTwLPYUci16GSPW9_6tcK1Dj7yDVh87xvIhzeW5jbmV0cwCDdGNwgjLIg3VkcIIu4A" \
  --verbosity debug \
  --log-file beacon.log \
  --log-format text
EOF
chmod +x 2-beacon-chain.sh

# Ask if the user wants a systemd script
if ask_yes_no "Do you want to create systemd services for gzond and beacon-chain? [y/N]:"; then
cat > "$SYSTEMD_USER_DIR/gzond.service" <<EOF
[Unit]
Description=Execution Engine (gzond)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ZOND_DIR
ExecStart=$ZOND_DIR/gzond --nat=extip:0.0.0.0 --testnet --http --http.api "web3,net,zond,engine" --datadir=gzonddata --syncmode=full --snapshot=false
Restart=on-failure
RestartSec=10
StandardOutput=journal

[Install]
WantedBy=default.target
EOF

# beacon chain service uses wrapper script
cat > "$SYSTEMD_USER_DIR/beacon-chain.service" <<EOF
[Unit]
Description=Beacon Chain (qrysm)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ZOND_DIR
ExecStart=$ZOND_DIR/2-beacon-chain.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal

[Install]
WantedBy=default.target
EOF

  echo "Reloading systemd --user daemon..."
  if systemctl --user daemon-reload 2>/dev/null; then
    if ask_yes_no "Enable and start gzond.service and beacon-chain.service now? [y/N]" "n"; then
      systemctl --user enable --now gzond.service beacon-chain.service
      echo "Enabled and started services (if your system supports user systemd)."
    else
      echo "You can enable/start them later with:"
      echo "  systemctl --user enable --now gzond.service beacon-chain.service"
    fi
  else
    echo "Couldn't reload systemd --user daemon. You may need to run the following manually in a user session:"
    echo "  systemctl --user daemon-reload"
    echo "Then enable/start the services:"
    echo "  systemctl --user enable --now gzond.service beacon-chain.service"
  fi

  if ask_yes_no "Enable user lingering (loginctl enable-linger \$USER) so services can run after reboot without a user login? This requires sudo. [y/N]" "n"; then
    sudo loginctl enable-linger "$USER"
    echo "Enabled linger for $USER. Services can now run across reboots when enabled."
  fi
fi

echo "All done. Files and binaries are in $ZOND_DIR"
echo "Start gzond manually with: $ZOND_DIR/1-gzond.sh"
echo "Start beacon-chain manually with: $ZOND_DIR/2-beacon-chain.sh"

if [ -d "$HOME/.config/systemd/user" ]; then
  echo "If systemd units were created you can manage them with: systemctl --user (start|stop|status) gzond.service beacon-chain.service"
fi