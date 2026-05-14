# ASUS-ProArt-PX13-Audio-Fix

Configs, fixes, bug workarounds for audio on linux (CachyOS specifically) on the ASUS ProArt PX13 HN7306EAC

The internal speakers (TAS2783 SmartAmp, SoundWire) are silent out of the box on Linux. Three things are missing:

1. **Firmware blobs** don't ship for linux by default for ASUS subsystem ID `0x1714`
2. **UCM config** The system `amd-soundwire` UCM config recognizes the RT721 headset codec but fails to create Speaker or Mic devices because the kernel's CardComponents string (`cfg-amp:2 hs:rt721`) doesn't contain `spk:` and `mic:` entries
3. **SoundWire bus corruption workaround** - a kernel issue where the SmartAmp IV-sense capture stream fails to configure (`-22 EINVAL`), corrupting the entire SoundWire bus

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

### Step 2

The system `amd-soundwire` UCM config (from `alsa-ucm-conf`) only creates Headphone and Headset devices for this card. It fails to create Speaker and Mic devices because the AMD ACP70 kernel driver does not report `spk:` or `mic:` in the card's `CardComponents` string.

This repo provides a replacement UCM config ([`ucm2/conf.d/amd-soundwire/`](ucm2/conf.d/amd-soundwire/)) that hardcodes all four devices:

| UCM Device | ALSA PCM | Hardware | Jack Detection |
|---|---|---|---|
| Speaker | `hw:amdsoundwire,2` | TAS2783 SmartAmp ([no stereo yet](#Stereo-channel-mapping-issue)) | always on |
| Headphones | `hw:amdsoundwire,0` | RT721 SDCA headphone jack | `Headphone Jack` |
| Mic | `hw:amdsoundwire,4` | ACP PDM dual-mic array | always on |
| Headset | `hw:amdsoundwire,1` | RT721 SDCA headset mic | `Headset Mic Jack` |

Back up the original first if you want to be safe:

```fish
sudo mv /usr/share/alsa/ucm2/conf.d/amd-soundwire/amd-soundwire.conf /usr/share/alsa/ucm2/conf.d/amd-soundwire/amd-soundwire.conf.bak
```

Install:

```fish
sudo install -m 644 ucm2/conf.d/amd-soundwire/amd-soundwire.conf /usr/share/alsa/ucm2/conf.d/amd-soundwire/
sudo install -m 644 ucm2/conf.d/amd-soundwire/HiFi.conf /usr/share/alsa/ucm2/conf.d/amd-soundwire/
```

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

### Step 4

SmartAmp's IV-sense capture stream (`SDW1-PIN4-CAPTURE-SmartAmp`) fails `Program transport params` during initial card activation. This corrupts the entire SoundWire bus and blocks all audio. The UCM config avoids defining this PCM, but the bus corruption still happens at the SoundWire transport layer during initial profile activation.

To fix,  ycle the card profile `off` -> `HiFi (Mic, Speaker)` after PipeWire starts, which resets the bus.

Copy [`config/fix-sdw-speakers.service`](config/fix-sdw-speakers.service) and enable it:

```fish
mkdir -p ~/.config/systemd/user
cp config/fix-sdw-speakers.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable fix-sdw-speakers.service
```

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

- No auto-switch on headphone plug/unplug
- Issues after suspend - may need `pactl set-card-profile ... off; sleep 1; pactl set-card-profile ... pro-audio`
- The profile cycle workaround should become unnecessary once the kerne/firmware/drivers mature upstream
- 16-bit / 48kHz output only - the TAS2783 supports up to 32-bit/96kHz per spec, but the AMD ACP70 SoundWire ALSA driver (`sound/soc/amd`) is stuck at 48kHz for SmartAmp playback.

### Bugs?
This may be intended behavior driver side they indicate the amps are supposed to only select and play their respective audio stream.
#### Stereo channel mapping issue

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
