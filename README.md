# ASUS ProArt PX13 audio fix

Stereo internal speakers on an ASUS ProArt PX13 (HN7306EAC, AMD Strix Halo)
under Linux. Written on CachyOS with kernel 7.2, applicable to other Arch-based
distributions.

Out of the box the two TAS2783 SmartAmp speakers do not render separate
channels: both play the same mix, or one plays and the other is silent. Fixing
that takes a patched codec module and a UCM file that selects a channel per
amp. An optional service works around a rarer boot-time fault (step 7). What
is broken and why is in [docs/analysis.md](docs/analysis.md).

## Quick install

```fish
git clone https://github.com/SaltCube/ASUS-ProArt-PX13-Audio-Fix.git
cd ASUS-ProArt-PX13-Audio-Fix
./install.sh
./install.sh --check
```

`--check` verifies the install, then plays a tone from each channel and asks
which speaker you heard, because nothing else catches a silent amp.

Everything below is that same install done by hand. Commands are
copy-pasteable fish, run from the repo root, and are idempotent.

## Fix history

- 2026-04-29 - machine set up with CachyOS 7.0.2
- 2026-05-04 - firmware blobs extracted from the ASUS Windows driver
- 2026-05-13 - repo rewritten and made public
- 2026-05-25 - SDCA register analysis, ACPI cluster tables decompiled
- 2026-07-18 - channel selection traced to the PPU21 posture register
- 2026-08-03 - patched module plus UCM config, both speakers correct
- 2026-08-04 - boot-time bus reset, install scripted

## What gets installed

The `install/` tree mirrors where its files land: everything under
`install/root/` installs to `/` and everything under `install/home/` to `~`.

| File | Purpose |
|---|---|
| `install/root/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Defines the Speaker device, sets posture 1 (left) / 4 (right) |
| `install/root/usr/local/bin/tas2783-module-rebuild` | Rebuilds the module for every installed kernel |
| `install/root/usr/local/bin/tas2783-bus-reset` | Cycles the card profile to repair the SoundWire transport |
| `install/root/etc/pacman.d/hooks/99-tas2783-module.hook` | Runs the rebuild after each kernel or headers upgrade |
| `install/home/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf` | Pins the card to the UCM-backed HiFi profile |
| `install/home/.config/systemd/user/fix-sdw-speakers.service` | Runs the bus reset once per boot; only with `--with-bus-reset` |

Two things live outside that tree because they are not plain file copies: the
patched module (built from `src/tas2783/`, installed to
`/usr/lib/modules/<kver>/updates/`) and a copy of its sources (to
`/usr/local/src/tas2783/`, where the pacman hook rebuilds from).

Firmware is not installed by these steps: `linux-firmware` ships it now (see step 2).

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
sudo install -Dm644 install/root/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf \
  /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
```

This is the file that actually assigns left and right: its EnableSequence writes
DSP posture 1 to amp 1 and posture 4 to amp 2, guarded by a `ControlExists`
condition so a stock (unpatched) module degrades to mono rather than failing.

## Step 5: Install the WirePlumber config

```fish
install -Dm644 install/home/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf \
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
sudo install -Dm755 install/root/usr/local/bin/tas2783-module-rebuild \
  /usr/local/bin/tas2783-module-rebuild
sudo install -Dm644 install/root/etc/pacman.d/hooks/99-tas2783-module.hook \
  /etc/pacman.d/hooks/99-tas2783-module.hook
```

The hook runs `/usr/local/bin/tas2783-module-rebuild`, which builds from
`/usr/local/src/tas2783` (not from this repo clone, so the clone can be deleted
or moved afterwards). If a future kernel breaks the build, the script warns and
exits 0 so the pacman transaction still succeeds; audio falls back to mono.

You can run it by hand at any time:

```fish
sudo /usr/local/bin/tas2783-module-rebuild
```

## Step 7: The bus reset (optional service)

On some boots the right speaker is silent even with everything above installed
correctly. When PipeWire starts it probes every PCM on the card, including the
SmartAmp IV-sense capture stream. That probe fails with `-22` at every boot,
and on some boots it leaves the SoundWire transport in a state where the
second amp receives nothing. The mixer gives no hint that anything is wrong:
both amps read unmuted with postures 1 and 4 applied either way. Cycling the
card profile reprograms the transport and repairs it.

The repair script is part of the normal install:

```fish
sudo install -Dm755 install/root/usr/local/bin/tas2783-bus-reset \
  /usr/local/bin/tas2783-bus-reset
```

Run `/usr/local/bin/tas2783-bus-reset` by hand any time the right speaker goes
quiet, or let `./install.sh --check` do it for you.

The audible failure is rare, so automating the repair is opt-in. A user
service can run the reset once per boot, at the cost of the audio devices
flickering shortly after every login. Install it with
`./install.sh --with-bus-reset`, or by hand:

```fish
install -Dm644 install/home/.config/systemd/user/fix-sdw-speakers.service \
  ~/.config/systemd/user/fix-sdw-speakers.service
systemctl --user daemon-reload
systemctl --user enable fix-sdw-speakers.service
```

It is a user service because it drives `pactl`, which talks to your session's
PipeWire.

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

# 5. only if you installed the optional step 7 service: it ran this boot
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
  corruption. Run `/usr/local/bin/tas2783-bus-reset`; if that fixes it and it
  keeps happening, install the optional step 7 service:
  `./install.sh --with-bus-reset`.

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

## Known issues

- **On rare boots the right speaker comes up silent** while every mixer
  reading looks correct. Run `/usr/local/bin/tas2783-bus-reset`, or install
  the optional once-per-boot service (step 7).
- **Suspend/resume kills all SoundWire audio until reboot.** A platform-level
  kernel bug, present with or without this fix and affecting the stock RT721
  codec too. After a suspend, expect no audio from any device, and expect
  `--check` to report the postures as 1 and 1 rather than 1 and 4: the codecs
  lose their state along with the bus. That is the suspend bug rather than a
  broken install, and only a reboot recovers it.
- **48 kHz / 16-bit playback only**, a limit of the AMD ACP70 SoundWire driver.
- **The patched module is a stopgap.** The real fix belongs in
  `sound/soc/sdca/sdca_functions.c` so the firmware's own init tables get
  applied ([docs/kernel-fix-plan.md](docs/kernel-fix-plan.md)).

## Appendix A: Extracting firmware from the ASUS driver

Only needed if `linux-firmware` does not ship the blobs (see step 2). In that
case `./install.sh` handles it: it offers to download the ASUS driver, verifies
it against the published SHA-256, extracts the two blobs and installs them under
both names the driver tries. Extraction needs `icoutils` and `7zip`:

```fish
sudo pacman -S --needed icoutils 7zip
```

To do only the firmware and nothing else:

```fish
./install.sh --firmware-only
```

If the download fails, ASUS is serving the file through a signed, short-lived
URL that only their page can mint. Get it with a browser from the
[support page](https://www.asus.com/laptops/for-creators/proart/proart-gopro-edition-px13-hn7306/helpdesk_download?model2Name=HN7306EAC)
(Driver & Tools, then Audio, then "TI Smart Amplifier Driver for Speakers"),
and point the script at the file:

```fish
./install.sh --firmware=/path/to/SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

An installer left in the repo root is picked up automatically. To extract the
blobs without installing anything:

```fish
./extract-firmware.sh SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

The script verifies SHA-256 checksums and prints the install commands. It writes
the blobs under both names the driver tries, `1714-1-8.bin` in `/lib/firmware/`
and in `/lib/firmware/ti/audio/tas2783/`.

## Appendix B: Swapping the module without rebooting

Instead of step 8. PipeWire holds the card open, so it must be stopped first,
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
