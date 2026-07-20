#!/bin/sh
# ============================================================================
# UNTESTED - DO NOT INSTALL until validated by a manual unbind/suspend/rebind
# test (see docs/investigation-stereo-channel-fix.md, 2026-07-19 sections).
# Version 1 of this hook caused a hard hang requiring a forced power-off.
# ============================================================================
#
# Workaround: AMD SoundWire bus dies on s2idle resume (kernel 7.2.0-rc3).
# All peripherals fail to resume (-110) and stay UNATTACHED; even a full
# driver reload cannot recover (IO_PAGE_FAULT in snd_pci_ps re-probe).
#
# Strategy: detach the SoundWire machine driver and both bus managers
# before suspend so the broken controller resume path is never exercised,
# then rebind after resume (fresh enumeration, UCM re-applies posture).
#
# Design constraints learned from the version-1 failure:
# - systemd freezes user.slice BEFORE sleep hooks run, so a hook must
#   NEVER call into a user manager (systemctl --user, runuser + DBus, ...)
#   - such calls hang against the frozen manager (~90 s DBus timeout) and
#   the desktop appears locked up.
# - WirePlumber cannot be stopped and therefore keeps /dev/snd fds open,
#   so module unload (modprobe -r) fails with EBUSY. Driver UNBIND via
#   sysfs works despite open fds (ALSA snd_card_disconnect handles it).
#
# Install (only after validation):
#   sudo install -Dm755 config/50-soundwire-sleep-reset.sh \
#     /usr/lib/systemd/system-sleep/50-soundwire-reset
# Remove:
#   sudo rm /usr/lib/systemd/system-sleep/50-soundwire-reset

MACH_DRV=/sys/bus/platform/drivers/amd_sdw
MGR_DRV=/sys/bus/platform/drivers/amd_sdw_manager

case "$1" in
pre)
	# Machine driver first (sound card goes away), then the managers.
	echo amd_sdw > "$MACH_DRV/unbind" 2>/dev/null
	echo amd_sdw_manager.0 > "$MGR_DRV/unbind" 2>/dev/null
	echo amd_sdw_manager.1 > "$MGR_DRV/unbind" 2>/dev/null
	;;
post)
	echo amd_sdw_manager.0 > "$MGR_DRV/bind" 2>/dev/null
	echo amd_sdw_manager.1 > "$MGR_DRV/bind" 2>/dev/null
	echo amd_sdw > "$MACH_DRV/bind" 2>/dev/null
	;;
esac
exit 0
