#!/bin/bash
set -e

# Variables
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
ZOND_DIR="$HOME/zond-testnetv1"
GOBREW_BIN="$HOME/.gobrew/bin/gobrew"

# Minimum requirements
MIN_CPU_CORES=2
MIN_RAM_GB=2
MIN_STORAGE_GB=50

# Helper Functions
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Progress + logging utilities
LOGFILE="$(mktemp -t zond-install-XXXXXX.log)"
SPIN='-\|/'
spinner() {
  local pid="$1" msg="$2" i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r[%c] %s" "${SPIN:i++%4:1}" "$msg"
    sleep 0.1
  done
}

run_step() {
  local desc="$1"; shift
  local cmd="$*"
  # Run command in a subshell, pipe all output to the log
  ( bash -o pipefail -c "$cmd" >>"$LOGFILE" 2>&1 ) &
  local pid=$!
  spinner "$pid" "$desc"
  wait "$pid"
  local ec=$?
  if [ $ec -eq 0 ]; then
    printf "\r${GREEN}[PASS]${NC} %s\n" "$desc"
  else
    printf "\r${GREEN}[FAIL]${NC} %s\n" "$desc"
    echo "See log for details: $LOGFILE"
    echo "Last 20 lines:"
    tail -n 20 "$LOGFILE" | sed 's/^/  /'
    exit $ec
  fi
}

ensure_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "Sudo privileges are required. You may be prompted for your password."
  sudo -v || { echo "Sudo authentication failed."; exit 1; }
}

# Main Script
echo "Starting Zond Testnet v1 installation."
echo "Detailed logs will be written to: $LOGFILE"
echo "-----------------------------------------------------"

# OS & System requirements check
echo -n "Checking system compatibility... "
if [[ ! -f /etc/os-release ]] || [[ "$(grep '^VERSION_ID=' /etc/os-release | cut -d '"' -f2)" != "24.04" ]] || [[ "$(grep '^ID=' /etc/os-release | cut -d '=' -f2)" != "ubuntu" ]]; then
    echo -e "${RED}✗ Failed${NC}"
    echo "This script requires Ubuntu 24.04 LTS. Detected: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d '"' -f2)"
    exit 1
else
    echo -e "${GREEN}✓ Ubuntu 24.04 detected${NC}"
fi

# Check CPU cores
CPU_CORES=$(nproc)
echo "CPU Cores detected: $CPU_CORES"

# Check RAM (in GB, rounded to nearest)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_KB/1024/1024}")
echo "RAM detected: ${TOTAL_RAM_GB} GB"

# Check available storage
AVAILABLE_STORAGE_KB=$(df / | tail -1 | awk '{print $4}')
AVAILABLE_STORAGE_GB=$((AVAILABLE_STORAGE_KB / 1024 / 1024))
AVAILABLE_STORAGE_GB_PRECISE=$(awk "BEGIN {printf \"%.2f\", $AVAILABLE_STORAGE_KB/1024/1024}")
echo "Available storage: ${AVAILABLE_STORAGE_GB_PRECISE} GB"

# CPU Check
if [ "$CPU_CORES" -lt "$MIN_CPU_CORES" ]; then
    echo -e "${RED}✗ FAIL: Minimum $MIN_CPU_CORES CPU cores required${NC}"
    CPU_CHECK=false
else
    echo -e "${GREEN}✓ PASS: CPU cores requirement met${NC}"
    CPU_CHECK=true
fi

# Ram check
if [ "$TOTAL_RAM_GB" -lt "$MIN_RAM_GB" ]; then
    echo -e "${RED}✗ FAIL: Minimum $MIN_RAM_GB GB RAM required${NC}"
    RAM_CHECK=false
else
    echo -e "${GREEN}✓ PASS: RAM requirement met${NC}"
    RAM_CHECK=true
fi

if [ "$AVAILABLE_STORAGE_GB" -lt "$MIN_STORAGE_GB" ]; then
    echo -e "${YELLOW}✗ WARNING: Minimum $MIN_STORAGE_GB GB storage recommended${NC}"
    STORAGE_CHECK=false
else
    echo -e "${GREEN}✓ PASS: Storage requirement met${NC}"
    STORAGE_CHECK=true
fi

# Final result
if [ "$CPU_CHECK" = true ] && [ "$RAM_CHECK" = true ]; then
    if [ "$STORAGE_CHECK" = false ]; then
        echo -e "${YELLOW}Warning: Low storage space detected!${NC}"
        if ask_yes_no "Do you want to continue anyway? [y/N]" "n"; then
            echo -e "${GREEN}Continuing with low storage...${NC}"
        else
            echo -e "${RED}Installation aborted due to insufficient storage.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}System meets all requirements!${NC}"
    fi
else
    echo -e "${RED}System does NOT meet minimum requirements!${NC}"
    echo "CPU and RAM requirements are mandatory."
    exit 1
fi

# Get sudo up front so spinners won't get stuck on a password prompt
ensure_sudo

# Prepare directories
run_step "Create systemd user dir" "mkdir -p '$SYSTEMD_USER_DIR'"

# Refresh apt and install base deps
run_step "Update apt cache" "sudo apt-get -y update"
run_step "Install dependencies" "sudo apt-get install -y build-essential git curl screen"

if ! command -v gobrew &> /dev/null; then
    run_step "Install gobrew" "curl -sL https://raw.githubusercontent.com/kevincobain2000/gobrew/master/git.io.sh | bash"
else
    echo "gobrew is already installed. Skipping."
fi

# Ensure gobrew PATH for this session and future shells
if ! grep -q 'gobrew/current/bin' "$HOME/.bashrc" 2>/dev/null; then
  run_step "Add gobrew PATH to ~/.bashrc" "printf '%s\n' 'export PATH=\"\$HOME/.gobrew/current/bin:\$HOME/.gobrew/bin:\$PATH\"' >> '$HOME/.bashrc'"
  run_step "Add GOPATH to ~/.bashrc" "printf '%s\n' 'export GOPATH=\"\$HOME/.gobrew/current/go\"' >> '$HOME/.bashrc'"
fi

# Export for current shell
export PATH="$HOME/.gobrew/current/bin:$HOME/.gobrew/bin:$PATH"
export GOPATH="$HOME/.gobrew/current/go"

# Install specific Go version with gobrew
run_step "Install Go 1.22.12 via gobrew" "\"$GOBREW_BIN\" use 1.22.12"

# Handle existing install directory
if [ -d "$ZOND_DIR" ]; then
  if ask_yes_no "Directory $ZOND_DIR already exists. Delete contents and continue? [y/N]:"; then
    run_step "Remove existing $ZOND_DIR" "rm -rf '$ZOND_DIR'"
  else
    echo "Exiting as requested."
    exit 0
  fi
fi

run_step "Create $ZOND_DIR" "mkdir -p '$ZOND_DIR'"
cd "$ZOND_DIR" || { echo "Failed to change directory to $ZOND_DIR"; exit 1; }

run_step "Cloning go-zond repository" "git clone --depth 1 https://github.com/theQRL/go-zond.git"
run_step "Cloning qrysm repository" "git clone --depth 1 https://github.com/theQRL/qrysm.git"

echo "Building binaries (this may take a few minutes)..."

# Build Binaries
cd go-zond/ || { echo "Failed to enter go-zond directory"; exit 1; }
run_step "  - Building go-zond" "make all"
run_step "  - Copying gzond binaries" "cp build/bin/{gzond,clef} ../"
cd ../

cd qrysm/ || { echo "Failed to enter qrysm directory"; exit 1; }
run_step "  - Building qrysmctl" "go build -o=../qrysmctl ./cmd/qrysmctl"
run_step "  - Building beacon-chain" "go build -o=../beacon-chain ./cmd/beacon-chain"
run_step "  - Building validator" "go build -o=../validator ./cmd/validator"
cd ../

# Download metadata
run_step "Download genesis.ssz" "cd '$ZOND_DIR' && curl -fsSL -o genesis.ssz https://github.com/theQRL/go-zond-metadata/raw/refs/heads/main/testnet/testnetv1/genesis.ssz"
run_step "Download config.yml" "cd '$ZOND_DIR' && curl -fsSL -o config.yml https://raw.githubusercontent.com/theQRL/go-zond-metadata/refs/heads/main/testnet/testnetv1/config.yml"

# Verify binaries
run_step "Verify built binaries" "test -x '$ZOND_DIR/gzond' && test -x '$ZOND_DIR/clef' && test -x '$ZOND_DIR/qrysmctl' && test -x '$ZOND_DIR/beacon-chain' && test -x '$ZOND_DIR/validator'"

# Create helper scripts
run_step "Create 1-gzond.sh" "cat > '$ZOND_DIR/1-gzond.sh' << 'EOF'
#!/bin/bash
./gzond \
  --nat=extip:0.0.0.0 \
  --testnet \
  --http \
  --http.api \"web3,net,zond,engine\" \
  --datadir=gzonddata console \
  --syncmode=full \
  --snapshot=false
EOF
chmod +x '$ZOND_DIR/1-gzond.sh'"

run_step "Create 2-beacon-chain.sh" "cat > '$ZOND_DIR/2-beacon-chain.sh' << 'EOF'
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
  --bootstrap-node "enr:-MK4QBUiE0sz67x3RrGbyEKZYnJRLp1gv3UkUEsON18nkisZTM7iV5ACYdZyaWvz1vghvrBO079kf90jHQnOTEn_yf2GAZmls6Ozh2F0dG5ldHOIAAAAAAAAAACEZXRoMpB0w1LqIAAAif__________gmlkgnY0gmlwhC0g6p2Jc2VjcDI1NmsxoQIhBcsnDFoKva4aeNktuAxWb7IxY948okJ1bpv20P_MGYhzeW5jbmV0cwCDdGNwgjLIg3VkcIIu4A" \
  --bootstrap-node "enr:-MK4QFirz10ntbN32_GOn6B1uZRU5rj6b4bEoP9o4yf_MlrGINIW4nICvCWexO3dHRYJIbIFXfEUQ3c3oHNYd3p_SjWGAZmltUODh2F0dG5ldHOIAAAAAAAAAACEZXRoMpB0w1LqIAAAif__________gmlkgnY0gmlwhC1MJ0KJc2VjcDI1NmsxoQNPBaBuj93C-yFVRC4mWoK315QM9O0SWdf741t3sbPtNIhzeW5jbmV0cwCDdGNwgjLIg3VkcIIu4A" \
  --verbosity debug \
  --log-file beacon.log \
  --log-format text
EOF
chmod +x '$ZOND_DIR/2-beacon-chain.sh'"

# Optionally create systemd user services
if ask_yes_no "Do you want to create systemd services for gzond and beacon-chain? [y/N]:"; then
  run_step "Write gzond.service" "cat > '$SYSTEMD_USER_DIR/gzond.service' <<EOF
[Unit]
Description=Execution Engine (gzond)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ZOND_DIR
ExecStart=$ZOND_DIR/gzond --nat=extip:0.0.0.0 --testnet --http --http.api \"web3,net,zond,engine\" --datadir=gzonddata --syncmode=full --snapshot=false
Restart=on-failure
RestartSec=10
StandardOutput=journal

[Install]
WantedBy=default.target
EOF"
  run_step "Write beacon-chain.service" "cat > '$SYSTEMD_USER_DIR/beacon-chain.service' <<EOF
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
EOF"

  # Reload user daemon
  if systemctl --user daemon-reload >>"$LOGFILE" 2>&1; then
    if ask_yes_no "Enable and start gzond.service and beacon-chain.service now? [y/N]" "n"; then
      if systemctl --user enable --now gzond.service beacon-chain.service >>"$LOGFILE" 2>&1; then
        echo "Enabled and started services."
      else
        echo "Failed to enable/start user services. See log: $LOGFILE"
      fi
    else
      echo "You can enable/start them later with:"
      echo "  systemctl --user enable --now gzond.service beacon-chain.service"
    fi
  else
    echo "Couldn't reload systemd --user daemon. You may need to run manually:"
    echo "  systemctl --user daemon-reload"
    echo "Then enable/start the services:"
    echo "  systemctl --user enable --now gzond.service beacon-chain.service"
  fi

  # Optional lingering
  if ask_yes_no "Enable user lingering (loginctl enable-linger $USER) so services can run after reboot without a user login? This requires sudo. [y/N]" "n"; then
    ensure_sudo
    run_step "Enable linger for $USER" "sudo loginctl enable-linger '$USER'"
  fi
fi

echo "-----------------------------------------------------"
echo -e "${GREEN}All done! Files and binaries are in $ZOND_DIR${NC}"
echo
echo "All done. Files and binaries are in $ZOND_DIR"
echo "Install log saved to: $LOGFILE"
echo
echo "To start services manually:"
echo "  cd $ZOND_DIR"
echo "  ./1-gzond.sh"
echo "  ./2-beacon-chain.sh"
echo
if [ -d "$SYSTEMD_USER_DIR" ]; then
  echo "If systemd units were created you can manage them with:"
  echo "  systemctl --user status gzond.service beacon-chain.service"
  echo "  systemctl --user (start|stop|restart) gzond.service beacon-chain.service"
fi
