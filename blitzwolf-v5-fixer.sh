#!/usr/bin/env bash
set -u

APP_NAME="blitzwolf-v5-fixer"
DAEMON_NAME="blitzwolf-v5-daemon.sh"
SERVICE_NAME="blitzwolf-v5-fixer.service"

PROJECTOR_MODE="1920x1080"
MAIN_MODE="1920x1080"
MAIN_X_POS="1920"
APPLY_DELAY="3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDID_BIN_DIR="$SCRIPT_DIR/edid-bin"

FIRMWARE_EDID_DIR="/lib/firmware/edid"
FIRMWARE_EDID_NAME="blitzwolf-v5-projector.bin"
FIRMWARE_EDID_PATH="$FIRMWARE_EDID_DIR/$FIRMWARE_EDID_NAME"

DAEMON_PATH="$HOME/.local/bin/$DAEMON_NAME"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"

GRUB_DEFAULT="/etc/default/grub"

LOG_PREFIX="[$APP_NAME]"

say() {
    echo "$LOG_PREFIX $*"
}

warn() {
    echo "$LOG_PREFIX WARNING: $*" >&2
}

die() {
    echo "$LOG_PREFIX ERROR: $*" >&2
    exit 1
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    while true; do
        if [[ "$default" == "y" ]]; then
            read -r -p "$prompt [Y/n]: " answer
            answer="${answer:-y}"
        else
            read -r -p "$prompt [y/N]: " answer
            answer="${answer:-n}"
        fi

        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_bundled_edid() {
    [[ -d "$EDID_BIN_DIR" ]] || die "EDID folder not found: $EDID_BIN_DIR"

    local preferred
    preferred="$(find "$EDID_BIN_DIR" -maxdepth 1 -type f \
        \( -iname "*projector*.bin" -o -iname "*stk*.bin" -o -iname "*s2*.bin" -o -iname "*good*.bin" -o -iname "*.bin" \) \
        | sort | head -n 1)"

    [[ -n "$preferred" ]] || die "No .bin EDID file found inside: $EDID_BIN_DIR"

    echo "$preferred"
}

connector_from_drm_path() {
    local base
    base="$(basename "$1")"
    echo "${base#card*-}"
}

connected_connectors() {
    local d name
    for d in /sys/class/drm/card*-*; do
        [[ -d "$d" ]] || continue
        [[ -f "$d/status" ]] || continue

        name="$(connector_from_drm_path "$d")"

        if [[ "$(cat "$d/status" 2>/dev/null)" == "connected" ]]; then
            echo "$name"
        fi
    done | sort -u
}

edid_text_for_path() {
    local edid_path="$1"

    if command -v edid-decode >/dev/null 2>&1; then
        edid-decode "$edid_path" 2>/dev/null || true
    else
        strings "$edid_path" 2>/dev/null || true
    fi
}

edid_looks_like_projector() {
    local edid_path="$1"
    local bundled_edid="$2"
    local txt

    [[ -s "$edid_path" ]] || return 1

    if [[ -s "$bundled_edid" ]] && cmp -s "$edid_path" "$bundled_edid"; then
        return 0
    fi

    txt="$(edid_text_for_path "$edid_path")"

    echo "$txt" | grep -Eiq "Manufacturer:[[:space:]]*STK|S2-TEK|SANTAK|CORK" && return 0

    if echo "$txt" | grep -Eiq "Manufacturer:[[:space:]]*SYN|Synaptic|Synaptics"; then
        echo "$txt" | grep -Eiq "Non-PnP|1024x768" && return 0
    fi

    return 1
}

detect_projector_connector() {
    local bundled_edid="$1"
    local d name edid candidates=()

    for d in /sys/class/drm/card*-*; do
        [[ -d "$d" ]] || continue
        [[ -f "$d/status" ]] || continue
        [[ "$(cat "$d/status" 2>/dev/null)" == "connected" ]] || continue

        name="$(connector_from_drm_path "$d")"
        edid="$d/edid"

        if [[ -s "$edid" ]] && edid_looks_like_projector "$edid" "$bundled_edid"; then
            candidates+=("$name")
        fi
    done

    if [[ "${#candidates[@]}" -eq 1 ]]; then
        echo "${candidates[0]}"
        return 0
    fi

    if [[ "${#candidates[@]}" -gt 1 ]]; then
        warn "Multiple possible projector connectors found: ${candidates[*]}"
    else
        warn "Projector connector was not detected automatically."
    fi

    {
        echo
        echo "Connected connectors:"
        connected_connectors | nl -w1 -s") "
        echo
    } >&2

    local choice
    read -r -p "Enter projector connector manually, example DP-1: " choice </dev/tty
    [[ -n "$choice" ]] || die "No projector connector selected."

    echo "$choice"
}

detect_main_connector() {
    local projector="$1"
    local primary
    local connectors=()
    local c

    primary="$(xrandr 2>/dev/null | awk '/ connected primary / {print $1; exit}')"

    if [[ -n "$primary" && "$primary" != "$projector" ]]; then
        echo "$primary"
        return 0
    fi

    while read -r c; do
        [[ -n "$c" ]] || continue
        [[ "$c" == "$projector" ]] && continue
        connectors+=("$c")
    done < <(connected_connectors)

    if [[ "${#connectors[@]}" -eq 1 ]]; then
        echo "${connectors[0]}"
        return 0
    fi

    if [[ "${#connectors[@]}" -gt 1 ]]; then
        warn "Multiple monitor connectors found: ${connectors[*]}"

        {
            echo
            echo "Available monitor connectors:"
            printf '%s\n' "${connectors[@]}" | nl -w1 -s") "
            echo
        } >&2

        local choice
        read -r -p "Enter main monitor connector, example DP-3: " choice </dev/tty
        [[ -n "$choice" ]] || die "No main monitor connector selected."

        echo "$choice"
        return 0
    fi

    die "Could not detect main monitor connector."
}
service_installed() {
    [[ -f "$SERVICE_PATH" || -f "$DAEMON_PATH" ]]
}

service_active() {
    systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

edid_file_installed() {
    [[ -f "$FIRMWARE_EDID_PATH" ]]
}

edid_grub_configured() {
    [[ -f "$GRUB_DEFAULT" ]] || return 1
    grep -q "edid/$FIRMWARE_EDID_NAME" "$GRUB_DEFAULT"
}

edid_current_boot_active() {
    grep -q "edid/$FIRMWARE_EDID_NAME" /proc/cmdline 2>/dev/null
}

show_edid_explanation() {
    cat <<EOF

====================================================================
EDID override explanation
====================================================================

The BlitzWolf/projector sometimes exposes two different EDIDs:

  Good EDID:
    STK / S2-TEK TV / SANTAK-like identity
    Preferred resolution: 1920x1080

  Bad EDID:
    SYN / Non-PnP identity
    Preferred resolution: 1024x768

When this happens, Ubuntu/GNOME treats the same physical projector
as a different monitor and forgets the previous layout/resolution.

This installer can install a Linux kernel DRM EDID override.

It copies the known-good EDID binary to:

  $FIRMWARE_EDID_PATH

and adds a GRUB kernel parameter like:

  drm.edid_firmware=DP-1:edid/$FIRMWARE_EDID_NAME

The connector name is auto-detected before installation.

Important:
  - This affects the selected connector at boot.
  - update-initramfs and update-grub are executed.
  - A reboot is required before the EDID override affects the kernel.
  - This does not force projector ON/OFF state. The ON/OFF layout
    automation is handled separately by the user service.

====================================================================

EOF
}

install_service() {
    local bundled_edid="$1"
    local projector
    local main

    projector="$(detect_projector_connector "$bundled_edid")"
    main="$(detect_main_connector "$projector")"

    say "Detected projector connector: $projector"
    say "Detected main monitor connector: $main"

    mkdir -p "$HOME/.local/bin"
    mkdir -p "$SERVICE_DIR"

    cat > "$DAEMON_PATH" <<EOF
#!/usr/bin/env bash
set -u

PROJECTOR="$projector"
MAIN="$main"

PROJECTOR_MODE="$PROJECTOR_MODE"
MAIN_MODE="$MAIN_MODE"
MAIN_X_POS="$MAIN_X_POS"

LOCK="/tmp/blitzwolf-v5-hotplug-transition.lock"
STATEFILE="/tmp/blitzwolf-v5-hotplug-state"
LOG="\$HOME/blitzwolf-v5-fixer.log"

APPLY_DELAY=$APPLY_DELAY
SAMPLE_COUNT=18
SAMPLE_INTERVAL=0.2

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S.%3N')] \$*" >> "\$LOG"
}

get_line() {
    xrandr 2>/dev/null | grep -E "^\${PROJECTOR} " || true
}

detect_pattern() {
    local first_line=""
    local first_connected=""
    local sample=""
    local i

    log "Starting fast sampling"

    for ((i=1; i<=SAMPLE_COUNT; i++)); do
        sample="\$(get_line)"
        log "sample \$i/\$SAMPLE_COUNT: \$sample"

        if [[ -z "\$first_line" && -n "\$sample" ]]; then
            first_line="\$sample"
            log "First DP line: \$first_line"

            # OFF pattern:
            # DP-1 disconnected 1920x1080+0+0 ...
            if [[ "\$first_line" =~ ^\${PROJECTOR}[[:space:]]disconnected[[:space:]]+[0-9]+x[0-9]+\\+[0-9]+\\+[0-9]+ ]]; then
                log "Detected OFF from first disconnected-with-mode line"
                echo "OFF"
                return 0
            fi

            # ON pattern:
            # DP-1 disconnected (normal left inverted right x axis y axis)
            if [[ "\$first_line" =~ ^\${PROJECTOR}[[:space:]]disconnected[[:space:]]+\\( ]]; then
                log "Detected ON from first disconnected-without-mode line"
                echo "ON"
                return 0
            fi
        fi

        if [[ -z "\$first_connected" && "\$sample" =~ ^\${PROJECTOR}[[:space:]]connected ]]; then
            first_connected="\$sample"
            log "First connected sample: \$first_connected"

            # Secondary OFF pattern:
            # DP-1 connected 1920x1080+0+0 ...
            if [[ "\$first_connected" =~ ^\${PROJECTOR}[[:space:]]connected[[:space:]]+[0-9]+x[0-9]+\\+[0-9]+\\+[0-9]+ ]]; then
                log "Detected OFF from first connected-with-mode line"
                echo "OFF"
                return 0
            fi

            # Secondary ON pattern:
            # DP-1 connected (normal left inverted right x axis y axis)
            if [[ "\$first_connected" =~ ^\${PROJECTOR}[[:space:]]connected[[:space:]]+\\( ]]; then
                log "Detected ON from first connected-without-mode line"
                echo "ON"
                return 0
            fi
        fi

        sleep "\$SAMPLE_INTERVAL"
    done

    echo "UNKNOWN"
}

apply_on() {
    log "Applying ON layout"

    xrandr \\
      --output "\$PROJECTOR" --mode "\$PROJECTOR_MODE" --pos 0x0 --rotate normal --scale 1x1 \\
      --output "\$MAIN" --primary --mode "\$MAIN_MODE" --pos "\${MAIN_X_POS}x0" --rotate normal --scale 1x1 \\
      >> "\$LOG" 2>&1

    log "ON layout applied"
    xrandr | grep -E "^\${PROJECTOR}|^\${MAIN}" >> "\$LOG" 2>&1 || true
}

apply_off() {
    log "Applying OFF layout"

    xrandr \\
      --output "\$PROJECTOR" --off \\
      --output "\$MAIN" --primary --mode "\$MAIN_MODE" --pos 0x0 --rotate normal --scale 1x1 \\
      >> "\$LOG" 2>&1

    log "OFF layout applied"
    xrandr | grep -E "^\${PROJECTOR}|^\${MAIN}" >> "\$LOG" 2>&1 || true
}

handle_hotplug() {
    (
        flock -n 9 || {
            log "Hotplug ignored because another transition is already running"
            exit 0
        }

        log "Hotplug detected"

        local state
        state="\$(detect_pattern)"

        log "Detected state: \$state"

        if [[ "\$state" != "ON" && "\$state" != "OFF" ]]; then
            echo "UNKNOWN \$(date '+%Y-%m-%d %H:%M:%S')" > "\$STATEFILE"
            log "Unknown state, no action"
            exit 0
        fi

        echo "\$state \$(date '+%Y-%m-%d %H:%M:%S')" > "\$STATEFILE"

        log "Waiting \${APPLY_DELAY}s before applying \$state action"
        sleep "\$APPLY_DELAY"

        if [[ "\$state" == "ON" ]]; then
            apply_on
        else
            apply_off
        fi

    ) 9>"\$LOCK"
}

log "BlitzWolf V5 daemon started"
log "Projector: \$PROJECTOR"
log "Main: \$MAIN"

udevadm monitor --kernel --property --subsystem-match=drm | while read -r line; do
    if [[ "\$line" == "HOTPLUG=1" ]]; then
        handle_hotplug &
    fi
done
EOF

    chmod +x "$DAEMON_PATH"

    local display_value="${DISPLAY:-:0}"
    local xauthority_value="${XAUTHORITY:-$HOME/.Xauthority}"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=BlitzWolf V5 projector HDMI hotplug fixer
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
Environment=DISPLAY=$display_value
Environment=XAUTHORITY=$xauthority_value
ExecStart=$DAEMON_PATH
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload

    systemctl --user import-environment DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP 2>/dev/null || true

    systemctl --user enable --now "$SERVICE_NAME"

    say "Service installed and started."
    say "Log file: $HOME/blitzwolf-v5-fixer.log"
    say "Check status with:"
    echo "  systemctl --user status $SERVICE_NAME"
}

uninstall_service() {
    systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true

    rm -f "$SERVICE_PATH"
    rm -f "$DAEMON_PATH"
    rm -f /tmp/blitzwolf-v5-hotplug-transition.lock
    rm -f /tmp/blitzwolf-v5-hotplug-state

    systemctl --user daemon-reload 2>/dev/null || true

    say "Service removed."
}

add_edid_to_grub() {
    local connector="$1"
    local param="drm.edid_firmware=${connector}:edid/${FIRMWARE_EDID_NAME}"

    sudo cp "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak.$APP_NAME.$(date +%Y%m%d-%H%M%S)"

    sudo python3 - "$GRUB_DEFAULT" "$param" "$FIRMWARE_EDID_NAME" <<'PY'
import sys

path = sys.argv[1]
param = sys.argv[2]
edid_name = sys.argv[3]

key = "GRUB_CMDLINE_LINUX_DEFAULT"

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

out = []
found = False

for line in lines:
    if line.startswith(key + "="):
        found = True
        left, right = line.split("=", 1)
        stripped = right.strip()

        quote = '"'
        if stripped.startswith('"') and stripped.endswith('"'):
            quote = '"'
            content = stripped[1:-1]
        elif stripped.startswith("'") and stripped.endswith("'"):
            quote = "'"
            content = stripped[1:-1]
        else:
            content = stripped

        parts = content.split()

        # Remove previous BlitzWolf EDID override if present.
        parts = [
            p for p in parts
            if not (p.startswith("drm.edid_firmware=") and ("edid/" + edid_name) in p)
        ]

        if param not in parts:
            parts.append(param)

        out.append(left + "=" + quote + " ".join(parts) + quote)
    else:
        out.append(line)

if not found:
    out.append(key + '="' + param + '"')

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
}

remove_edid_from_grub() {
    sudo cp "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak.$APP_NAME.$(date +%Y%m%d-%H%M%S)"

    sudo python3 - "$GRUB_DEFAULT" "$FIRMWARE_EDID_NAME" <<'PY'
import sys

path = sys.argv[1]
edid_name = sys.argv[2]

key = "GRUB_CMDLINE_LINUX_DEFAULT"

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

out = []

for line in lines:
    if line.startswith(key + "="):
        left, right = line.split("=", 1)
        stripped = right.strip()

        quote = '"'
        if stripped.startswith('"') and stripped.endswith('"'):
            quote = '"'
            content = stripped[1:-1]
        elif stripped.startswith("'") and stripped.endswith("'"):
            quote = "'"
            content = stripped[1:-1]
        else:
            content = stripped

        parts = content.split()

        parts = [
            p for p in parts
            if not (p.startswith("drm.edid_firmware=") and ("edid/" + edid_name) in p)
        ]

        out.append(left + "=" + quote + " ".join(parts) + quote)
    else:
        out.append(line)

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
}

update_initramfs_and_grub() {
    say "Updating initramfs..."
    sudo update-initramfs -u

    say "Updating GRUB..."
    if command -v update-grub >/dev/null 2>&1; then
        sudo update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    else
        die "Could not find update-grub or grub-mkconfig."
    fi
}

install_edid_override() {
    local bundled_edid="$1"
    local projector

    projector="$(detect_projector_connector "$bundled_edid")"

    say "Detected projector connector for EDID override: $projector"

    if [[ ! -f "$GRUB_DEFAULT" ]]; then
        die "$GRUB_DEFAULT not found. This installer currently supports Ubuntu/GRUB-style systems."
    fi

    sudo mkdir -p "$FIRMWARE_EDID_DIR"
    sudo cp "$bundled_edid" "$FIRMWARE_EDID_PATH"

    say "Copied EDID:"
    echo "  from: $bundled_edid"
    echo "  to:   $FIRMWARE_EDID_PATH"

    add_edid_to_grub "$projector"
    update_initramfs_and_grub

    say "EDID override installed."
    say "Reboot is required before the EDID override becomes active."
}

uninstall_edid_override() {
    if [[ -f "$GRUB_DEFAULT" ]]; then
        remove_edid_from_grub
    fi

    if [[ -f "$FIRMWARE_EDID_PATH" ]]; then
        sudo rm -f "$FIRMWARE_EDID_PATH"
        say "Removed $FIRMWARE_EDID_PATH"
    fi

    update_initramfs_and_grub

    say "EDID override removed."
    say "Reboot is recommended."
}

print_status() {
    echo
    echo "===================================================================="
    echo "Current status"
    echo "===================================================================="

    if service_installed; then
        echo "User service: installed"
        if service_active; then
            echo "User service state: active"
        else
            echo "User service state: not active"
        fi
    else
        echo "User service: not installed"
    fi

    if edid_file_installed; then
        echo "EDID firmware file: installed"
    else
        echo "EDID firmware file: not installed"
    fi

    if edid_grub_configured; then
        echo "EDID GRUB config: configured"
    else
        echo "EDID GRUB config: not configured"
    fi

    if edid_current_boot_active; then
        echo "EDID current boot: active"
    else
        echo "EDID current boot: not active"
    fi

    echo "===================================================================="
    echo
}

main() {
    require_cmd xrandr
    require_cmd udevadm
    require_cmd systemctl
    require_cmd flock
    require_cmd python3
    require_cmd sudo

    local bundled_edid
    bundled_edid="$(find_bundled_edid)"

    show_edid_explanation

    say "Bundled EDID selected:"
    echo "  $bundled_edid"

    if command -v sha256sum >/dev/null 2>&1; then
        echo "  sha256: $(sha256sum "$bundled_edid" | awk '{print $1}')"
    fi

    if command -v edid-decode >/dev/null 2>&1; then
        echo
        echo "Bundled EDID summary:"
        edid-decode "$bundled_edid" 2>/dev/null | grep -Ei "Manufacturer|Product|Display Product|Preferred|Detailed Timing|1920|1024" || true
    else
        warn "edid-decode is not installed. Auto-detection may be less accurate."
        warn "Recommended: sudo apt install edid-decode"
    fi

    print_status

    if service_installed; then
        if ask_yes_no "Service is already installed. Do you want to uninstall it?" "n"; then
            uninstall_service
        else
            say "Service left unchanged."
        fi
    else
        if ask_yes_no "Service is not installed. Do you want to install it?" "y"; then
            install_service "$bundled_edid"
        else
            say "Service installation skipped."
        fi
    fi

    echo

    if edid_file_installed && edid_grub_configured; then
        if ask_yes_no "EDID override appears installed/configured. Do you want to uninstall it?" "n"; then
            uninstall_edid_override
        else
            say "EDID override left unchanged."
        fi
    else
        if ask_yes_no "EDID override is not fully installed/configured. Do you want to install it?" "y"; then
            install_edid_override "$bundled_edid"
        else
            say "EDID override installation skipped."
        fi
    fi

    echo
    say "Done."
    say "Useful commands:"
    echo "  systemctl --user status $SERVICE_NAME"
    echo "  journalctl --user -u $SERVICE_NAME -f"
    echo "  tail -f $HOME/blitzwolf-v5-fixer.log"
    echo
}

main "$@"
