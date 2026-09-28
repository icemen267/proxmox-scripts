#!/usr/bin/env bash
# =============================================================================
#  Lokales LLM auf Proxmox – Teil 1: Container auf dem Proxmox-HOST anlegen
#  Hardware: Ryzen AI 9 HX 370 / Radeon 890M / 48 GB RAM
#
#  Ausführen als root auf dem Proxmox-Host, im selben Ordner wie
#  02-container-setup.sh:
#      bash 01-proxmox-host.sh
# =============================================================================
set -euo pipefail

# ----------------------------- Einstellungen ---------------------------------
CTID=200                    # Container-ID (muss frei sein)
CT_HOSTNAME="llm"
MEMORY=32768                # RAM in MB (32 GB – Modell ~21 GB + Kontext + Open WebUI)
SWAP=4096                   # Swap in MB
CORES=12                    # CPU-Kerne
DISK_GB=100                 # Festplatte in GB (Modell ~21 GB, Docker, Backends)
STORAGE="local-zfs"         # Storage für die Container-Festplatte
TEMPLATE_STORAGE="local"    # Storage für Container-Templates
BRIDGE="vmbr0"              # Netzwerk-Bridge
# -----------------------------------------------------------------------------

info()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARNUNG]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[FEHLER]\033[0m $*"; exit 1; }

[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen."
command -v pct >/dev/null || fail "pct nicht gefunden – läuft das Skript auf dem Proxmox-Host?"
[[ -f ./02-container-setup.sh ]] || fail "02-container-setup.sh muss im selben Ordner liegen."
pct status "$CTID" &>/dev/null && fail "Container-ID $CTID ist schon belegt. Bitte CTID oben ändern."

# --- Proxmox-Version prüfen (dev0-Durchreichen braucht PVE 8.2+) --------------
PVE_VER=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+')
info "Proxmox VE $PVE_VER erkannt"
if [[ $(printf '%s\n' "8.2" "$PVE_VER" | sort -V | head -n1) != "8.2" ]]; then
  fail "Proxmox VE 8.2 oder neuer wird benötigt (für das Durchreichen der GPU per dev0)."
fi

# --- iGPU finden ---------------------------------------------------------------
info "Suche die AMD-iGPU (amdgpu) ..."
lsmod | grep -q '^amdgpu' || fail "Kernelmodul amdgpu ist nicht geladen."
RENDER_NODE=""
for node in /sys/class/drm/renderD*; do
  drv=$(basename "$(readlink -f "$node/device/driver")" 2>/dev/null || true)
  if [[ "$drv" == "amdgpu" ]]; then
    RENDER_NODE="/dev/dri/$(basename "$node")"
    break
  fi
done
[[ -n "$RENDER_NODE" ]] || fail "Kein amdgpu-Render-Device unter /dev/dri gefunden."
echo "    GPU-Render-Device: $RENDER_NODE"

# --- Speicher-Hinweis ----------------------------------------------------------
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo "    Für Linux sichtbarer RAM: ${TOTAL_MB} MB"
if (( TOTAL_MB < 40000 )); then
  warn "Linux sieht weniger als 40 GB RAM. Vermutlich ist im BIOS ein großer"
  warn "'UMA Frame Buffer' reserviert. Stell ihn auf einen kleinen Wert (z. B. 2-4 GB);"
  warn "die iGPU holt sich den Rest dynamisch (GTT), und der RAM bleibt flexibel."
fi

# --- Ubuntu-24.04-Template besorgen --------------------------------------------
info "Suche Ubuntu-24.04-Template ..."
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard' | sort -V | tail -n1)
[[ -n "$TEMPLATE" ]] || fail "Kein Ubuntu-24.04-Template gefunden."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  info "Lade $TEMPLATE herunter ..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# --- Container anlegen ----------------------------------------------------------
info "Lege Container $CTID ($CT_HOSTNAME) an ..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --ostype ubuntu \
  --dev0 "${RENDER_NODE},mode=0666"
# nesting/keyctl: nötig für Docker (Open WebUI)
# dev0: reicht die iGPU durch; mode=0666, damit der Lemonade-Dienstnutzer zugreifen darf

info "Starte Container ..."
pct start "$CTID"

echo -n "    Warte auf Netzwerk "
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts ppa.launchpadcontent.net &>/dev/null; then echo " ok"; break; fi
  echo -n "."; sleep 2
done

# --- Teil 2 im Container ausführen ----------------------------------------------
info "Kopiere und starte die Einrichtung im Container (das dauert – das Modell hat ~21 GB) ..."
pct push "$CTID" ./02-container-setup.sh /root/02-container-setup.sh --perms 755
pct exec "$CTID" -- bash /root/02-container-setup.sh

info "Fertig. Mit 'pct enter $CTID' kommst du in den Container."
