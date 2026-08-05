# Analysis

Background for the fix in [README.md](../README.md): what is wrong with audio on
this laptop and what was measured. Measurements and conclusions are kept in
separate sections so the evidence stands on its own.

Full working notes for the channel investigation are in
[investigation-log.md](investigation-log.md), and
the remaining kernel-side plan is in [kernel-fix-plan.md](kernel-fix-plan.md).

## Hardware

Two TI TAS2783 SmartAmp speaker amplifiers on SoundWire link 1, unique IDs `0x8`
and `0xb`, sharing one stereo playback DAI. A Realtek RT721 SDCA codec handles
the headphone jack and headset mic. The AMD ACP70 provides the SoundWire master
and a PDM mic array.

The card exposes five PCMs:

```
pcm0p  RT721 headphone playback
pcm1c  RT721 headset mic capture
pcm2p  TAS2783 speaker playback
pcm3c  TAS2783 IV-sense capture
pcm4c  PDM mic array capture
```

Each amp loads a calibration blob matched by unique ID (`1714-1-0x8.bin`,
`1714-1-0xB.bin`), where `1714` is the ASUS subsystem ID. Since
`linux-firmware` 20260622 these ship in `linux-firmware-other`, byte for byte
identical to the ones inside the ASUS Windows driver.

## Channel selection

### Observations

Both amps are configured identically at the SoundWire transport layer. DP1
Bank1 registers read from `/sys/kernel/debug/soundwire/master-0-1/`:

| Register (DP1 Bank1) | Chip 1 (0x8) | Chip 2 (0xb) | SoundWire field |
|---|---|---|---|
| 0x130 | 0x3 | 0x3 | `ChannelEn` |
| 0x132 | 0xf3 | 0xf3 | `SampleCtrl1` |
| 0x134 | 0x41 | 0x41 | `OffsetCtrl1` |
| 0x136 | 0x19 | 0x19 | `HCtrl` |

`asoc_sdw_hw_params()` in `soc_sdw_utils.c` assigns the same mask to every
codec on the link:

```c
if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
    ch_mask = GENMASK(ch - 1, 0);  // ch=2 -> 0x3 (both channels)
    step = 0;                      // all codecs get both channels
}

for_each_link_ch_maps(rtd->dai_link, i, ch_maps)
    ch_maps->ch_mask = ch_mask << (i * step);
```

PipeWire routes FL and FR as distinct streams to the ALSA boundary
(`output_FL -> playback_FL`, `output_FR -> playback_FR`, via `wpctl status`).
The DAPM graph from `/sys/kernel/debug/asoc/amd-soundwire/` shows `Left Spk`
fed by `tas2783-1 SPK` and `Right Spk` by `tas2783-2 SPK`, each codec with its
own path `Playback > ASI > FU21/FU23 > SPK`.

The stock driver exposes no channel-routing control. The entire mixer surface
for the speaker path is four mute gates and two gain pairs:

```
Left Spk Switch / Right Spk Switch          chip 1 mute gates
Left Spk2 Switch / Right Spk2 Switch        chip 2 mute gates
tas2783-1 Amp Volume / Speaker Volume       chip 1 gain
tas2783-2 Amp Volume / Speaker Volume       chip 2 gain
```

The kernel logs this for both amps at every boot:

```
acpi device:26: function type only supported as DisCo constant
acpi device:28: function type only supported as DisCo constant
```

A decompile of SSDT9 shows per-amp init tables in ACPI, including cluster
definitions: cluster 1 has channel-id 1, cluster 3 has channel-id 2.

Writing the PPU21 `PostureNumber` register directly, posture 1 to amp 1 and
posture 4 to amp 2, produces correct left and right output, confirmed by ear
on 2026-07-18.

### Conclusion

Both amps receive the full stereo stream by design, and each amp's DSP is
expected to render only its own channel. Which channel that is comes from the
per-amp init tables in ASUS firmware.

The kernel never applies those tables. `find_sdca_function()` in
`sound/soc/sdca/sdca_functions.c` requires the SDCA function type as a DisCo
constant, ASUS supplies it in another form, the parse fails, and both amps are
left in the same default state.

The fix writes the posture register from userspace: two kcontrols added to the
codec module, set to 1 and 4 by the UCM `EnableSequence`. The kernel-side fix
would be a fallback in `sdca_functions.c` so the firmware's own tables are
applied.

### Rejected hypothesis: IT21

The first hypothesis was the SDCA Input Terminal entity IT21, whose registers
the driver initialises to `0x0` and never writes:

```c
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x04, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x08, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x10, 0), 0x0},
{SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x11, 0), 0x0},
```

UDMPU23 Cluster Select was the second candidate. Neither produced channel
separation. The selector is PPU21 PostureNumber; note that posture 4 is not a
cluster index, as the amp cluster-id list is 1, 2, 3.

## Boot-time bus corruption

### Observations

At every boot, starting at the moment PipeWire starts and repeating around ten
times:

```
soundwire sdw-master-0-1: Program transport params failed: -22
soundwire sdw-master-0-1: Program params failed: -22
SDW1-PIN4-CAPTURE-SmartAmp: ASoC error (-22): at snd_soc_link_prepare()
sdw_deprepare_stream: subdevice #0-Capture: inconsistent state state 1
```

`SDW1-PIN4-CAPTURE-SmartAmp` is the IV-sense capture stream, PCM 3. The UCM
configuration does not define it as a device.

On a boot observed on 2026-08-04, with the fix installed: the right speaker
produced nothing, while the left one worked. At the same time both amps
reported unmuted switches, volumes at 200, postures 1 and 4, all three
SoundWire peripherals reported `Attached`, the sink was unmuted with both
channels at 100%, and the card was on the HiFi profile.

Forcing a fresh posture write to amp 2 did not restore output. Cycling the
card profile `off` then `HiFi` did, immediately.

On 2026-08-05, three consecutive boots with no bus reset played correct stereo
while the same probe failures appeared in the log each time (about 60 error
lines per boot).

### Conclusion

PipeWire's ACP layer probes every PCM the card exposes, including the one UCM
omits. That probe fails at every boot, and on some boots it leaves the
SoundWire transport in a state where the second amp receives no data, which is
why the fault is invisible to every mixer level check. What separates a boot
that comes up broken from one that does not is not known; the audible failure
is the rare case.

Cycling the profile tears the streams down and reprograms the transport.
`fix-sdw-speakers.service` does this once per boot, after WirePlumber starts;
because the failure is rare, the service is opt-in
(`./install.sh --with-bus-reset`) rather than part of the default install.

## Suspend and resume

### Observations

After s2idle suspend, all SoundWire peripherals fail to resume, including the
RT721 which none of this repo's changes touch:

```
sdw_deprepare_stream: inconsistent state state 1
rt721-sdca: SDW_SCP_BUSCLOCK_SCALE register write failed
soundwire sdw-master-0-1: Program params failed: -61
SDW1-PIN1-PLAYBACK-SmartAmp: ASoC error (-61): at snd_soc_link_prepare()
```

Peripherals report `-110` (ETIMEDOUT) and stay UNATTACHED. Reloading the driver
stack raises an IO_PAGE_FAULT in `snd_pci_ps` re-probe. Cycling the card
profile does not recover it, restarting PipeWire and WirePlumber does not
recover it, and unloading the codec module fails because the stream references
are still held. A reboot recovers it.

Observed after a suspend on 2026-08-05: no audio from any device, and the
posture controls reading 1 and 1 instead of 1 and 4. Cycling the card profile
set them back to 1 and 4 without restoring audio.

Observed on kernels 7.2.0-rc3 and 7.2.0-rc5. A systemd sleep hook that unloaded
the SoundWire stack before s2idle was tried as a workaround and hung the machine
(post-mortem in
[investigation-log.md](investigation-log.md)).

### Conclusion

The failure covers every device on the bus and predates this repo's changes, so
it sits in the platform's SoundWire suspend and resume path rather than in the
codec driver or in this fix. Unresolved.

## Device map

| Plasma name | PipeWire node | Hardware |
|---|---|---|
| Internal Speakers | `HiFi__Speaker__sink` | TAS2783 SmartAmp, stereo |
| Audio Jack (3.5mm) | `HiFi__Headphones__sink` | RT721 SDCA headphone jack |
| Audio Jack (3.5mm) | `HiFi__Headset__source` | RT721 SDCA jack mic |
| Internal Microphone | `HiFi__Mic__source` | PDM mic array |
| *(not defined)* | - | SmartAmp IV-sense, PCM 3 |

Node names are prefixed with `alsa_output.pci-0000_c4_00.5-platform-amd_sdw.` or
the matching `alsa_input.` form. The PCI address differs between units.

## Limitations

- Suspend and resume, as above.
- 16-bit 48 kHz output only. The TAS2783 supports up to 32-bit 96 kHz, but the
  AMD ACP70 SoundWire driver in `sound/soc/amd` is fixed at 48 kHz for SmartAmp
  playback.
- The patched module is a stopgap. It adds controls so userspace can do what
  the firmware's own init tables would have done.
- The `pro-audio` profile remains selectable in PipeWire and Plasma. It bypasses
  the UCM device definitions, so the posture sequence never runs. The
  WirePlumber configuration hides it.

## Shutdown tone

A tone lasting several seconds was heard during shutdown on this machine
earlier in the project. `/etc/modprobe.d/nobeep.conf` containing
`blacklist pcspkr` has been present since 2026-05-12; `pcspkr` is not loaded and
the kernel reports no PC Speaker input device. The tone has not recurred since.
