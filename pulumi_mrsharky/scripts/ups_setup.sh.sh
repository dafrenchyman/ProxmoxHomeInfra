#!/usr/bin/env bash
# setup-nut-proxmox.sh
# Idempotent NUT+Proxmox graceful shutdown installer

set -euo pipefail

### --- CONFIGURABLE DEFAULTS ---
UPS_NAME="myups"
THRESHOLD=20                 # % battery threshold for cron-based shutdown
MONUSER="monuser"
MONPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || echo 'changeme123')"

# Match your UPS (auto-detects CyberPower first, else first HID UPS)
UDEV_VENDORID=""             # e.g. "0764"
UDEV_PRODUCTID=""            # e.g. "0601"
# You can pre-fill the two above to skip auto-detection.

### --- CONSTANTS ---
UDEV_RULE="/etc/udev/rules.d/99-nut-ups.rules"
NUTDIR="/etc/nut"
NUTCONF="$NUTDIR/nut.conf"
UPSCONF="$NUTDIR/ups.conf"
UPSDCONF="$NUTDIR/upsd.conf"
UPSDUSERS="$NUTDIR/upsd.users"
UPSMONCONF="$NUTDIR/upsmon.conf"
SHUTSCRIPT="/usr/local/bin/proxmox-ups-shutdown.sh"
LOCKFILE="/run/proxmox-ups-shutdown.lock"
CRONLINE="* * * * * flock -n ${LOCKFILE} ${SHUTSCRIPT} --from-cron"
BACKUP_SUFFIX=".$(date +%Y%m%d-%H%M%S).bak"

### --- FUNCTIONS ---
bkp() { [[ -f "$1" ]] && sudo cp -a "$1" "$1${BACKUP_SUFFIX}" || true; }

ensure_pkg() {
  sudo apt-get update -y
  sudo apt-get install -y nut nut-server nut-client
}

detect_usb_ids() {
  # If pre-filled, keep them
  if [[ -n "${UDEV_VENDORID}" && -n "${UDEV_PRODUCTID}" ]]; then return 0; fi

  # Prefer CyberPower; else pick first UPS HID-like line
  local line
  line=$(lsusb | grep -i 'cyber' || true)
  if [[ -z "$line" ]]; then
    line=$(lsusb | grep -Ei 'ups|hid|power' | head -n1 || true)
  fi
  if [[ -n "$line" ]]; then
    # line sample: Bus 001 Device 004: ID 0764:0601 CyberPower ...
    UDEV_VENDORID=$(echo "$line" | sed -n 's/.*ID \([0-9a-fA-F]\{4\}\):\([0-9a-fA-F]\{4\}\).*/\1/p')
    UDEV_PRODUCTID=$(echo "$line" | sed -n 's/.*ID \([0-9a-fA-F]\{4\}\):\([0-9a-fA-F]\{4\}\).*/\2/p')
  fi
}

write_configs() {
  sudo mkdir -p "$NUTDIR"

  # nut.conf
  bkp "$NUTCONF"
  sudo tee "$NUTCONF" >/dev/null <<EOF
MODE=standalone
EOF

  # ups.conf
  bkp "$UPSCONF"
  sudo tee "$UPSCONF" >/dev/null <<EOF
[${UPS_NAME}]
    driver = usbhid-ups
    port = auto
    user = nut
    pollinterval = 2
$( [[ -n "$UDEV_VENDORID" && -n "$UDEV_PRODUCTID" ]] && printf "    vendorid = %s\n    productid = %s\n" "$UDEV_VENDORID" "$UDEV_PRODUCTID" )
    desc = "UPS for Proxmox host"
EOF

  # upsd.conf
  bkp "$UPSDCONF"
  sudo tee "$UPSDCONF" >/dev/null <<'EOF'
LISTEN 127.0.0.1 3493
EOF

  # upsd.users
  bkp "$UPSDUSERS"
  sudo tee "$UPSDUSERS" >/dev/null <<EOF
[${MONUSER}]
    password = ${MONPASS}
    upsmon master
EOF
  sudo chown root:nut "$UPSDUSERS" || true
  sudo chmod 640 "$UPSDUSERS" || true

  # upsmon.conf
  bkp "$UPSMONCONF"
  sudo tee "$UPSMONCONF" >/dev/null <<EOF
MONITOR ${UPS_NAME}@localhost 1 ${MONUSER} ${MONPASS} master
SHUTDOWNCMD "${SHUTSCRIPT}"
POWERDOWNFLAG /etc/killpower
MINSUPPLIES 1
FINALDELAY 5
EOF
}

write_shutdown_script() {
  sudo tee "$SHUTSCRIPT" >/dev/null <<'EOS'
#!/bin/bash
set -euo pipefail

UPS="${UPS_NAME:-myups}"
THRESHOLD="${THRESHOLD:-20}"
LOCK="${LOCKFILE:-/run/proxmox-ups-shutdown.lock}"

# Lock (cron and upsmon may both call this)
exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0

# Read status
BATTERY_LEVEL=$(upsc "$UPS" battery.charge 2>/dev/null || echo 100)
STATUS=$(upsc "$UPS" ups.status 2>/dev/null || echo "OL")

has_flag() { [[ " $STATUS " == *" $1 "* ]]; }

logger -t ups "UPS check: level=${BATTERY_LEVEL}% status=${STATUS}"

# Do not shut down if we're online or charging
if has_flag OL || has_flag CHRG; then
  exit 0
fi

# If low and on battery/discharging, initiate graceful shutdown
if (( BATTERY_LEVEL < THRESHOLD )) && ( has_flag OB || has_flag DISCHRG ); then
  logger -t ups "Battery low (${BATTERY_LEVEL}%), initiating Proxmox guest shutdown and host poweroff"

  # VMs
  for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    logger -t ups "Shutting down VM $vmid"
    qm shutdown "$vmid" --skiplock 1 || true
  done

  # Containers
  for ct in $(pct list | awk 'NR>1 {print $1}'); do
    logger -t ups "Shutting down CT $ct"
    pct shutdown "$ct" || true
  done

  # Wait up to 180s for guests to stop
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    running_vms=$(qm list | awk 'NR>1 {print $1}' | xargs -r -n1 qm status 2>/dev/null | grep -c running || true)
    running_cts=$(pct list | awk 'NR>1 {print $1}' | xargs -r -n1 pct status 2>/dev/null | grep -c running || true)
    total=$((running_vms + running_cts))
    if [ "$total" -eq 0 ] || [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 5
  done

  logger -t ups "Guests stopped or timeout reached; powering off host"
  /sbin/poweroff
fi
EOS

  # Inject real values into the script (safe sed replaces placeholders)
  sudo sed -i "s|UPS_NAME:-myups|UPS_NAME:-${UPS_NAME}|g" "$SHUTSCRIPT"
  sudo sed -i "s|THRESHOLD:-20|THRESHOLD:-${THRESHOLD}|g" "$SHUTSCRIPT"
  sudo sed -i "s|LOCKFILE:-/run/proxmox-ups-shutdown.lock|LOCKFILE:-${LOCKFILE}|g" "$SHUTSCRIPT"

  sudo chmod +x "$SHUTSCRIPT"
}

write_udev_rule() {
  if [[ -n "$UDEV_VENDORID" && -n "$UDEV_PRODUCTID" ]]; then
    bkp "$UDEV_RULE"
    sudo tee "$UDEV_RULE" >/dev/null <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="${UDEV_VENDORID}", ATTR{idProduct}=="${UDEV_PRODUCTID}", MODE="0660", GROUP="nut"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger
  fi
}

start_nut_stack() {
  # Clean stale runtime
  sudo mkdir -p /run/nut
  sudo chown nut:nut /run/nut || true
  sudo rm -f /run/nut/*.pid || true

  # Start driver(s)
  sudo upsdrvctl -u nut start || true

  # Start server + monitor
  sudo systemctl restart nut-server
  # Start monitor *after* you verify upsc works; we start it now for full automation:
  sudo systemctl restart nut-monitor

  sudo systemctl enable nut-server nut-monitor
}

install_cron() {
  # Idempotently ensure the cron line exists
  (sudo crontab -l 2>/dev/null | grep -v -F "$SHUTSCRIPT" || true; echo "$CRONLINE") | sudo crontab -
}

validate() {
  echo "=== Validation ==="
  set +e
  upsc -l || true
  upsc "${UPS_NAME}" ups.status || true
  ss -ltn | grep -E ':3493' || true
  systemctl --no-pager --full status nut-server nut-monitor | sed -n '1,120p' || true
  echo "MONITOR user: ${MONUSER}, password: ${MONPASS}"
  echo "If upsc cannot connect yet, unplug AC briefly (leave USB) or replug USB; then: sudo upsdrvctl -u nut start"
}

### --- MAIN ---
ensure_pkg
detect_usb_ids
write_configs
write_shutdown_script
write_udev_rule
install_cron
start_nut_stack
validate

echo "Done. Threshold=${THRESHOLD}%. Shutdown cmd wired via upsmon + cron to: ${SHUTSCRIPT}"
