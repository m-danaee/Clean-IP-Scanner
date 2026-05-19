#!/usr/bin/env bash

set -eo pipefail

clear

echo "=========================================="
echo "   Clean IP Scanner - Installer"
echo "=========================================="
echo ""

PLATFORM="linux"
XRAY_ASSET=""
INSTALL_TARGET=""
APT_PROXY="${APT_PROXY:-http://127.0.0.1:10808}"

case "${APT_PROXY}" in
    http://127.0.0.1:*|http://localhost:*)
        ;;
    *)
        echo "✗ APT_PROXY must point to a local proxy (http://127.0.0.1:* or http://localhost:*)"
        exit 1
        ;;
esac

if [[ -n "${TERMUX_VERSION:-}" ]] || [[ "${PREFIX:-}" == *"/com.termux/"* ]]; then
    PLATFORM="termux"
    XRAY_ASSET="Xray-android-arm64-v8a.zip"
    INSTALL_TARGET="${PREFIX}/bin"
else
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64)
            XRAY_ASSET="Xray-linux-64.zip"
            ;;
        aarch64|arm64)
            XRAY_ASSET="Xray-linux-arm64-v8a.zip"
            ;;
        armv7l|armv7)
            XRAY_ASSET="Xray-linux-arm32-v7a.zip"
            ;;
        *)
            echo "✗ Unsupported Linux architecture: ${ARCH}"
            echo "  Supported: x86_64/amd64, aarch64/arm64, armv7l/armv7"
            exit 1
            ;;
    esac
    INSTALL_TARGET="/usr/local/bin"
fi

echo "Detected platform: ${PLATFORM}"
echo "Xray package: ${XRAY_ASSET}"
echo ""

echo "[1/6] Checking and installing packages..."
if [[ "${PLATFORM}" == "termux" ]]; then
    for cmd in git go curl unzip jq; do
        if ! command -v "${cmd}" &> /dev/null; then
            pkg_name="${cmd}"
            if [[ "${cmd}" == "go" ]]; then
                pkg_name="golang"
            fi
            echo "  → Installing ${pkg_name}..."
            pkg install -y "${pkg_name}" || { echo "✗ Failed to install ${pkg_name}"; exit 1; }
        fi
    done
else
    export DEBIAN_FRONTEND=noninteractive
    SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &> /dev/null; then
            SUDO="sudo"
        else
            echo "✗ sudo is required on Linux to install dependencies"
            exit 1
        fi
    fi

    APT_COMMAND=(apt-get -o "Acquire::HTTP::Proxy=${APT_PROXY}" -o "Acquire::HTTPS::Proxy=${APT_PROXY}")
    if [[ -n "${SUDO}" ]]; then
        APT_COMMAND=("${SUDO}" "${APT_COMMAND[@]}")
    fi

    "${APT_COMMAND[@]}" update
    "${APT_COMMAND[@]}" install -y git golang-go curl unzip jq ca-certificates
fi
echo "✓ All packages ready"

echo ""
echo "[2/6] Downloading source code..."
cd "${HOME}"
if [ -d "Clean-IP-Scanner" ]; then
    echo "  → Removing old installation..."
    rm -rf Clean-IP-Scanner
fi
git clone -q https://github.com/m-danaee/Clean-IP-Scanner.git || { echo "✗ Failed to clone repository"; exit 1; }
cd Clean-IP-Scanner || { echo "✗ Directory not found"; exit 1; }
echo "✓ Source code downloaded"

echo ""
echo "[3/6] Downloading dependencies..."
go mod tidy || { echo "✗ Failed to download dependencies"; exit 1; }
echo "✓ Dependencies ready"

echo ""
echo "[4/6] Installing Xray core (${XRAY_ASSET})..."

if [ -f "./xray/xray" ]; then
    echo "  → Xray binary already present, skipping download."
else
    MAX_RETRIES=3
    RETRY_COUNT=0

    download_xray() {
        echo "  → Fetching latest Xray release URL (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."

        LATEST_URL=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r ".assets[] | select(.name==\"${XRAY_ASSET}\") | .browser_download_url")

        if [ -z "${LATEST_URL}" ] || [ "${LATEST_URL}" = "null" ]; then
            echo "  → Could not get download URL from API"
            return 1
        fi

        echo "  → Downloading from ${LATEST_URL}"
        curl -L --retry 3 --retry-delay 5 -o xray-core.zip "${LATEST_URL}" || { echo "  → Download failed"; return 1; }

        if [ ! -f xray-core.zip ] || [ ! -s xray-core.zip ]; then
            echo "  → Downloaded file is missing or empty"
            return 1
        fi

        unzip -o xray-core.zip -d xray_temp || { echo "  → Unzip failed"; rm -f xray-core.zip; return 1; }
        mkdir -p xray
        cp xray_temp/xray xray/
        chmod +x xray/xray
        rm -rf xray_temp xray-core.zip
        return 0
    }

    while [ "${RETRY_COUNT}" -lt "${MAX_RETRIES}" ]; do
        if download_xray; then
            echo "✓ Xray core installed"
            break
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ "${RETRY_COUNT}" -lt "${MAX_RETRIES}" ]; then
                echo "  → Retrying in 15 seconds..."
                sleep 15
            fi
        fi
    done

    if [ ! -f "./xray/xray" ]; then
        echo ""
        echo "  → Auto-detection failed. Trying fallback version..."
        FALLBACK_VERSION="v26.3.27"
        FALLBACK_URL="https://github.com/XTLS/Xray-core/releases/download/${FALLBACK_VERSION}/${XRAY_ASSET}"
        echo "  → Downloading ${FALLBACK_VERSION} from ${FALLBACK_URL}"

        if curl -L --retry 3 -o xray-core.zip "${FALLBACK_URL}" && \
           unzip -o xray-core.zip -d xray_temp && \
           mkdir -p xray && \
           cp xray_temp/xray xray/ && \
           chmod +x xray/xray; then
            rm -rf xray_temp xray-core.zip
            echo "✓ Xray core installed (fallback version ${FALLBACK_VERSION})"
        else
            rm -rf xray_temp xray-core.zip
            echo "✗ Failed to install Xray core. Please check your internet connection."
            exit 1
        fi
    fi
fi

echo ""
echo "[5/6] Setting up Xray config files..."
mkdir -p config

if [ ! -f "config/xray_config.json" ]; then
    cat > config/xray_config.json << 'EOF_JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 1080,
      "protocol": "socks",
      "settings": { "udp": false },
      "listen": "127.0.0.1"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "IP_PLACEHOLDER",
            "port": 443,
            "users": [
              { "id": "your-uuid-here", "encryption": "none", "flow": "xtls-rprx-vision" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "your-domain.com",
          "allowInsecure": false
        }
      }
    }
  ]
}
EOF_JSON
    echo "✓ Sample JSON config created at config/xray_config.json"
else
    echo "✓ Existing xray_config.json found, keeping it."
fi

if [ ! -f "config/xray_config.txt" ]; then
    cat > config/xray_config.txt << 'EOF_TXT'
# Xray URL Config
# Put your proxy URL on the line below (remove the # at the start).
# Supported formats: vless://, vmess://, trojan://, ss://
# Example:
# vless://your-uuid@your-server.com:443?type=ws&security=tls&host=your-server.com&path=%2F&sni=your-server.com#MyConfig
#
# If this file has a valid URL, it will be used instead of xray_config.json.
EOF_TXT
    echo "✓ Sample URL config created at config/xray_config.txt"
else
    echo "✓ Existing xray_config.txt found, keeping it."
fi

echo ""
echo "[6/6] Building clean-ip-scanner..."
echo "  (This may take 1-2 minutes...)"
CGO_ENABLED=0 go build -ldflags="-s -w" -o clean-ip-scanner || { echo "✗ Build failed"; exit 1; }
if [ ! -f "clean-ip-scanner" ]; then
    echo "✗ Build failed - executable not created"
    exit 1
fi
echo "✓ Build completed"

echo ""
echo "Installing launcher..."

LAUNCHER_TMP="$(mktemp)"
cat > "${LAUNCHER_TMP}" << 'EOF_SCRIPT'
#!/usr/bin/env bash
cd "$HOME/Clean-IP-Scanner"
./clean-ip-scanner "$@"
EOF_SCRIPT

if [[ "${PLATFORM}" == "termux" ]]; then
    mkdir -p "${INSTALL_TARGET}"
    install -m 755 "${LAUNCHER_TMP}" "${INSTALL_TARGET}/clean-ip-scanner"
    echo "✓ Installed to ${INSTALL_TARGET}/clean-ip-scanner"
else
    if install -m 755 "${LAUNCHER_TMP}" "${INSTALL_TARGET}/clean-ip-scanner"; then
        echo "✓ Installed to ${INSTALL_TARGET}/clean-ip-scanner"
    elif command -v sudo &> /dev/null; then
        echo "  → Direct install failed, retrying with sudo..."
        sudo install -m 755 "${LAUNCHER_TMP}" "${INSTALL_TARGET}/clean-ip-scanner"
        echo "✓ Installed to ${INSTALL_TARGET}/clean-ip-scanner"
    else
        mkdir -p "${HOME}/.local/bin"
        install -m 755 "${LAUNCHER_TMP}" "${HOME}/.local/bin/clean-ip-scanner"
        echo "✓ Installed to ${HOME}/.local/bin/clean-ip-scanner"
        echo "  → Add this to PATH if needed: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

rm -f "${LAUNCHER_TMP}"

echo ""
echo "=========================================="
echo "   Installation completed successfully!"
echo "=========================================="
echo ""
echo "Usage:"
echo "  clean-ip-scanner"
echo ""
echo "  You will be asked to choose scan mode:"
echo "    1) Normal scan (TCP ping + speed test)"
echo "    2) Xray scan (uses Xray core with your config)"
echo ""
echo "  For Xray mode, edit ONE of these files:"
echo "    URL format : ~/Clean-IP-Scanner/config/xray_config.txt"
echo "    JSON format: ~/Clean-IP-Scanner/config/xray_config.json"
echo ""
echo "  Results saved to: clean_ips.txt and clean_ips_list.txt"
echo ""
echo "You can now run: clean-ip-scanner"
echo ""
