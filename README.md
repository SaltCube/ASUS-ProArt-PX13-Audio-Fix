# ASUS-ProArt-PX13-Audio-Fix

Configs, fixes, bug workarounds for audio on linux (CachyOS specifically) on the ASUS ProArt PX13 HN7306EAC

The internal speakers (TAS2783 SmartAmp, SoundWire) are silent out of the box on Linux. Three things are missing:

1. **Firmware blobs** don't ship for linux by default for ASUS subsystem ID `0x1714`
2. **no UCM exists for this card**, so the SoundWire device gets no usable audio profile
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
The ASUS Windows driver (`SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe`, 4.3 MB) is a nested installer. As far as I can tell, the firmware is buried inside a 7z archive embedded at an offset within the Inno Setup payload's `AsusBusinessIntelligenceCPPLib.dll`. 

The extraction process was:

1. `7z x smartamp.exe`
2. `wrestool -x --raw --type=EXE --name=102` on the `.rsrc` EXE 
3. `innoextract` (needs `innoextract-git` from AUR, stock 1.9 is too old for Inno 6.1.0)
4. `7z` / `binwalk` on `AsusBusinessIntelligenceCPPLib.dll` at the right offset

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

No ALSA UCM profile exists for this card. Without config, WirePlumber sets the profile to `off` and no audio sinks appear. Save as `~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf`:

```
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "alsa_card.pci-0000_c4_00.5-platform-amd_sdw" }
    ]
    actions = {
      update-props = {
        device.profile = "pro-audio"
      }
    }
  }
  {
    matches = [
      { node.name = "alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2" }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.description = "Internal Speakers (TAS2783)"
      }
    }
  }
  {
    matches = [
      { node.name = "alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-0" }
    ]
    actions = {
      update-props = {
        node.description = "Headphones (3.5mm)"
      }
    }
  }
  {
    matches = [
      { node.name = "alsa_input.pci-0000_c4_00.5-platform-amd_sdw.pro-input-1" }
    ]
    actions = {
      update-props = {
        node.description = "Headset Mic (3.5mm)"
      }
    }
  }
  {
    matches = [
      { node.name = "alsa_input.pci-0000_c4_00.5-platform-amd_sdw.pro-input-4" }
    ]
    actions = {
      update-props = {
        node.description = "Internal Microphone"
      }
    }
  }
  {
    matches = [
      { node.name = "~alsa_input.pci-0000_c4_00.5-platform-amd_sdw.pro-input-3" }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
```

**Note:** The PCI BDF `0000_c4_00.5` may differ on other units. Check `pactl list short cards | grep sdw`.

### Step 3

This is kind of a hack/bandaid. There seems to be a kernel issue where the SmartAmp's IV-sense capture stream (`SDW1-PIN4-CAPTURE-SmartAmp`) fails `Program transport params` with `-22` during PipeWire startup which corrupts the soundwire bus.

We can cycle the card profile `off` -> `pro-audio` after PipeWire starts, which seems to reset the bus. This is automated with a systemd user service at `~/.config/systemd/user/fix-sdw-speakers.service`:

```ini
[Unit]
Description=Reset SoundWire bus for TAS2783 speakers
After=wireplumber.service
Requires=wireplumber.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/sleep 3
ExecStart=/bin/sh -c 'pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw off && sleep 2 && pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw pro-audio'

[Install]
WantedBy=default.target
```

Enable with `systemctl --user daemon-reload && systemctl --user enable fix-sdw-speakers.service`.

### Device Map

| Plasma name | PipeWire node | Hardware |
|---|---|---|
| Internal Speakers | pro-output-2 | TAS2783 SmartAmp (stereo) |
| Headphones (3.5mm) | pro-output-0 | RT721 SDCA headphone jack |
| Headset Mic (3.5mm) | pro-input-1 | RT721 SDCA jack mic |
| Internal Microphone | pro-input-4 | PDM mic array |
| *(hidden)* | pro-input-3 | SmartAmp IV-sense |

### Remaining Quirks

- No auto-switch on headphone plug/unplug
- Issues after suspend - may need `pactl set-card-profile ... off; sleep 1; pactl set-card-profile ... pro-audio`
- The profile cycle workaround should become unnecessary once the kerne/firmware/drivers mature upstream