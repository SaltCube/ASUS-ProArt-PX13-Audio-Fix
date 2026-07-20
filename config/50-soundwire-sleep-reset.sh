#!/bin/sh
# Workaround: AMD SoundWire bus dies on s2idle resume (kernel 7.2.0-rc3).
# All peripherals fail to resume (-110) and stay UNATTACHED; even a full
# driver reload cannot recover (IO_PAGE_FAULT in snd_pci_ps re-probe).
# See docs/investigation-stereo-channel-fix.md, section 2026-07-19.
#
# Strategy: never exercise the broken controller resume path. Unload the
# whole ACP SoundWire stack before suspend and reload it after resume,
# which re-enumerates the bus exactly like a fresh boot (posture csets are
# re-applied by UCM when WirePlumber re-activates the HiFi profile).
#
# Install: sudo install -Dm755 config/50-soundwire-sleep-reset.sh \
#            /usr/lib/systemd/system-sleep/50-soundwire-reset
# Remove:  sudo rm /usr/lib/systemd/system-sleep/50-soundwire-reset
#
# systemd-sleep runs this with $1=pre before suspend and $1=post after
# resume. WirePlumber must release the ALSA devices or module unload fails
# with "in use"; it is stopped for the duration of the sleep. Single-user
# machine: the desktop user is hardcoded below.

DESKTOP_USER=chris
DESKTOP_UID=1000

# Order matters: machine driver first, PCI/ACP driver (owns both
# SoundWire managers) last.
SDW_MODULES="snd_acp_sdw_legacy_mach snd_ps_sdw_dma snd_ps_pdm_dma \
snd_soc_tas2783_sdw snd_soc_rt721_sdca snd_pci_ps"

user_systemctl() {
	runuser -u "$DESKTOP_USER" -- \
		env XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID" \
		systemctl --user "$@"
}

case "$1" in
pre)
	user_systemctl stop wireplumber.service 2>/dev/null
	if ! modprobe -r $SDW_MODULES; then
		logger -t soundwire-sleep-reset \
			"pre-suspend module unload failed (device busy?)"
	fi
	;;
post)
	modprobe snd_pci_ps
	modprobe snd_acp_sdw_legacy_mach
	user_systemctl start wireplumber.service 2>/dev/null
	;;
esac
exit 0
