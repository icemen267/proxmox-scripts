#!/usr/bin/env bash
# =============================================================================
#  Lokales LLM auf Proxmox – Teil 2: Einrichtung IM CONTAINER
#  Lemonade (llama.cpp mit Vulkan auf der Radeon 890M) + Qwen3.6-35B-A3B + Open WebUI
#
#  Wird von 01-proxmox-host.sh automatisch ausgeführt.
#  Kann auch manuell im Container laufen:  bash 02-container-setup.sh
# =============================================================================
set -euo pipefail

# ----------------------------- Einstellungen ---------------------------------
MODEL="unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"   # ~21 GB
CTX_SIZE=32768                               # Kontextlänge (Tokens)
LEMONADE_PORT=13305
WEBUI_PORT=3000
# -----------------------------------------------------------------------------

info()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARNUNG]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[FEHLER]\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen."
export DEBIAN_FRONTEND=noninteractive

wait_for_lemonade() {
  local auth=()
  [[ -n "${LEMONADE_API_KEY:-}" ]] && auth=(-H "Authorization: Bearer ${LEMONADE_API_KEY}")
  echo -n "    Warte auf Lemonade "
  for _ in $(seq 1 60); do
    if curl -sf "${auth[@]}" "http://localhost:${LEMONADE_PORT}/api/v1/health" >/dev/null; then
      echo " ok"; return 0
    fi
    echo -n "."; sleep 2
  done
  echo; fail "Lemonade antwortet nicht. Log ansehen mit: journalctl -u lemond -n 50"
}

# --- 1. System und Vulkan-Treiber --------------------------------------------
info "Aktualisiere System und installiere Vulkan-Treiber ..."
apt-get update
apt-get -y upgrade
apt-get install -y software-properties-common curl ca-certificates openssl \
                   mesa-vulkan-drivers vulkan-tools

info "Prüfe, ob die iGPU im Container sichtbar ist ..."
ls /dev/dri/renderD* &>/dev/null || fail "Kein /dev/dri/renderD* im Container – GPU-Durchreichen prüfen."
VK_DEVICES=$(vulkaninfo --summary 2>/dev/null | grep -i 'deviceName' || true)
echo "${VK_DEVICES}" | sed 's/^/    /'
if [[ "${VK_DEVICES,,}" != *radeon* ]]; then
  warn "Vulkan erkennt keine Radeon-GPU. Lemonade würde dann auf der CPU rechnen."
fi

# --- 2. Lemonade installieren -------------------------------------------------
info "Installiere Lemonade ..."
add-apt-repository -y ppa:lemonade-team/stable
apt-get update
apt-get install -y lemonade-server
systemctl enable --now lemond
wait_for_lemonade

# --- 3. Lemonade konfigurieren ------------------------------------------------
info "Konfiguriere Lemonade (Netzwerkzugriff, Vulkan, Kontextlänge) ..."
lemonade config set host=0.0.0.0 llamacpp.backend=vulkan ctx_size=${CTX_SIZE}

# API-Schlüssel, weil Lemonade jetzt im ganzen Netz erreichbar ist
API_KEY=$(openssl rand -hex 24)
mkdir -p /etc/systemd/system/lemond.service.d
cat > /etc/systemd/system/lemond.service.d/api-key.conf <<EOF
[Service]
Environment=LEMONADE_API_KEY=${API_KEY}
EOF
systemctl daemon-reload
systemctl restart lemond
export LEMONADE_API_KEY="${API_KEY}"
wait_for_lemonade

# --- 4. Modell herunterladen --------------------------------------------------
info "Lade ${MODEL} herunter (ca. 21 GB, das dauert eine Weile) ..."
lemonade pull "${MODEL}"
echo "    Installierte Modelle:"
lemonade list | sed 's/^/    /'

# --- 5. Docker + Open WebUI ---------------------------------------------------
info "Installiere Docker ..."
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

info "Starte Open WebUI ..."
docker rm -f open-webui &>/dev/null || true
docker run -d \
  --name open-webui \
  --restart always \
  -p ${WEBUI_PORT}:8080 \
  --add-host=host.docker.internal:host-gateway \
  -e OPENAI_API_BASE_URL="http://host.docker.internal:${LEMONADE_PORT}/api/v1" \
  -e OPENAI_API_KEY="${API_KEY}" \
  -e ENABLE_OLLAMA_API=false \
  -e ENABLE_TITLE_GENERATION=false \
  -e ENABLE_FOLLOW_UP_GENERATION=false \
  -e ENABLE_TAGS_GENERATION=false \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main

# --- 6. Zusammenfassung -------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')
cat > /root/llm-zugangsdaten.txt <<EOF
Open WebUI:        http://${IP}:${WEBUI_PORT}
Lemonade-API:      http://${IP}:${LEMONADE_PORT}/api/v1   (OpenAI-kompatibel)
Lemonade-API-Key:  ${API_KEY}
Modell:            ${MODEL}
EOF
chmod 600 /root/llm-zugangsdaten.txt

info "Fertig!"
cat /root/llm-zugangsdaten.txt | sed 's/^/    /'
echo
echo "    Open WebUI braucht beim ersten Start 1-2 Minuten."
echo "    Das erste Konto, das du dort anlegst, wird Administrator."
echo "    Zugangsdaten liegen in /root/llm-zugangsdaten.txt"
