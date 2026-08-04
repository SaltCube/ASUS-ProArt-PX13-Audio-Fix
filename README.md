# ASUS-ProArt-PX13-Audio-Fix

Configs, fixes, bug workarounds for audio on linux (CachyOS specifically) on the ASUS ProArt PX13 HN7306EAC

The internal speakers (TAS2783 SmartAmp, SoundWire) are silent out of the box on Linux. Three things are missing:

1. **Firmware blobs** don't ship for linux by default for ASUS subsystem ID `0x1714`
2. **UCM config** The system `amd-soundwire` UCM config recognizes the RT721 headset codec but fails to create Speaker or Mic devices because the kernel's CardComponents string (`cfg-amp:2 hs:rt721`) doesn't contain `spk:` and `mic:` entries
3. **SoundWire bus corruption workaround** - a kernel issue where the SmartAmp IV-sense capture stream fails to configure (`-22 EINVAL`), corrupting the entire SoundWire bus

## SOLVED: stereo channel separation (2026-08-03)

Both speakers used to play an identical L+R mix instead of separate channels. Root cause:
the ASUS ACPI firmware omits a required SDCA DisCo constant, the kernel's SDCA function
parse fails for both amps, and the per-amp init tables (which set DSP posture 1 vs 4, the
left/right differentiation) are never applied. Full analysis in
`docs/investigation-stereo-channel-fix.md`, fix plan in `docs/step3-fix-plan.md`.

The working solution stack (kernel 7.2.0-rc5, alsa-ucm-conf >= 1.2.16):

1. **Patched codec module** (`src/tas2783/`, patch in `patches/`): the stock
   `snd-soc-tas2783-sdw` driver plus two kcontrols (`DSP Posture Select`,
   `UDMPU Cluster Select`) that expose the per-amp channel-select register.
   Built out-of-tree and installed to `/usr/lib/modules/$(uname -r)/updates/`,
   which depmod prefers over the stock module.
2. **UCM config** (`ucm2/sof-soundwire/tas2783.conf`, installed to
   `/usr/share/alsa/ucm2/sof-soundwire/`): defines the Speaker device and writes
   posture 1 (left) / 4 (right) in the EnableSequence, guarded by
   `ControlExists` so it degrades gracefully on a stock kernel.
3. **Pacman hook** (`config/99-tas2783-module.hook` +
   `config/tas2783-module-rebuild`): rebuilds and reinstalls the patched module
   after every kernel/headers upgrade, since anything in `updates/` dies with a
   kernel package update. Sources are copied to `/usr/local/src/tas2783`.
4. **WirePlumber config** (`config/51-strix-halo-audio.conf`): keeps the card on
   the UCM-backed HiFi profile and hides the Pro Audio profile.

Install (from repo root, after the firmware steps below):

```fish
# build the module
cd src/tas2783
make -C /usr/lib/modules/$(uname -r)/build M=$PWD LLVM=1 modules
sudo install -Dm644 snd-soc-tas2783-sdw.ko /usr/lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko
sudo depmod
cd ../..
# UCM + WirePlumber
sudo install -Dm644 ucm2/sof-soundwire/tas2783.conf /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
install -Dm644 config/51-strix-halo-audio.conf ~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf
# survive kernel updates
sudo install -Dm644 -t /usr/local/src/tas2783 src/tas2783/tas2783-sdw.c src/tas2783/tas2783.h src/tas2783/Makefile
sudo install -Dm755 config/tas2783-module-rebuild /usr/local/bin/tas2783-module-rebuild
sudo install -Dm644 config/99-tas2783-module.hook /etc/pacman.d/hooks/99-tas2783-module.hook
# reboot, then verify: speaker-test -D pipewire -c2 -t wav
```

Known remaining issue: s2idle suspend/resume kills the whole SoundWire bus (all
peripherals, including the stock RT721) at the platform level - pre-existing
kernel bug, not caused by this fix; only a reboot recovers. See the
[suspend section](#soundwire-bus-dies-after-suspendresume) and the investigation
doc for the post-mortem of an attempted sleep-hook workaround
(`config/50-soundwire-sleep-reset.sh`, unvalidated - do not install).

## ASUS Driver Downloads

The firmware extraction documented here uses the SmartAMP driver from the ASUS support page:

https://www.asus.com/laptops/for-creators/proart/proart-px13-hn7306/helpdesk_download?model2Name=HN7306EA

In my case I clicked *HN7306EAC* in the drop down under Driver & Tools.

Look for *TI Smart Amplifier Driver for Speakers* under that. The file used in this repo was `SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe` (SHA-256: `8728835795be467d39c721b6245e6e038d44fcbf0d0e49718ef45cb44eb8a3ce`).

### Prerequisites

- **Kernel 7.0+** - an initial driver landed mainline 2026-03-16. On 6.x kernels, only a capture-only `acp-pdm-mach` device appears, not the SoundWire card.
- **CachyOS** ships `linux-cachyos` 7.0.x from the `cachyos-znver4` repo, which works.

### Step 1

The firmware must be extracted from the ASUS Windows driver, download link above.

The ASUS Windows driver (`SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe`, 4.3 MB) is a nested installer.

**Automated extraction, script courtesy of Claude Opus 4.6** - requires `wrestool` (icoutils) and `7z` (p7zip):

```fish
chmod +x extract-firmware.sh && \
./extract-firmware.sh SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
```

The script extracts the firmware, verifies SHA-256 checksums, and prints install commands. Under the hood, the installer is a nested PE with a 7z archive embedded as a resource:

1. `wrestool -x --raw --type=ZIP --name=103` on the installer: extracts a 7z archive containing a `Firmwares/` directory with calibration blobs for every supported ASUS model
2. `7z x` on that archive: extracts `1714-1-0x8.bin` and `1714-1-0xB.bin` (the blobs for subsystem ID `0x1714` / HN7306EAC)


The two files needed:
| Source filename | Size | SHA-256 |
|---|---|---|
| `1714-1-0x8.bin` | 40 KB | `9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca` |
| `1714-1-0xB.bin` | 40 KB | `a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1` |

Install to **both** paths the kernel probes:

```fish
sudo install -m 644 1714-1-0x8.bin /lib/firmware/1714-1-8.bin
sudo install -m 644 1714-1-0xB.bin /lib/firmware/1714-1-B.bin
sudo install -d -m 755 /lib/firmware/ti/audio/tas2783
sudo install -m 644 1714-1-0x8.bin /lib/firmware/ti/audio/tas2783/1714-1-8.bin
sudo install -m 644 1714-1-0xB.bin /lib/firmware/ti/audio/tas2783/1714-1-B.bin
```

### Step 2 (OBSOLETE since alsa-ucm-conf 1.2.16 + kernel 7.2)

> **This step is no longer needed.** alsa-ucm-conf >= 1.2.16 routes the
> `amd-soundwire` card through the shared `sof-soundwire` UCM tree, and kernel
> 7.2 reports `spk:tas2783` in CardComponents. What that combination is missing
> is a per-speaker-codec file no alsa-ucm-conf release ships:
> `sof-soundwire/tas2783.conf`. This repo provides it (see the stereo section
> above). The old replacement config below was removed from the repo (it lives
> in git history); if you installed it, remove the leftover
> `/usr/share/alsa/ucm2/conf.d/amd-soundwire/HiFi.conf` - the packaged
> `amd-soundwire.conf` symlink now points into `sof-soundwire/` and the stray
> file is dead config.

The system `amd-soundwire` UCM config (from `alsa-ucm-conf`) only created Headphone and Headset devices for this card, because the AMD ACP70 kernel driver did not report `spk:` or `mic:` in the card's `CardComponents` string. The replacement config hardcoded all four devices:

| UCM Device | ALSA PCM | Hardware | Jack Detection |
|---|---|---|---|
| Speaker | `hw:amdsoundwire,2` | TAS2783 SmartAmp (stereo fixed, see above) | always on |
| Headphones | `hw:amdsoundwire,0` | RT721 SDCA headphone jack | `Headphone Jack` |
| Mic | `hw:amdsoundwire,4` | ACP PDM dual-mic array | always on |
| Headset | `hw:amdsoundwire,1` | RT721 SDCA headset mic | `Headset Mic Jack` |

**Proper UCM fix should:**
- Load HiFi profile with named devices instead of generic "Pro" nodes
- Jack detection - headphone/headset nodes are hidden when unplugged
- Auto-switch - WirePlumber automatically switches output when headphones are plugged in

If you need to test the UCM config manually, use `alsaucm -c amd-soundwire` or verify via `pactl list cards`.

### Step 3

A minimal WirePlumber rule prevents the SoundWire bus from suspending (which causes desync and audio dropouts):

```fish
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
cp config/51-strix-halo-audio.conf ~/.config/wireplumber/wireplumber.conf.d/
```

**Note**: It seems the `pro-audio` profile still appears as a selectable option in PipeWire/Plasma even with the UCM config installed. Selecting this likely bypasses the UCM device definitions and reverts to raw ALSA nodes.

Also clear WirePlumber's saved profile state so it doesn't restore `pro-audio` on next boot:

```fish
sed -i '/platform-amd_sdw/d' ~/.local/state/wireplumber/default-profile
sed -i '/platform-amd_sdw/d' ~/.local/state/wireplumber/default-routes
```

The PCI BDF `0000_c4_00.5` may differ on other units check with `pactl list short cards | grep sdw`.

### Step 4 (OBSOLETE)

> **This step is no longer needed** on kernel 7.2 with the current UCM config:
> the boot-time bus corruption no longer occurs (the UCM file simply never
> defines the IV-sense PCM). The profile-cycle service was removed from the
> repo; if you enabled it, disable it:
> `systemctl --user disable --now fix-sdw-speakers.service` and delete it from
> `~/.config/systemd/user/`.

SmartAmp's IV-sense capture stream (`SDW1-PIN4-CAPTURE-SmartAmp`) used to fail `Program transport params` during initial card activation, corrupting the entire SoundWire bus and blocking all audio until the card profile was cycled `off` -> `HiFi`.

### Device Map

| Plasma name | PipeWire node | Hardware |
|---|---|---|
| Internal Speakers | pro-output-2 | TAS2783 SmartAmp (stereo) |
| Audio Jack (3.5mm) | pro-output-0 | RT721 SDCA headphone jack |
| Audio Jack (3.5mm) | pro-input-1 | RT721 SDCA jack mic |
| Internal Microphone | pro-input-4 | PDM mic array |
| *(hidden)* | pro-input-3 | SmartAmp IV-sense |

### Silence Beep on Shutdown

The laptop seems to have a piezo buzzer that beeps during shutdown, a ~1800Hz tone lasting several seconds until power fully cuts. This is the `pcspkr` kernel module, not the TAS2783 speakers. Blacklist it:

```fish
sudo sh -c 'echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf'
sudo rmmod pcspkr  # kill it immediately without rebooting
```

### Remaining Quirks

- Suspend/resume kills all SoundWire audio until reboot (platform kernel bug,
  see suspend section below)
- 16-bit / 48kHz output only - the TAS2783 supports up to 32-bit/96kHz per spec, but the AMD ACP70 SoundWire ALSA driver (`sound/soc/amd`) is stuck at 48kHz for SmartAmp playback.
- The patched module is a stopgap: the proper fix is a kernel-side fallback in
  `sound/soc/sdca/sdca_functions.c` so the firmware's own init tables get
  applied (Phase 2 in `docs/step3-fix-plan.md`), plus upstream reports
  (kernel regression, alsa-ucm-conf `tas2783.conf`, ASUS firmware bug).

### Bugs?
This may be intended behavior driver side they indicate the amps are supposed to only select and play their respective audio stream.
#### Stereo channel mapping issue

> **RESOLVED (2026-07-18).** The analysis below was the starting point; the
> actual channel selector turned out to be the PPU21 `PostureNumber` SDCA
> register (posture 1 = left, 4 = right), not IT21. The per-amp postures are
> in the firmware's ACPI init tables, which the kernel never applies because
> the SDCA function parse fails (missing DisCo constant in ASUS firmware).
> Full story in `docs/investigation-stereo-channel-fix.md`; solution in the
> stereo section at the top.

Both physical speakers produce audio, but there is no stereo separation. Testing with `speaker-test -c 2 -t sine -f 440 -s <channel>` shows that both speakers respond to the front-left signal; the front-right signal may be silent or indistinguishable. PipeWire routes FL and FR as distinct streams to the ALSA boundary (`output_FL → playback_FL`, `output_FR → playback_FR` confirmed via `wpctl status`), so the problem is below ALSA.

The kernel exposes no channel-routing controls for the TAS2783 path. The full mixer surface is:

- `Left Spk Switch` / `Right Spk Switch` - chip 1 mute gates
- `Left Spk2 Switch` / `Right Spk2 Switch` - chip 2 mute gates
- `tas2783-1 Amp Volume` / `tas2783-1 Speaker Volume` - chip 1 gain
- `tas2783-2 Amp Volume` / `tas2783-2 Speaker Volume` - chip 2 gain

No source-select, slot-select, channel-select, or routing enums exist. With any of the four switches off, at least one physical speaker goes silent, so UCM enables all four, but this does not fix stereo.

The two TAS2783 chips (SoundWire unique IDs `0x8` and `0xb`) share a single playback DAI (`multicodec-2`).

Possible root causes:

1. `asoc_sdw_hw_params()` in `soc_sdw_utils.c` uses `step = 0` (identical data to both amps) without per-codec channel differentiation, but this seems like intended behavior
2. SDCA per-chip channel-select register (IT21 input selector) is never written by the Linux TAS2783 driver - the Windows driver likely does this during init

DAPM graph (dumped from `/sys/kernel/debug/asoc/amd-soundwire/`) shows the card-level routing is correct, `Left Spk` receives from `tas2783-1 SPK` (chip 0x8), `Right Spk` receives from `tas2783-2 SPK` (chip 0xb). Each codec has its own signal path: `Playback > ASI > FU21/FU23 > SPK > Left/Right Spk`. PipeWire, ALSA, and DAPM are all wired correctly for stereo.

Both chips are configured identically at the SoundWire transport layer. Reading the DP1 Bank1 registers from `/sys/kernel/debug/soundwire/master-0-1/`:

| Register (DP1 Bank1) | Chip 1 (0x8) | Chip 2 (0xb) | SoundWire field |
|---|---|---|---|
| 0x130 | 0x3 | 0x3 | `ChannelEn`  |
| 0x132 | 0xf3 | 0xf3 | `SampleCtrl1` |
| 0x134 | 0x41 | 0x41 | `OffsetCtrl1` |
| 0x136 | 0x19 | 0x19 | `HCtrl` |

`ChannelEn = 0x3` (and step = 0) means both chips receive both L and R channels. Each amp's internal DSP is then responsible for selecting only its assigned channel (left or right) and discarding the other. AFIK this is the normal approach for multi-amp SoundWire setups.

```c
if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
    ch_mask = GENMASK(ch - 1, 0);  // ch=2 -> 0x3 (both channels)
    step = 0;                      // all codecs get both channels
}

for_each_link_ch_maps(rtd->dai_link, i, ch_maps)
    ch_maps->ch_mask = ch_mask << (i * step);
```

The TAS2783 is an SDCA device with an Input Terminal entity (IT21) that controls which channel each chip amplifies. The Linux driver (`sound/soc/codecs/tas2783-sdw.c`) has SDCA IT21 registers in its regmap but initializes them all to `0x0`:

```c
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x04, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x08, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x10, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x11, 0), 0x0},
```

The driver defines `TAS2783_DEVICE_CHANNEL_LEFT` but does not appear to write per-chip channel selection to IT21. The per-chip firmware blobs (`1714-1-0x8.bin` vs `1714-1-0xB.bin`) contain per-chip calibration data matched by `unique_id` but not channel routing. The firmware works correctly on Windows, so the blobs themselves are fine. The Windows driver likely writes the IT21 channel selection register during init, and it seems the Linux driver doesn't yet.

Other SoundWire amp drivers (RT1318, CS35L56) handle this by implementing `set_tdm_slot` in the codec driver. The TAS2783 driver does not implement `set_tdm_slot`.

#### IV-sense capture stream corruption

`SDW1-PIN4-CAPTURE-SmartAmp` fails `snd_soc_link_prepare()` with `-EINVAL` on every boot. This corrupts the SoundWire bus state, blocking all audio until the card profile is cycled. The UCM config intentionally omits PCM 3 (IV-sense) to avoid triggering this from the profile level, but the corruption occurs at the SoundWire transport layer during initial card activation regardless.

This is worked around by the profile-cycle systemd service (Step 4). The workaround becomes unnecessary once this is fixed upstream.

#### SoundWire bus dies after suspend/resume

> **Update 2026-07-19 (kernel 7.2.0-rc3/rc5):** this got worse - on s2idle
> resume ALL SoundWire peripherals (both TAS2783 and the stock RT721) fail
> resume with `-110 ETIMEDOUT` and stay UNATTACHED. Not caused by this repo's
> changes; it is a platform-level kernel bug, still present in rc5. Driver
> reload cannot recover (IO_PAGE_FAULT in `snd_pci_ps` re-probe); only a
> reboot does. An attempted systemd sleep-hook workaround caused a hard hang
> (post-mortem in the investigation doc); the rewritten hook
> `config/50-soundwire-sleep-reset.sh` is UNVALIDATED - do not install it.

After system suspend (sleep/lid close), the SoundWire bus fails to re-initialize.
The kernel logs show:

```
sdw_deprepare_stream: inconsistent state state 1
rt721-sdca: SDW_SCP_BUSCLOCK_SCALE register write failed
soundwire sdw-master-0-1: Program params failed: -61
SDW1-PIN1-PLAYBACK-SmartAmp: ASoC error (-61): at snd_soc_link_prepare()
```

Error `-61` is `ENODATA`: the bus master cannot communicate with any SoundWire device (RT721 or TAS2783). The stream state machine is stuck in an inconsistent state and the bus clock cannot be reprogrammed. This is different from the boot-time IV-sense issue (which is `-22 EINVAL` on `PIN4-CAPTURE` and recoverable with a profile cycle).

No userspace workaround exists:
- Profile cycling (`pactl set-card-profile ... off / on`) does not help
- Restarting PipeWire/WirePlumber does not help (and causes a 30s hang + loss of all audio devices in GUI)
- Module unload fails (`snd_soc_tas2783_sdw` is in use due to stuck stream references)

The `session.suspend-timeout-seconds = 0` WirePlumber rule (Step 3) prevents PipeWire from voluntarily suspending the speaker stream, but cannot prevent system-wide suspend. This may implicate the AMD ACP70 SoundWire bus master's suspend/resume path.

#### CardComponents Missing

The AMD ACP70 SoundWire machine driver (`snd_acp_sdw_legacy_mach`) reports `CardComponents` as `cfg-amp:2 hs:rt721` - missing `spk:` (for TAS2783 speakers) and `mic:` (for the ACP DMIC).
This prevents the upstream `amd-soundwire` UCM config from auto-creating Speaker and Mic devices.
This is worked around by the custom UCM config (Step 2) which hardcodes all device definitions.
