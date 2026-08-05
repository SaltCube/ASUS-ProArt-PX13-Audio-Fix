# Install guide

Minimal reproducible steps to get working stereo internal speakers on an ASUS
ProArt PX13 (HN7306EAC) running CachyOS or another Arch-based distro.

Every command below is copy-pasteable fish, run from the repo root unless noted.
Steps are idempotent: re-running them is safe.

Background on why any of this is needed is in [README.md](README.md); the
diagnosis is in [docs/investigation-stereo-channel-fix.md](docs/investigation-stereo-channel-fix.md).

## What gets installed

| Component | Installed to | Purpose |
|---|---|---|
| Patched `snd-soc-tas2783-sdw` module | `/usr/lib/modules/<kver>/updates/` | Adds the kcontrols that select each amp's channel |
| `tas2783.conf` UCM file | `/usr/share/alsa/ucm2/sof-soundwire/` | Defines the Speaker device, sets posture 1 (left) / 4 (right) |
| `51-strix-halo-audio.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Pins the card to the UCM-backed HiFi profile |
| Module sources | `/usr/local/src/tas2783/` | Source of truth for automatic rebuilds |
| `tas2783-module-rebuild` | `/usr/local/bin/` | Rebuilds the module for every installed kernel |
| `99-tas2783-module.hook` | `/etc/pacman.d/hooks/` | Runs the rebuild after each kernel or headers upgrade |
| `tas2783-bus-reset` | `/usr/local/bin/` | Cycles the card profile once per boot to repair the SoundWire transport |
| `fix-sdw-speakers.service` | `~/.config/systemd/user/` | Runs that reset after WirePlumber starts |

Firmware is not installed by these steps: `linux-firmware` ships it now (see step 3).

## Step 0: Prerequisites

Kernel **7.2 or newer** is required. Earlier kernels either lack the TAS2783
SoundWire driver entirely (6.x) or lack the `spk:tas2783` CardComponents string
that makes the UCM profile load (7.0, 7.1).

```fish
uname -r                       # must be 7.2 or newer
pacman -Q alsa-ucm-conf        # must be 1.2.16 or newer
```

Install the build toolchain and the headers **for the kernel you are running**.
CachyOS kernels are clang-built, so clang, llvm and lld are required rather than
gcc. The headers package name must match your kernel package
(`linux-cachyos-headers`, `linux-cachyos-rc-headers`, `linux-cachyos-lts-headers`, ...):

```fish
sudo pacman -S --needed base-devel clang llvm lld linux-cachyos-rc-headers
```

Confirm the headers match the running kernel; this path must exist:

```fish
test -e /usr/lib/modules/$(uname -r)/build/Makefile; and echo "headers OK"
```

Note: the module is unsigned and out of tree, so Secure Boot must be off (or the
module signed yourself). Loading it taints the kernel, which is expected.

## Step 1: Clone the repo

```fish
git clone https://github.com/SaltCube/ASUS-ProArt-PX13-Audio-Fix.git
cd ASUS-ProArt-PX13-Audio-Fix
```

## Step 2: Check the firmware is present

On `linux-firmware` 20260622 or newer the blobs are already installed and the
kernel loads them automatically. Check:

```fish
ls /lib/firmware/1714-1-0x8.bin.zst /lib/firmware/1714-1-0xB.bin.zst
```

If both exist, this step is done. If not, update linux-firmware:

```fish
sudo pacman -S linux-firmware
```

If your distro still does not ship them, extract them from the ASUS Windows
driver instead: see
[Appendix A](#appendix-a-extracting-firmware-from-the-asus-driver).

## Step 3: Build and install the patched module

```fish
make -C /usr/lib/modules/$(uname -r)/build M=$PWD/src/tas2783 LLVM=1 modules
sudo install -Dm644 src/tas2783/snd-soc-tas2783-sdw.ko \
  /usr/lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko
sudo depmod $(uname -r)
```

`depmod` prefers `updates/` over the in-tree module, so the patched one wins from
the next boot on. The build takes a few seconds and should produce no warnings.

## Step 4: Install the UCM config

```fish
sudo install -Dm644 ucm2/sof-soundwire/tas2783.conf \
  /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
```

This is the file that actually assigns left and right: its EnableSequence writes
DSP posture 1 to amp 1 and posture 4 to amp 2, guarded by a `ControlExists`
condition so a stock (unpatched) module degrades to mono rather than failing.

## Step 5: Install the WirePlumber config

```fish
install -Dm644 config/51-strix-halo-audio.conf \
  ~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf
```

No sudo: this is a per-user config. It pins the card to the HiFi profile and
hides the Pro Audio profile, which bypasses UCM and exposes the broken IV-sense
capture PCM.

If you have previously used this machine's audio, also clear WirePlumber's saved
profile state so it does not restore `pro-audio` on the next boot:

```fish
sed -i '/platform-amd_sdw/d' ~/.local/state/wireplumber/default-profile
sed -i '/platform-amd_sdw/d' ~/.local/state/wireplumber/default-routes
```

## Step 6: Install the rebuild hook

A kernel package upgrade wipes `updates/`, silently reverting the machine to
mono. This hook rebuilds and reinstalls the module after every kernel or headers
upgrade, for every installed kernel that has headers available.

```fish
sudo install -Dm644 -t /usr/local/src/tas2783 \
  src/tas2783/tas2783-sdw.c src/tas2783/tas2783.h src/tas2783/Makefile
sudo install -Dm755 config/tas2783-module-rebuild /usr/local/bin/tas2783-module-rebuild
sudo install -Dm644 config/99-tas2783-module.hook /etc/pacman.d/hooks/99-tas2783-module.hook
```

The hook runs `/usr/local/bin/tas2783-module-rebuild`, which builds from
`/usr/local/src/tas2783` (not from this repo clone, so the clone can be deleted
or moved afterwards). If a future kernel breaks the build, the script warns and
exits 0 so the pacman transaction still succeeds; audio falls back to mono.

You can run it by hand at any time:

```fish
sudo /usr/local/bin/tas2783-module-rebuild
```

## Step 7: Install the boot-time bus reset

Without this step the right speaker is silent on every boot, even with
everything above installed correctly.

When PipeWire starts it probes every PCM on the card, including the SmartAmp
IV-sense capture stream. That probe fails with `-22` and leaves the SoundWire
transport in a state where the second amp receives nothing. Cycling the card
profile reprograms it. The mixer gives no hint that anything is wrong: both amps
read unmuted with postures 1 and 4 applied either way.

```fish
sudo install -Dm755 config/tas2783-bus-reset /usr/local/bin/tas2783-bus-reset
install -Dm644 config/fix-sdw-speakers.service \
  ~/.config/systemd/user/fix-sdw-speakers.service
systemctl --user daemon-reload
systemctl --user enable fix-sdw-speakers.service
```

The service is a user service because it drives `pactl`, which talks to your
session's PipeWire. Run `/usr/local/bin/tas2783-bus-reset` by hand any time the
right speaker goes quiet.

## Step 8: Reboot

```fish
reboot
```

A reboot is the simple, reliable way to load the patched module and re-run the
UCM sequence. To avoid one, see
[Appendix B](#appendix-b-swapping-the-module-without-rebooting).

## Step 9: Verify

`./install.sh --check` runs everything below, then plays a tone from each
channel and asks which speaker you heard. If the right one is silent it runs the
bus reset and retests, so it both finds and fixes the common failure. The manual
equivalent:

```fish
# 1. the patched module is the one loaded (path must contain updates/)
modinfo -F filename snd_soc_tas2783_sdw

# 2. the channel-select kcontrols exist
amixer -c amdsoundwire scontrols | grep Posture

# 3. UCM applied the postures: amp 1 must read 1, amp 2 must read 4
amixer -c amdsoundwire cget name='tas2783-1 DSP Posture Select'
amixer -c amdsoundwire cget name='tas2783-2 DSP Posture Select'

# 4. the amd_sdw card is on the HiFi profile, not pro-audio or off
pactl list cards | grep -E 'Name: alsa_card|Active Profile'

# 5. the bus reset ran this boot
systemctl --user status fix-sdw-speakers.service

# 6. listen: "Front Left" from the left speaker only, then "Front Right" from
#    the right speaker only. This is the only check that catches a silent amp.
speaker-test -D pipewire -c2 -t wav
```

The listening test matters because checks 1 to 4 pass whether or not the right
speaker actually makes sound.

- **Both amps read `values=1`**: the UCM condition did not match and you are
  running the stock module. Re-check steps 3 and 4, then reboot.
- **Postures read 1 and 4 but the right speaker is silent**: the boot-time bus
  corruption. Run `/usr/local/bin/tas2783-bus-reset`; if that fixes it, step 7
  is missing or its service did not run.

## Uninstall

```fish
systemctl --user disable --now fix-sdw-speakers.service
rm -f ~/.config/systemd/user/fix-sdw-speakers.service
systemctl --user daemon-reload
sudo rm -f /etc/pacman.d/hooks/99-tas2783-module.hook \
           /usr/local/bin/tas2783-module-rebuild \
           /usr/local/bin/tas2783-bus-reset \
           /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf \
           /usr/lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko
sudo rm -rf /usr/local/src/tas2783
rm -f ~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf
sudo depmod $(uname -r)
reboot
```

That returns the machine to the stock driver, which means silent-or-mono
speakers depending on your alsa-ucm-conf version.

## Known issues after install

- **Suspend/resume kills all SoundWire audio until reboot.** This is a
  platform-level kernel bug present with or without this fix, affecting the
  stock RT721 codec too. Do not install `config/50-soundwire-sleep-reset.sh`;
  it is unvalidated and an earlier version hard-hung the machine.
- **48 kHz / 16-bit playback only**, a limit of the AMD ACP70 SoundWire driver.
- **The patched module is a stopgap.** The real fix belongs in
  `sound/soc/sdca/sdca_functions.c` so the firmware's own init tables get
  applied (Phase 2 in [docs/step3-fix-plan.md](docs/step3-fix-plan.md)).

## Appendix A: Extracting firmware from the ASUS driver

Only needed if `linux-firmware` does not ship the blobs (see step 2).

Download `SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe` from the
[ASUS support page](https://www.asus.com/laptops/for-creators/proart/proart-px13-hn7306/helpdesk_download?model2Name=HN7306EA)
(pick model HN7306EAC, then "TI Smart Amplifier Driver for Speakers"), then:

```fish
sudo pacman -S --needed icoutils 7zip
./install.sh --firmware-exe SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

That extracts the blobs and installs them under both names the driver tries,
then continues with the rest of the install. It only does so when the blobs are
actually missing, so the flag is harmless to pass on a machine that already has
them. To extract without installing anything:

```fish
./extract-firmware.sh SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

The script verifies SHA-256 checksums and prints the install commands. It writes
the blobs under both names the driver tries, `1714-1-8.bin` in `/lib/firmware/`
and in `/lib/firmware/ti/audio/tas2783/`.

## Appendix B: Swapping the module without rebooting

Instead of step 7. PipeWire holds the card open, so it must be stopped first,
twice, because socket activation restarts it:

```fish
systemctl --user stop wireplumber.service pipewire.service pipewire.socket \
  pipewire-pulse.service pipewire-pulse.socket
systemctl --user stop wireplumber.service pipewire.service pipewire.socket \
  pipewire-pulse.service pipewire-pulse.socket
sudo modprobe -r snd_acp_sdw_legacy_mach snd_soc_tas2783_sdw
sudo modprobe snd_soc_tas2783_sdw
sudo modprobe snd_acp_sdw_legacy_mach
systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service
```

Then run the step 8 verification. If the postures do not apply, reboot instead.
