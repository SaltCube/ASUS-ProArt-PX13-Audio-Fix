#!/usr/bin/env bash
#
# Install the TAS2783 stereo fix for the ASUS ProArt PX13 (HN7306EAC).
#
# This automates INSTALL.md step for step; the numbered steps below match the
# numbered steps in that document. Read it if you want to know why any of this
# is needed, or if you would rather run the commands by hand.
#
# Usage:
#   ./install.sh              install everything, then tell you to reboot
#   ./install.sh --check      run the verification checks only, change nothing
#   ./install.sh --uninstall  remove everything this script installs
#
# Run as your normal user, not as root: step 5 installs a per-user WirePlumber
# config, and sudo is called only for the steps that need it.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KVER=$(uname -r)
MODDIR="/usr/lib/modules/$KVER"
MODULE=snd-soc-tas2783-sdw.ko
SRC_INSTALL_DIR=/usr/local/src/tas2783

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

# Step 0: prerequisites. Everything here is a hard requirement for the build,
# so a failure stops the script before anything has been touched.
step0_prerequisites() {
    step "Step 0: checking prerequisites"

    local kmajor kminor missing=()
    kmajor=${KVER%%.*}
    kminor=${KVER#*.}; kminor=${kminor%%.*}
    if [ "$kmajor" -lt 7 ] || { [ "$kmajor" -eq 7 ] && [ "$kminor" -lt 2 ]; }; then
        die "kernel $KVER is too old, 7.2 or newer is required (see INSTALL.md step 0)"
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

# Step 2: firmware. Nothing to install on a current linux-firmware; this only
# reports, because a missing blob does not stop the rest of the install.
step2_firmware() {
    step "Step 2: checking firmware"

    if [ -e /lib/firmware/1714-1-0x8.bin.zst ] && [ -e /lib/firmware/1714-1-0xB.bin.zst ]; then
        ok "firmware shipped by linux-firmware"
    elif [ -e /lib/firmware/1714-1-8.bin ] && [ -e /lib/firmware/1714-1-B.bin ]; then
        ok "firmware installed manually"
    else
        warn "TAS2783 firmware not found"
        info "Update linux-firmware (sudo pacman -S linux-firmware), or extract the"
        info "blobs from the ASUS driver: see Appendix A in INSTALL.md."
    fi
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

    sudo install -Dm644 "$REPO_DIR/ucm2/sof-soundwire/tas2783.conf" \
        /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
    ok "installed to /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf"
}

# Step 5: per-user WirePlumber config. No sudo here on purpose.
step5_wireplumber() {
    step "Step 5: installing the WirePlumber config"

    install -Dm644 "$REPO_DIR/config/51-strix-halo-audio.conf" \
        "$HOME/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf"
    ok "installed to ~/.config/wireplumber/wireplumber.conf.d/"

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
    sudo install -Dm755 "$REPO_DIR/config/tas2783-module-rebuild" \
        /usr/local/bin/tas2783-module-rebuild
    sudo install -Dm644 "$REPO_DIR/config/99-tas2783-module.hook" \
        /etc/pacman.d/hooks/99-tas2783-module.hook
    ok "sources in $SRC_INSTALL_DIR, hook in /etc/pacman.d/hooks/"
    info "The hook builds from $SRC_INSTALL_DIR, so this clone can be moved or deleted."
}

# Step 7: the boot-time bus reset. Without this the right speaker is silent on
# every boot: PipeWire's probe of the IV-sense capture PCM fails with -22 and
# leaves the transport in a state where the second amp renders nothing.
step7_bus_reset() {
    step "Step 7: installing the boot-time bus reset"

    sudo install -Dm755 "$REPO_DIR/config/tas2783-bus-reset" /usr/local/bin/tas2783-bus-reset
    # A user service, not a system one: it drives pactl, which needs the
    # session's PipeWire.
    install -Dm644 "$REPO_DIR/config/fix-sdw-speakers.service" \
        "$HOME/.config/systemd/user/fix-sdw-speakers.service"
    systemctl --user daemon-reload
    systemctl --user enable fix-sdw-speakers.service >/dev/null
    ok "fix-sdw-speakers.service enabled"
}

# Step 9: verification. Also the whole of --check.
step8_verify() {
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

    if systemctl --user is-enabled fix-sdw-speakers.service >/dev/null 2>&1; then
        ok "boot-time bus reset service enabled"
    else
        fail "fix-sdw-speakers.service not enabled, the right speaker will be silent after a boot"
        failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        printf '\n%sSome checks failed.%s See INSTALL.md step 9.\n' "$BOLD$RED" "$RESET"
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

ask_speaker() {
    local prompt="$1" reply
    while true; do
        # The prompt goes to stderr: stdout is the answer, captured by the
        # caller's command substitution.
        printf '    %s %s[l]%seft, %s[r]%sight, %s[b]%soth, %s[n]%seither: ' \
            "$prompt" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" >&2
        read -r reply || return 1
        case "$reply" in
            [Ll]*) echo l; return 0 ;;
            [Rr]*) echo r; return 0 ;;
            [Bb]*) echo b; return 0 ;;
            [Nn]*) echo n; return 0 ;;
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
        if [ ! -x /usr/local/bin/tas2783-bus-reset ]; then
            fail "/usr/local/bin/tas2783-bus-reset is not installed (INSTALL.md step 7)"
            return 1
        fi

        info "Running the bus reset, this takes about 10 seconds..."
        /usr/local/bin/tas2783-bus-reset >/dev/null 2>&1 || true
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
                info "Enable it so this happens automatically: INSTALL.md step 7."
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

do_uninstall() {
    step "Uninstalling"

    systemctl --user disable --now fix-sdw-speakers.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/fix-sdw-speakers.service"
    systemctl --user daemon-reload

    sudo rm -f /etc/pacman.d/hooks/99-tas2783-module.hook \
               /usr/local/bin/tas2783-module-rebuild \
               /usr/local/bin/tas2783-bus-reset \
               /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
    sudo rm -rf "$SRC_INSTALL_DIR"
    rm -f "$HOME/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf"

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
    sudo -v || die "sudo is required"

    step2_firmware
    step3_module
    step4_ucm
    step5_wireplumber
    step6_hook
    step7_bus_reset

    step "Step 8: reboot"
    printf '\n%sInstall complete.%s Reboot, then verify with:\n' "$BOLD$GREEN" "$RESET"
    printf '    %s/install.sh --check\n' "$REPO_DIR"
    printf '\nTo load the module without rebooting, see Appendix B in INSTALL.md.\n'
}

usage() {
    cat <<'EOF'
Install the TAS2783 stereo fix for the ASUS ProArt PX13 (HN7306EAC).

This automates INSTALL.md step for step; the step numbers printed while it
runs match the step numbers in that document.

Usage:
  ./install.sh              install everything, then tell you to reboot
  ./install.sh --check      verify the install, then play test tones and ask
                            which speaker you heard, repairing the bus if the
                            right one is silent
  ./install.sh --listen     the listening test on its own
  ./install.sh --uninstall  remove everything this script installs

Run as your normal user, not as root: it installs a per-user WirePlumber
config, and calls sudo only for the steps that need it.
EOF
}

main() {
    local rc=0
    case "${1:-}" in
        "")            ;;
        --check)       step8_verify || rc=1
                       listening_test || rc=1
                       exit "$rc" ;;
        --listen)      listening_test; exit $? ;;
        --uninstall)   do_uninstall; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac

    [ "$(id -u)" -ne 0 ] ||
        die "do not run this as root: step 5 installs a config into your home directory.
    Run it as your normal user; it calls sudo where needed."

    do_install
}

main "$@"
