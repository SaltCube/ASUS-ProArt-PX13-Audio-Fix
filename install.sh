#!/usr/bin/env bash
#
# Install the TAS2783 stereo fix for the ASUS ProArt PX13 (HN7306EAC).
#
# This automates README.md step for step; the numbered steps below match the
# numbered steps in that document. Read it if you want to know why any of this
# is needed, or if you would rather run the commands by hand.
#
# Run ./install.sh --help for the options.
#
# Run as your normal user, not as root: step 5 installs a per-user WirePlumber
# config, and sudo is called only for the steps that need it.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KVER=$(uname -r)
MODDIR="/usr/lib/modules/$KVER"
MODULE=snd-soc-tas2783-sdw.ko
SRC_INSTALL_DIR=/usr/local/src/tas2783
SYSTEM_CONF="$REPO_DIR/systems/HN7306EAC.conf"
FIRMWARE_EXE=""   # set by --firmware, an installer the user already downloaded
FIRMWARE_PROVENANCE=""   # "asus" if the vendor vouched for the installer hash
WITH_BUS_RESET=0  # set by --with-bus-reset, installs the once-per-boot service

if [ -t 1 ]; then
    BOLD=$(tput bold); RED=$(tput setaf 1); GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4); RESET=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD$BLUE" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ ok ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf '    %s[fail]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$BOLD$RED" "$RESET" "$*" >&2; exit 1; }

# ALSA card id for the SoundWire card, e.g. "amdsoundwire". Needed by the
# verification step; not known until the card exists, so this is looked up
# lazily rather than at startup.
detect_card() {
    local f id
    for f in /proc/asound/card*/id; do
        [ -r "$f" ] || continue
        id=$(cat "$f")
        case "$id" in
            *soundwire*|*sdw*) echo "$id"; return 0 ;;
        esac
    done
    return 1
}

# The install/ tree mirrors where its files land: install/root/<path> installs
# to /<path>, install/home/<path> to $HOME/<path>. That tree is the single
# list of what this repo installs, read by both install and uninstall, and
# file modes come from the repo files themselves (git tracks the executable
# bit), so nothing here re-declares a destination or a mode.
overlay_dest() {
    case "$1" in
        install/root/*) printf '/%s\n' "${1#install/root/}" ;;
        install/home/*) printf '%s/%s\n' "$HOME" "${1#install/home/}" ;;
        *) return 1 ;;
    esac
}

overlay_install() {
    local rel="$1" src dest mode
    src="$REPO_DIR/$rel"
    dest=$(overlay_dest "$rel") || die "not an overlay path: $rel"
    mode=$(stat -c %a "$src")
    case "$rel" in
        install/root/*) sudo install -D -m "$mode" "$src" "$dest" ;;
        *)              install -D -m "$mode" "$src" "$dest" ;;
    esac
    ok "installed to $dest"
}

# Step 0: prerequisites. Everything here is a hard requirement for the build,
# so a failure stops the script before anything has been touched.
step0_prerequisites() {
    step "Step 0: checking prerequisites"

    local kmajor kminor missing=()
    kmajor=${KVER%%.*}
    kminor=${KVER#*.}; kminor=${kminor%%.*}
    if [ "$kmajor" -lt 7 ] || { [ "$kmajor" -eq 7 ] && [ "$kminor" -lt 2 ]; }; then
        die "kernel $KVER is too old, 7.2 or newer is required (see README.md step 0)"
    fi
    ok "kernel $KVER"

    # The headers must be for the running kernel, not just any installed kernel.
    [ -e "$MODDIR/build/Makefile" ] ||
        die "no kernel headers for $KVER at $MODDIR/build
    Install the headers package matching your kernel, for example:
      sudo pacman -S linux-cachyos-rc-headers"
    ok "kernel headers present"

    # LLVM=1: CachyOS kernels are clang-built, so the module must be too.
    local tool
    for tool in make clang ld.lld llvm-objcopy; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ ${#missing[@]} -eq 0 ] ||
        die "missing build tools: ${missing[*]}
    Install them with:
      sudo pacman -S --needed base-devel clang llvm lld"
    ok "build toolchain present"

    # The UCM file lands in the sof-soundwire tree, which alsa-ucm-conf only
    # routes this card through from 1.2.16 on.
    if command -v pacman >/dev/null 2>&1; then
        local ucmver
        ucmver=$(pacman -Q alsa-ucm-conf 2>/dev/null | awk '{print $2}' || true)
        if [ -n "$ucmver" ]; then
            if [ "$(printf '1.2.16\n%s\n' "$ucmver" | sort -V | head -1)" = "1.2.16" ]; then
                ok "alsa-ucm-conf $ucmver"
            else
                warn "alsa-ucm-conf $ucmver is older than 1.2.16; the Speaker device may not appear"
            fi
        fi
    fi

    [ -f "$REPO_DIR/src/tas2783/tas2783-sdw.c" ] ||
        die "run this script from inside the repo clone (src/tas2783 not found)"
}

# Ask ASUS for the current driver list and print the SmartAmp entry's download
# URL, SHA-256 and version, one per line. This is what keeps the install
# working across driver updates: both the link and the hash come from the
# vendor at run time rather than being pinned in this repo.
discover_installer() {
    command -v python3 >/dev/null 2>&1 || return 1
    local api="https://www.asus.com/support/api/product.asmx/GetPDDrivers"
    curl -sfL --max-time 30 -A "Mozilla/5.0" \
        "$api?website=global&model=${ASUS_MODEL}&osid=${ASUS_OSID}" 2>/dev/null |
    python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
want = sys.argv[1].lower()
for group in data.get("Result", {}).get("Obj", []):
    for f in group.get("Files", []):
        if want in (f.get("Title") or "").lower():
            url = (f.get("DownloadUrl") or {}).get("Global") or ""
            sha = (f.get("sha256") or "").lower()
            if url and sha:
                print(url)
                print(sha)
                print(f.get("Version") or "unknown")
                sys.exit(0)
sys.exit(1)
' "$DRIVER_TITLE_MATCH"
}

# Fetch the installer and check it against the hash the vendor publishes for
# it. Sets FIRMWARE_PROVENANCE so the caller knows whether the hash came from
# ASUS just now or from the fallback recorded in this repo.
download_installer() {
    local dest="$1" found url sha version actual

    # shellcheck source=/dev/null
    . "$SYSTEM_CONF"
    command -v curl >/dev/null 2>&1 || return 1

    if found=$(discover_installer); then
        url=$(printf '%s\n' "$found" | sed -n 1p)
        sha=$(printf '%s\n' "$found" | sed -n 2p)
        version=$(printf '%s\n' "$found" | sed -n 3p)
        FIRMWARE_PROVENANCE=asus
        ok "ASUS lists driver $version"
    else
        url="${INSTALLER_URL:-}"
        sha="${INSTALLER_SHA256:-}"
        FIRMWARE_PROVENANCE=recorded
        warn "could not read the ASUS driver list, falling back to the recorded link"
    fi
    [ -n "$url" ] && [ -n "$sha" ] || return 1

    info "Downloading the installer (about 4 MB)..."
    curl -fL --progress-bar -A "Mozilla/5.0" --max-time 300 -o "$dest" "$url" || return 1

    # Never feed the extractor something unverified: an error page or a captive
    # portal would otherwise be treated as an installer.
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$actual" != "$sha" ]; then
        warn "downloaded file does not match the SHA-256 published for it"
        rm -f "$dest"
        return 1
    fi
    ok "downloaded and verified against the vendor SHA-256"
}

# Extract the blobs from the ASUS Windows installer and install them under both
# names the driver tries. Only reached when linux-firmware does not ship them.
extract_and_install_firmware() {
    local exe="$1" name8 nameB

    [ -f "$exe" ] || die "no such file: $exe"
    [ -r "$SYSTEM_CONF" ] || die "missing $SYSTEM_CONF"

    local tool
    for tool in wrestool 7z; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "$tool is needed to extract the firmware.
    Install it with: sudo pacman -S --needed icoutils 7zip"
    done

    info "Extracting from $(basename "$exe")..."
    # extract-firmware.sh verifies the SHA-256 of the installer and of both
    # blobs, and writes them to ./firmware/ relative to the repo.
    #
    # When the installer itself was just verified against the hash ASUS
    # publishes for it, blobs that differ from the ones recorded here mean a
    # newer driver, not a corrupt download, so that is a warning rather than a
    # hard stop. Without that provenance the recorded blob hashes stay binding.
    local allow=0
    [ "$FIRMWARE_PROVENANCE" = "asus" ] && allow=1
    ( cd "$REPO_DIR" && FIRMWARE_ALLOW_UNKNOWN="$allow" ./extract-firmware.sh "$exe" >/dev/null ) ||
        die "firmware extraction failed, run ./extract-firmware.sh directly to see why"

    # Blob names come from the same per-system config the extractor uses, so
    # they are defined in exactly one place.
    # shellcheck source=/dev/null
    . "$SYSTEM_CONF"
    name8=${FIRMWARE_8_NAME/0x/}   # the kernel drops the 0x: 1714-1-0x8.bin -> 1714-1-8.bin
    nameB=${FIRMWARE_B_NAME/0x/}

    sudo install -Dm644 "$REPO_DIR/firmware/$FIRMWARE_8_NAME" "/lib/firmware/$name8"
    sudo install -Dm644 "$REPO_DIR/firmware/$FIRMWARE_B_NAME" "/lib/firmware/$nameB"
    sudo install -Dm644 "$REPO_DIR/firmware/$FIRMWARE_8_NAME" "/lib/firmware/ti/audio/tas2783/$name8"
    sudo install -Dm644 "$REPO_DIR/firmware/$FIRMWARE_B_NAME" "/lib/firmware/ti/audio/tas2783/$nameB"
    ok "firmware installed as $name8 and $nameB"
}

# Step 2: firmware. Normally nothing to do, since linux-firmware ships the
# blobs. When it does not, they can only come from the ASUS Windows installer,
# which cannot be downloaded automatically, so this asks for it rather than
# pretending it can fetch it.
step2_firmware() {
    step "Step 2: checking firmware"

    if [ -e /lib/firmware/1714-1-0x8.bin.zst ] && [ -e /lib/firmware/1714-1-0xB.bin.zst ]; then
        ok "firmware shipped by linux-firmware"
        return 0
    fi
    if [ -e /lib/firmware/1714-1-8.bin ] && [ -e /lib/firmware/1714-1-B.bin ]; then
        ok "firmware installed manually"
        return 0
    fi

    warn "firmware blobs not detected, the speakers stay silent without them"

    # An installer the user passed in, or one already sitting in the repo.
    local candidate="$FIRMWARE_EXE"
    if [ -z "$candidate" ]; then
        candidate=$(find "$REPO_DIR" -maxdepth 1 -iname 'SmartAMP*.exe' 2>/dev/null | head -1)
        [ -n "$candidate" ] && info "found $(basename "$candidate") in the repo"
    fi
    if [ -n "$candidate" ]; then
        extract_and_install_firmware "$candidate"
        return 0
    fi

    if [ ! -t 0 ]; then
        info "Re-run interactively, or pass an installer: ./install.sh --firmware=PATH"
        return 0
    fi

    if ask_yn "Download the ASUS driver and extract the firmware now?"; then
        # shellcheck source=/dev/null
        . "$SYSTEM_CONF"
        if download_installer "$REPO_DIR/$INSTALLER_FILENAME"; then
            extract_and_install_firmware "$REPO_DIR/$INSTALLER_FILENAME"
            return 0
        fi
        warn "automatic download failed"
    fi

    # ASUS serves the download button as a signed, short-lived URL, so a
    # browser is the reliable fallback rather than another scripted attempt.
    # shellcheck source=/dev/null
    . "$SYSTEM_CONF"
    printf '\n    Download "TI Smart Amplifier Driver for Speakers" from:\n'
    printf '      %s\n' "$SUPPORT_URL"
    printf '\n    Then re-run:\n'
    printf '      ./install.sh --firmware=/path/to/%s\n\n' "$INSTALLER_FILENAME"
    die "firmware is required for the speakers to make any sound"
}

# Step 3: build the patched module and put it where depmod prefers it over the
# in-tree one.
step3_module() {
    step "Step 3: building and installing the patched module"

    make -C "$MODDIR/build" M="$REPO_DIR/src/tas2783" LLVM=1 modules
    sudo install -Dm644 "$REPO_DIR/src/tas2783/$MODULE" "$MODDIR/updates/$MODULE"
    sudo depmod "$KVER"
    ok "installed to $MODDIR/updates/$MODULE"
}

# Step 4: the UCM file that actually assigns left and right.
step4_ucm() {
    step "Step 4: installing the UCM config"

    overlay_install install/root/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
}

# Step 5: per-user WirePlumber config. No sudo here on purpose.
step5_wireplumber() {
    step "Step 5: installing the WirePlumber config"

    overlay_install install/home/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf

    # A previously saved pro-audio profile would be restored on next boot and
    # would bypass UCM, so drop this card's saved state if there is any.
    local state
    for state in "$HOME/.local/state/wireplumber/default-profile" \
                 "$HOME/.local/state/wireplumber/default-routes"; do
        if [ -f "$state" ] && grep -q 'platform-amd_sdw' "$state"; then
            sed -i '/platform-amd_sdw/d' "$state"
            ok "cleared saved profile state in ${state##*/}"
        fi
    done
}

# Step 6: the pacman hook, so a kernel upgrade does not silently revert the
# machine to mono.
step6_hook() {
    step "Step 6: installing the rebuild hook"

    sudo install -Dm644 -t "$SRC_INSTALL_DIR" \
        "$REPO_DIR/src/tas2783/tas2783-sdw.c" \
        "$REPO_DIR/src/tas2783/tas2783.h" \
        "$REPO_DIR/src/tas2783/Makefile"
    overlay_install install/root/usr/local/bin/tas2783-module-rebuild
    overlay_install install/root/etc/pacman.d/hooks/99-tas2783-module.hook
    info "The hook builds from $SRC_INSTALL_DIR, so this clone can be moved or deleted."
}

# Step 7: the bus reset. On some boots PipeWire's probe of the IV-sense
# capture PCM leaves the transport with the second amp rendering nothing, and
# cycling the card profile repairs it. The helper script always installs so
# --check (and the user) can repair such a boot by hand; the once-per-boot
# service is opt-in because the audible failure has proven rare and the
# profile cycle makes the audio devices flicker at every login.
step7_bus_reset() {
    step "Step 7: installing the bus reset"

    overlay_install install/root/usr/local/bin/tas2783-bus-reset

    if [ "$WITH_BUS_RESET" -eq 0 ]; then
        if systemctl --user is-enabled fix-sdw-speakers.service >/dev/null 2>&1; then
            ok "fix-sdw-speakers.service already enabled, leaving it"
        else
            info "Boot-time service not installed (optional). If the right speaker"
            info "is ever silent after a boot, run tas2783-bus-reset, and consider:"
            info "  ./install.sh --with-bus-reset"
        fi
        return 0
    fi

    # A user service, not a system one: it drives pactl, which needs the
    # session's PipeWire.
    overlay_install install/home/.config/systemd/user/fix-sdw-speakers.service
    systemctl --user daemon-reload
    systemctl --user enable fix-sdw-speakers.service >/dev/null
    ok "fix-sdw-speakers.service enabled"
}

# Step 8: load the patched module on the running system. depmod already
# prefers it, but the stock module is loaded and PipeWire holds the card open,
# so the stack comes down first. Best effort: on failure the module is still
# installed and the next boot loads it.
step8_reload() {
    step "Step 8: reloading the audio modules"

    local units=(wireplumber.service pipewire.service pipewire.socket
                 pipewire-pulse.service pipewire-pulse.socket)

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "no systemd user session, cannot stop PipeWire"
        return 1
    fi

    # Twice: the first stop trips socket activation and pipewire comes back.
    info "Stopping PipeWire..."
    systemctl --user stop "${units[@]}" >/dev/null 2>&1 || true
    systemctl --user stop "${units[@]}" >/dev/null 2>&1 || true

    info "Reloading snd_soc_tas2783_sdw..."
    local rc=0
    if sudo modprobe -r snd_acp_sdw_legacy_mach snd_soc_tas2783_sdw 2>/dev/null; then
        sudo modprobe snd_soc_tas2783_sdw && sudo modprobe snd_acp_sdw_legacy_mach || rc=1
    else
        rc=1
    fi

    # Unconditional: a failed swap must not leave PipeWire stopped.
    systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service \
        >/dev/null 2>&1 || true

    if [ "$rc" -ne 0 ]; then
        warn "modules are in use, reload failed"
        return 1
    fi

    # The card and the UCM sequence come back a second or two after the modules
    # do. The posture kcontrols exist only in the patched module.
    local card i=0
    info "Waiting for the card..."
    while [ "$i" -lt 15 ]; do
        if card=$(detect_card) &&
           amixer -c "$card" scontrols 2>/dev/null | grep -q 'DSP Posture Select'; then
            ok "patched module loaded"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    warn "card did not return with the patched module"
    return 1
}

# DEFAULT is what a bare Enter means. Returns 0 if the machine is going down.
offer_reboot() {
    local default="$1"

    # Never reboot a non-interactive run.
    [ -t 0 ] || return 1

    printf '\n'
    ask_yn "Reboot now?" "$default" || return 1

    info "Run '$REPO_DIR/install.sh --check' after rebooting to verify."
    info "Rebooting..."
    sudo systemctl reboot
}

# Step 9: verification. Also the whole of --check.
step9_verify() {
    step "Step 9: verifying"

    local failed=0 card modpath controls p1 p2

    modpath=$(modinfo -k "$KVER" -F filename snd_soc_tas2783_sdw 2>/dev/null || true)
    case "$modpath" in
        */updates/*) ok "patched module is preferred: $modpath" ;;
        "")          fail "module snd_soc_tas2783_sdw not found by modinfo"; failed=1 ;;
        *)           fail "stock module would load: $modpath"; failed=1 ;;
    esac

    if ! card=$(detect_card); then
        fail "no SoundWire sound card found (is the machine booted with the fix?)"
        return 1
    fi
    ok "sound card: $card"

    controls=$(amixer -c "$card" scontrols 2>/dev/null | grep -c 'DSP Posture Select' || true)
    if [ "$controls" -ge 2 ]; then
        ok "channel-select kcontrols present"
    else
        fail "posture kcontrols missing, the running module is the stock one"
        info "if you just installed, reboot and run: ./install.sh --check"
        failed=1
    fi

    # The UCM EnableSequence writes 1 to amp 1 and 4 to amp 2. Both reading 1
    # means the ControlExists guard did not match and the profile fell back.
    p1=$(amixer -c "$card" cget name='tas2783-1 DSP Posture Select' 2>/dev/null |
         awk -F= '/: values=/ {print $2; exit}')
    p2=$(amixer -c "$card" cget name='tas2783-2 DSP Posture Select' 2>/dev/null |
         awk -F= '/: values=/ {print $2; exit}')
    if [ "${p1:-}" = "1" ] && [ "${p2:-}" = "4" ]; then
        ok "postures applied: amp 1 = left (1), amp 2 = right (4)"
    else
        fail "postures not applied (amp 1 = ${p1:-none}, amp 2 = ${p2:-none}, expected 1 and 4)"
        failed=1
    fi

    if command -v pactl >/dev/null 2>&1; then
        # The properties block between the card name and its profile is long
        # and variable, so track the current card in awk rather than grepping
        # a fixed number of lines after the name.
        local profile
        profile=$(pactl list cards 2>/dev/null | awk '
            /Name: alsa_card/  { card = $2 }
            /Active Profile:/  { if (card ~ /amd_sdw/) { print $3; exit } }')
        if [ "$profile" = "HiFi" ]; then
            ok "card is on the HiFi profile"
        else
            fail "card profile is ${profile:-not found}, expected HiFi (UCM devices will be missing)"
            failed=1
        fi
    fi

    # Optional, so its absence is not a failure; the listening test points at
    # the flag if a boot actually shows the fault this service repairs.
    if systemctl --user is-enabled fix-sdw-speakers.service >/dev/null 2>&1; then
        ok "boot-time bus reset service enabled (optional)"
    else
        info "boot-time bus reset service not installed (optional, see README.md step 7)"
    fi

    if [ "$failed" -ne 0 ]; then
        printf '\n%sSome checks failed.%s See README.md step 9.\n' "$BOLD$RED" "$RESET"
        return 1
    fi

    ok "all automated checks passed"
    return 0
}

# Play one channel and ask which speaker it came out of. Every automated check
# above passes whether or not an amp actually makes sound, so this is the only
# test that catches a silent amp, and it needs ears.
play_channel() {
    timeout 15 speaker-test -D pipewire -c2 -t wav -s "$1" -l 1 >/dev/null 2>&1 || true
}

# ask_yn PROMPT [DEFAULT]
# DEFAULT is y or n, taken on a bare Enter and shown as the capital in the
# hint. Without it an answer is required.
ask_yn() {
    local prompt="$1" default="${2:-}" hint reply
    case "$default" in
        y) hint="[Y/n]" ;;
        n) hint="[y/N]" ;;
        *) hint="[y/n]" ;;
    esac
    while true; do
        printf '    %s %s ' "$prompt" "$hint" >&2
        read -r reply || return 1
        [ -n "$reply" ] || reply="$default"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) printf '    %sanswer y or n%s\n' "$YELLOW" "$RESET" >&2 ;;
        esac
    done
}

ask_speaker() {
    local prompt="$1" reply
    # Laid out like the bash "select" builtin, which is what a menu looks like
    # in most shell scripts: options one per line, then a "#?" prompt. Numbered
    # rather than lettered because a lowercase "l" for left is indistinguishable
    # from "1" in most terminal fonts, so people type the digit; letters are
    # still accepted. All of it goes to stderr, because stdout carries the
    # answer back through the caller's command substitution.
    printf '    %s\n' "$prompt" >&2
    printf '      %s1%s) left\n      %s2%s) right\n      %s3%s) both\n      %s4%s) neither\n' \
        "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" >&2
    while true; do
        printf '    #? ' >&2
        read -r reply || return 1
        case "$reply" in
            1|[Ll]|[Ll][Ee][Ff][Tt])       echo l; return 0 ;;
            2|[Rr]|[Rr][Ii][Gg][Hh][Tt])   echo r; return 0 ;;
            3|[Bb]|[Bb][Oo][Tt][Hh])       echo b; return 0 ;;
            4|[Nn]|[Nn][Ee][Ii][Tt][Hh][Ee][Rr]) echo n; return 0 ;;
            # Silently re-prompting looks like the script has hung.
            *) printf '    %sanswer 1, 2, 3 or 4%s\n' "$YELLOW" "$RESET" >&2 ;;
        esac
    done
}

listening_test() {
    step "Listening test"

    if [ ! -t 0 ]; then
        info "not running on a terminal, skipping the listening test"
        return 0
    fi
    command -v speaker-test >/dev/null 2>&1 || {
        warn "speaker-test not found (install alsa-utils), skipping"
        return 0
    }

    info "Turn the volume up enough to hear which side is playing."
    printf '\n'

    local left right
    info "Playing the LEFT channel..."
    play_channel 1
    left=$(ask_speaker "Which speaker played?") || return 0

    info "Playing the RIGHT channel..."
    play_channel 2
    right=$(ask_speaker "Which speaker played?") || return 0

    if [ "$left" = "l" ] && [ "$right" = "r" ]; then
        printf '\n%sStereo is working.%s\n' "$BOLD$GREEN" "$RESET"
        return 0
    fi

    # The one fault this script can fix by itself: the boot-time bus corruption
    # leaves amp 2 rendering nothing, and cycling the card profile repairs it.
    if [ "$left" = "l" ] && [ "$right" = "n" ]; then
        printf '\n'
        warn "right speaker silent: the boot-time SoundWire bus corruption"
        # The installed helper if there is one, the repo copy otherwise, so the
        # repair works even from a bare clone.
        local reset=/usr/local/bin/tas2783-bus-reset
        [ -x "$reset" ] || reset="$REPO_DIR/install/root/usr/local/bin/tas2783-bus-reset"

        info "Running the bus reset, this takes about 10 seconds..."
        "$reset" >/dev/null 2>&1 || true
        sleep 1

        info "Playing the RIGHT channel again..."
        play_channel 2
        right=$(ask_speaker "Which speaker played?") || return 0

        if [ "$right" = "r" ]; then
            printf '\n%sFixed.%s The bus reset repaired it.\n' "$BOLD$GREEN" "$RESET"
            if systemctl --user is-enabled fix-sdw-speakers.service >/dev/null 2>&1; then
                info "fix-sdw-speakers.service is enabled but did not do this at boot."
                info "Check it with: systemctl --user status fix-sdw-speakers.service"
            else
                info "This is the failure the optional boot-time service repairs"
                info "automatically. Reinstall with: ./install.sh --with-bus-reset"
            fi
            return 0
        fi

        fail "still silent after the bus reset"
        info "Collect the evidence with:"
        info "  journalctl -b -k | grep -iE 'tas2783|sdw|soundwire'"
        return 1
    fi

    printf '\n'
    case "$left$right" in
        rl) fail "channels are swapped: amp 1 and amp 2 have each other's posture"
            info "Swap the 1 and 4 values in /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf" ;;
        bb) fail "both speakers play both channels: no stereo separation"
            info "The stock module is loaded, or the UCM posture sequence did not run." ;;
        nn) fail "no sound at all from either speaker"
            info "Check the volume and that the Speaker sink is the default output." ;;
        *)  fail "unexpected result (left channel: $left, right channel: $right)" ;;
    esac
    return 1
}

# The whole of --check: automated checks, then the listening test. Also run at
# the end of an install when the reboot is declined.
run_check() {
    local rc=0

    step9_verify || rc=1
    listening_test || rc=1

    return "$rc"
}

do_uninstall() {
    step "Uninstalling"

    systemctl --user disable --now fix-sdw-speakers.service >/dev/null 2>&1 || true

    # The overlay tree is the list of what was installed, so walking it is the
    # uninstall: no second list to keep in sync.
    local f rel dest
    while IFS= read -r f; do
        rel=${f#"$REPO_DIR/"}
        dest=$(overlay_dest "$rel") || continue
        case "$rel" in
            install/root/*) sudo rm -f "$dest" ;;
            *)              rm -f "$dest" ;;
        esac
        ok "removed $dest"
    done < <(find "$REPO_DIR/install" -type f | sort)

    systemctl --user daemon-reload
    sudo rm -rf "$SRC_INSTALL_DIR"

    # Every installed kernel may have a copy, not just the running one.
    local moddir kver
    for moddir in /usr/lib/modules/*; do
        if [ -e "$moddir/updates/$MODULE" ]; then
            kver=${moddir##*/}
            sudo rm -f "$moddir/updates/$MODULE"
            sudo depmod "$kver"
            ok "removed patched module for $kver"
        fi
    done

    printf '\n%sUninstalled.%s Reboot to go back to the stock driver.\n' "$BOLD" "$RESET"
}

do_install() {
    step0_prerequisites

    printf '\n    This installs system files and needs sudo for some steps.\n'
    # A cached sudo timestamp is fine; otherwise sudo needs a terminal to
    # prompt on, which it does not have when the script is piped or run
    # from an editor or agent shell.
    if ! sudo -n true 2>/dev/null && [ ! -t 0 ]; then
        die "sudo needs a password and there is no terminal to type it into.
    Run ./install.sh from a normal terminal window instead."
    fi
    sudo -v || die "sudo is required"

    step2_firmware
    step3_module
    step4_ucm
    step5_wireplumber
    step6_hook
    step7_bus_reset

    # Reload failed: the stock module is still loaded, so a check here would
    # only report the install as broken.
    if ! step8_reload; then
        printf '\n%sInstall complete.%s A reboot is required to load the module.\n' \
            "$BOLD$GREEN" "$RESET"
        offer_reboot y && return 0
        info "Reboot when convenient, then run '$REPO_DIR/install.sh --check'."
        return 0
    fi

    # Suggested, not required: a reboot is what proves the fix persists.
    printf '\n%sInstall complete.%s A reboot is recommended.\n' "$BOLD$GREEN" "$RESET"
    offer_reboot n && return 0

    # Reboot declined: verify now.
    local rc=0
    run_check || rc=1
    if [ "$rc" -ne 0 ]; then
        printf '\n'
        info "Reboot and run '$REPO_DIR/install.sh --check' again."
    fi

    return "$rc"
}

usage() {
    cat <<'EOF'
Install the TAS2783 stereo fix for the ASUS ProArt PX13 (HN7306EAC).

This automates README.md step for step; the step numbers printed while it
runs match the step numbers in that document.

Usage:
  ./install.sh              install everything, load it, and verify it
  ./install.sh --check      verify the install, then play test tones and ask
                            which speaker you heard, repairing the bus if the
                            right one is silent
  ./install.sh --listen     the listening test on its own
  ./install.sh --uninstall  remove everything this script installs

  --with-bus-reset          also install and enable a user service that runs
                            the bus reset once per boot. Optional: on rare
                            boots the right speaker comes up silent, and this
                            repairs it automatically at the cost of the audio
                            devices flickering at every login. --check tells
                            you if your machine needs it.

Firmware. Normally there is nothing to do here, because linux-firmware ships
the blobs. When it does not, a plain ./install.sh offers to download the ASUS
driver and extract them. These two flags are for doing that part by hand:

  --firmware=PATH           use this already downloaded ASUS installer instead
                            of downloading one
  --firmware-only           do the firmware and stop, installing nothing else

Run as your normal user, not as root: it installs a per-user WirePlumber
config, and calls sudo only for the steps that need it.
EOF
}

main() {
    local rc=0 action=install
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)          action=check ;;
            --listen)         action=listen ;;
            --uninstall)      action=uninstall ;;
            --firmware)       shift
                              [ $# -gt 0 ] || die "--firmware needs a path to the ASUS installer"
                              FIRMWARE_EXE="$1" ;;
            --firmware=*)     FIRMWARE_EXE="${1#*=}" ;;
            --firmware-only)  action=firmware ;;
            --with-bus-reset) WITH_BUS_RESET=1 ;;
            -h|--help)        usage; exit 0 ;;
            *)                die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    case "$action" in
        check)     run_check || rc=1
                   exit "$rc" ;;
        listen)    listening_test; exit $? ;;
        uninstall) do_uninstall; exit 0 ;;
        firmware)  # Firmware and nothing else, for doing the rest by hand.
                   # No sudo prompt up front: if the blobs are already there,
                   # this needs no privileges at all.
                   [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"
                   step2_firmware
                   exit 0 ;;
    esac

    [ "$(id -u)" -ne 0 ] ||
        die "do not run this as root: step 5 installs a config into your home directory.
    Run it as your normal user; it calls sudo where needed."

    do_install
}

main "$@"
