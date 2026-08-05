# Investigation log

Chronological record of the audio work on this laptop, dead ends included. For
what is currently true, read [analysis.md](analysis.md); for the kernel work
that is still outstanding, read [kernel-fix-plan.md](kernel-fix-plan.md).

- **2026-05**: first investigation. Its conclusion was wrong, superseded below.
- **2026-07-18**: actual root cause, confirmed by experiment.
- **2026-07-19**: suspend and resume failure; sleep-hook post-mortem.
- **2026-08-03**: a kernel update had wiped the fix; rebuild hook added.
- **2026-08-04**: boot-time bus corruption confirmed still real; bus reset
  service, install script, repo restructure.
- **2026-08-05**: the audible boot failure is rare; bus reset service demoted
  to opt-in.

Paths under `temp/` were scratch working files: kernel sources, ACPI decompiles
and captured logs. That directory is gitignored and its contents are not part of
this repo.

## 2026-05 investigation (superseded)

> The root cause named in this section, the UDMPU23 Cluster register never being
> configured, is **wrong**. The channel selector is PPU21 PostureNumber, and it
> goes unwritten because the SDCA function parse fails; see the 2026-07-18 entry.
> Kept because the hardware topology, register analysis and RT1318 comparison are
> accurate and are what led to the right answer.

### Problem statement

Both TAS2783 SmartAmp speakers on the ASUS ProArt PX13 play the **same audio content** (both channels mixed) instead of separate left/right channels. This means no stereo separation - both speakers output identical L+R audio.

### Hardware Topology

```
ASUS ProArt PX13 (HN7306EAC)
  AMD Strix Halo SoC
    ACP (Audio Co-Processor)
      SoundWire Bus 0, Link 1
        +-- tas2783-1 (unique_id=0x8)  -> "Left Spk"  / "Spk"
        +-- tas2783-2 (unique_id=0xb)  -> "Right Spk" / "Spk2"
```

- Vendor ID: 0x0102 (Texas Instruments)
- Part ID: 0x0000 (TAS2783)
- Both chips share a single DAI (PCM 2, stereo, SoundWire)
- ACPI match table in `amd-acp70-acpi-match.c` assigns name prefixes:
  - `0x0001380102000001` -> `tas2783-1`
  - `0x00013B0102000001` -> `tas2783-2`

### Root Cause Analysis

#### How SoundWire multi-codec DAIs work

In `soc_sdw_utils.c:1294-1335` (`asoc_sdw_hw_params`), for playback:
- `step = 0` and `ch_mask = GENMASK(ch - 1, 0)` (= 0x3 for stereo)
- Comment at line 1308: **"Identical data will be sent to all codecs in playback"**
- Both TAS2783 chips receive the full stereo stream (L+R on both)

This is **by design**. Each amp's internal DSP is supposed to select its own channel from the stereo data using the **UDMPU (Undecimation Multi-Purpose Unit) Cluster Select** register.

#### The bug: UDMPU23 Cluster is never configured

The UDMPU23 Cluster register controls which audio channel(s) the amp extracts from the stereo stream.

- Register: `SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_UDMPU23, TAS2783_SDCA_CTL_UDMPU_CLUSTER, 0)`
- Entity: `TAS2783_SDCA_ENT_UDMPU23 = 0x0E`
- Control: `TAS2783_SDCA_CTL_UDMPU_CLUSTER = 0x10`
- SDCA address: `0x40480700` (computed by SDW_SDCA_CTL macro)
- Size: 1 byte (confirmed by `tas2783_sdca_mbq_size` at lines 349-350, returns 1)
- Regmap default: `0x0` (line 302 of `tas2783-sdw.c`)
- **Live read confirmed**: `0x00` on chip 0x8 (via debugfs `registers` read)

**Value 0x0 = passthrough** - both channels pass through unmodified, so both amps play L+R mixed.

#### Where the bug manifests (three layers of missing code)

**Layer 1 - Codec driver (`tas2783-sdw.c`)**:
- `tas2783_snd_controls[]` (line 554-561) only has "Amp Volume" and "Speaker Volume"
- **No kcontrol for UDMPU23 Cluster** - userspace cannot set channel selection
- The header defines `TAS2783_DEVICE_CHANNEL_RIGHT = 2` but it's never used in the .c file

**Layer 2 - Machine driver (`soc_sdw_ti_amp.c`)**:
- `asoc_sdw_ti_spk_rtd_init` (line 40-82) only sets DAPM routes and caps volume
- `asoc_sdw_ti_amp_init` (line 85-96) only does `info->amp_num++`
- `asoc_sdw_ti_amp_initial_settings` (line 17-37) only limits speaker volume to 0dB
- **No code writes the UDMPU23 Cluster register for either amp**

**Layer 3 - UCM config (`ucm2/conf.d/amd-soundwire/HiFi.conf`, since removed from the repo)**:
- Speaker EnableSequence (line 35-39) only sets Switch controls
- Line 33 explicitly notes: **"The kernel exposes no source-select or slot-select for the TAS2783 path"**
- Cannot set channel selection because no kcontrol exists for it

### Reference Implementation: RT1318

The Realtek RT1318 SmartAmp driver (`rt1318-sdw.c`) has a working stereo implementation that serves as our reference pattern.

#### RT1318 kcontrol (lines 491-511)

```c
static const char * const rt1318_rx_data_ch_select[] = {
    "L,R",      // 0 - passthrough (both channels)
    "L,L",      // 1 - left channel to both outputs
    "L,R",      // 2 - (duplicate of 0, likely copy-paste error)
    "L,L+R",    // 3 - left to left, mix to right
    "R,L",      // 4 - swap channels
    "R,R",      // 5 - right channel to both outputs
    "R,L+R",    // 6
    "L+R,L",    // 7
    "L+R,R",    // 8
    "L+R,L+R",  // 9 - mono mix to both
};

static SOC_ENUM_SINGLE_DECL(rt1318_rx_data_ch_enum,
    SDW_SDCA_CTL(FUNC_NUM_SMART_AMP, RT1318_SDCA_ENT_UDMPU21,
                 RT1318_SDCA_CTL_UDMPU_CLUSTER, 0), 0,
    rt1318_rx_data_ch_select);

static const struct snd_kcontrol_new rt1318_snd_controls[] = {
    SOC_ENUM("RX Channel Select", rt1318_rx_data_ch_enum),
};
```

- Left amp: UCM sets "RX Channel Select" to 1 ("L,L")
- Right amp: UCM sets "RX Channel Select" to 5 ("R,R")

#### RT1318 machine driver

`asoc_sdw_rt_amp_spk_rtd_init` (in `soc_sdw_rt_amp.c`) does NOT set the channel register. It only adds DAPM routes. Channel selection is 100% driven from UCM/userspace.

#### RT1316 comparison

Uses the identical 10-value enum (copy-paste lineage from RT1318).

#### RT1320 comparison (IMPORTANT)

Uses a **completely different** 9-value enum in a different order, AND targets a PPU entity instead of UDMPU:

```c
// RT1320's values (different order, 9 not 10):
{"L,R", "R,L", "L,L", "R,R", "L,L+R", "R,L+R", "L+R,L", "L+R,R", "L+R,L+R"}
```

### Critical Finding: UDMPU Values are NOT SDCA-Standardized

The kernel's SDCA header (`include/sound/sdca_function.h`) defines:
- `SDCA_CTL_UDMPU_CLUSTERINDEX = 0x10` (the control ID - standardized)

But it does **NOT** define what values can be written to this control. The actual value-to-behavior mapping is **vendor-specific**:

| Driver | Entity | Values | Count |
|--------|--------|--------|-------|
| RT1316 | UDMPU21 | L,R / L,L / L,R / L,L+R / R,L / R,R / R,L+R / L+R,L / L+R,R / L+R,L+R | 10 |
| RT1318 | UDMPU21 | (identical to RT1316) | 10 |
| RT1320 | PPU21 | L,R / R,L / L,L / R,R / L,L+R / R,L+R / L+R,L / L+R,R / L+R,L+R | 9 |
| TAS2783 | UDMPU23 | **Unknown** | **Unknown** |

**We cannot assume RT1318's value mapping applies to TAS2783.** The values must be determined empirically or from TI documentation.

### Regmap & Write Path Analysis

#### Regmap configuration (`tas2783-sdw.c:513-524`)

```c
static const struct regmap_config tas_regmap = {
    .reg_bits = 32,
    .val_bits = 8,
    .readable_reg = tas2783_readable_register,  // returns mbq_size > 0
    .volatile_reg = tas2783_volatile_register,   // only data ports + 0x800001
    // NO writeable_reg callback -> all registers writable
    .reg_defaults = tas2783_reg_default,
    .num_reg_defaults = ARRAY_SIZE(tas2783_reg_default),
    .max_register = 0x41008000 + TASDEV_REG_SDW(0xa1, 0x60, 0x7f),
    .cache_type = REGCACHE_MAPLE,
    .use_single_read = true,
    .use_single_write = true,
};
```

Key properties of UDMPU23 Cluster register:
- **Writable**: Yes (no `writeable_reg` callback = all registers writable)
- **Volatile**: No (only data port ranges 0x000-0x540 and 0x800001 are volatile)
- **Cached**: Yes (REGCACHE_MAPLE, default value 0x0 seeds cache)
- **Read behavior**: Returns cached value (not volatile, so no hardware read)
- **Write behavior**: Updates cache AND writes to hardware (standard regmap non-volatile behavior)
- **MBQ size**: 1 byte (confirmed at lines 349-350)

#### Write path trace (kcontrol -> hardware)

```
SOC_ENUM kcontrol write
  -> snd_soc_put_enum_double()
    -> snd_soc_component_update_bits()
      -> regmap_update_bits()
        -> regmap_write()              [if bits changed]
          -> regmap_sdw_mbq_write()    [MBQ bus abstraction]
            -> regmap_sdw_mbq_write_impl(slave, reg, val, mbq_size=1)
              -> while(--mbq_size > 0)  [loop doesn't execute for size=1]
              -> sdw_write_no_pm(slave, reg, val & 0xff)  [direct SoundWire write]
```

#### Component regmap association

- `tas_component_probe` (line 1008-1017) does NOT call `snd_soc_component_init_regmap()`
- ASoC auto-discovers the MBQ regmap via `dev_get_regmap(dev, NULL)`
- The regmap is registered at line 1331: `devm_regmap_init_sdw_mbq_cfg()`

#### Why debugfs writes failed (previous test)

Debugfs writes returned -EINVAL when we tried to poke the register directly. This is because:
1. The device was likely in `cache_only` mode (set at probe line 1340 and suspend line 1072)
2. Debugfs does NOT trigger `pm_runtime_get` - the device stays suspended
3. kcontrol writes go through ASoC's component framework which properly handles pm_runtime resume

The resume path (line 1100-1102) does:
```c
regcache_cache_only(tas_dev->regmap, false);
regcache_sync(tas_dev->regmap);
```

This is NOT a concern for kcontrol writes - they trigger proper PM lifecycle.

### Power Management & Cache Sync

#### Suspend (`tas2783_sdca_dev_suspend`, line 1065-1073)
```c
regcache_cache_only(tas_dev->regmap, true);
```
Switches to cache-only mode. Hardware writes are deferred.

#### Resume (`tas2783_sdca_dev_resume`, line 1081-1103)
```c
regcache_cache_only(tas_dev->regmap, false);
regcache_sync(tas_dev->regmap);
```
Re-enables hardware writes and syncs all dirty cache values to hardware. This means: **if we write the UDMPU register via kcontrol while the device is active, the value will persist through suspend/resume cycles** because regcache_sync pushes cached values back to hardware on resume.

### DAPM Topology (Codec Driver)

#### Widgets (`tas2783-sdw.c:856-866`)
```
ASI        - AIF_IN  ("ASI Playback")
ASI OUT    - AIF_OUT ("ASI Capture")
FU21       - DAC_E   (mute event handler)
FU23       - DAC_E   (mute event handler)
SPK        - OUTPUT
DMIC       - INPUT
```

#### Routes (`tas2783-sdw.c:868-874`)
```
ASI  -> FU21 -> SPK    (playback main path)
ASI  -> FU23 -> SPK    (playback secondary path)
DMIC -> ASI OUT        (capture path)
```

Note: UDMPU23 is NOT represented in the DAPM topology. It sits logically between ASI and FU21/FU23 but has no widget. The register is written directly, not through DAPM power events.

#### Machine driver DAPM routes (`soc_sdw_ti_amp.c:40-82`)
```
"tas2783-1 SPK" -> "Left Spk"     (for prefix "tas2783-1")
"tas2783-2 SPK" -> "Right Spk"    (for prefix "tas2783-2")
"tas2783-3 SPK" -> "Left Spk2"    (for prefix "tas2783-3", if present)
"tas2783-4 SPK" -> "Right Spk2"   (for prefix "tas2783-4", if present)
```

### Other SDCA Entities of Interest

#### MU26 - Mixer Unit (8 channels)

The regmap defaults show MU26 with 8 channel mute controls (all default 0x0):
```
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_MU26, 0x01, 0..7) = 0x0  (mute for channels 0-7)
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_MU26, 0x06, 0)    = 0x0  (mixer control)
```

MU26 is listed in the `mbq_size` function (lines 436-443, returns 1 for each). This mixer unit could potentially be relevant to channel routing as an alternative to UDMPU, but it's not how RT1318-family drivers handle it.

#### IT21 - Input Terminal

```
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x04, 0) = 0x0  (confirmed live read: 0x00)
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x08, 0) = 0x0
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x10, 0) = 0x0
SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_IT21, 0x11, 0) = 0x0
```

All IT21 registers default to 0x0 and are never written elsewhere in the driver.

#### Header Constants

```c
#define TAS2783_SDCA_ENT_FU21       0x01   // Feature Unit (volume/mute)
#define TAS2783_SDCA_ENT_FU23       0x02   // Feature Unit (capture mute)
#define TAS2783_SDCA_ENT_FU26       0x03
#define TAS2783_SDCA_ENT_XU22       0x04   // Extension Unit
#define TAS2783_SDCA_ENT_CS24       0x05   // Clock Source
#define TAS2783_SDCA_ENT_CS21       0x06
#define TAS2783_SDCA_ENT_PDE23      0x0C   // Power Domain Entity
#define TAS2783_SDCA_ENT_UDMPU23    0x0E   // << THE KEY ENTITY
#define TAS2783_SDCA_ENT_SAPU29     0x0F   // SmartAmp Processing Unit
#define TAS2783_SDCA_ENT_PPU21      0x10   // Posture Processing Unit
#define TAS2783_SDCA_ENT_PPU26      0x11
#define TAS2783_SDCA_ENT_TG23       0x12   // Tone Generator
#define TAS2783_SDCA_ENT_IT21       0x13   // Input Terminal (playback)
#define TAS2783_SDCA_ENT_IT29       0x14
#define TAS2783_SDCA_ENT_IT26       0x15   // Input Terminal (feedback)
#define TAS2783_SDCA_ENT_IT28       0x16
#define TAS2783_SDCA_ENT_OT24       0x17   // Output Terminal
#define TAS2783_SDCA_ENT_OT23       0x18
#define TAS2783_SDCA_ENT_MU26       0x1B   // Mixer Unit (8 channels)
#define TAS2783_SDCA_ENT_MFPU21     0x22   // Multi-Function Processing Unit
#define TAS2783_SDCA_ENT_MFPU26     0x23

#define TAS2783_SDCA_CTL_UDMPU_CLUSTER  0x10
#define TAS2783_DEVICE_CHANNEL_LEFT     1   // Used as SDCA channel parameter, NOT a register value
#define TAS2783_DEVICE_CHANNEL_RIGHT    2   // Defined but NEVER used in .c file
```

### DAI Configuration

#### Codec DAI (`tas2783-sdw.c:985-1005`)
```c
{
    .name = "tas2783-codec",
    .playback = { .channels_min = 1, .channels_max = 4, ... },
    .capture  = { .channels_min = 1, .channels_max = 4, ... },
    .ops = &tas_dai_ops,  // hw_params, hw_free, set_stream, shutdown
    .symmetric_rate = 1,
}
```

No `set_tdm_slot` in `tas_dai_ops`. Channel selection is not done at the DAI level.

#### Machine driver codec_info (`soc_sdw_utils.c:74-94`)
```c
{
    .vendor_id = 0x0102,
    .part_id = 0x0000,
    .name_prefix = "tas2783",
    .dais = {{
        .direction = {true, true},        // playback + capture
        .dai_name = "tas2783-codec",
        .dai_type = SOC_SDW_DAI_TYPE_AMP,
        .dailink = {SOC_SDW_AMP_OUT_DAI_ID, SOC_SDW_AMP_IN_DAI_ID},
        .init = asoc_sdw_ti_amp_init,             // only bumps amp_num++
        .rtd_init = asoc_sdw_ti_spk_rtd_init,     // DAPM routes + volume cap
        .controls = lr_4spk_controls,
        .num_controls = ARRAY_SIZE(lr_4spk_controls),
        .widgets = lr_4spk_widgets,
        .num_widgets = ARRAY_SIZE(lr_4spk_widgets),
    }},
    .dai_num = 1,
}
```

#### hw_params behavior (`soc_sdw_utils.c:1294-1335`)
For playback with 2-channel (stereo) audio:
- `ch_mask = GENMASK(1, 0) = 0x3` (both channels)
- `step = 0`
- Both codecs get `ch_mask = 0x3` via the `for_each_link_ch_maps` loop
- Result: identical stereo data to both amps

### Existing UCM Configuration

#### HiFi.conf Speaker section
```
SectionDevice."Speaker" {
    Comment "TAS2783 SmartAmp Speakers"
    EnableSequence [
        cset "name='Left Spk Switch' on"
        cset "name='Right Spk Switch' on"
        cset "name='Left Spk2 Switch' on"
        cset "name='Right Spk2 Switch' on"
    ]
    DisableSequence [
        cset "name='Left Spk Switch' off"
        cset "name='Right Spk Switch' off"
        cset "name='Left Spk2 Switch' off"
        cset "name='Right Spk2 Switch' off"
    ]
    Value {
        PlaybackPriority 100
        PlaybackPCM "hw:${CardId},2"
    }
}
```

These Switch controls map to DAPM widgets, not to channel selection. Lines 33-34 of HiFi.conf explicitly document the limitation.

### Name Prefix Mechanism

ASoC kcontrol naming with `name_prefix`:
- Each TAS2783 component gets a prefix from ACPI match tables
- `tas2783-1` prefix -> all kcontrols prefixed with "tas2783-1 "
- `tas2783-2` prefix -> all kcontrols prefixed with "tas2783-2 "

Current kcontrols exposed (per component):
- `"tas2783-1 Amp Volume"` / `"tas2783-2 Amp Volume"`
- `"tas2783-1 Speaker Volume"` / `"tas2783-2 Speaker Volume"`

Volume limiting in `asoc_sdw_ti_amp_initial_settings` (line 23) constructs `"%s Speaker Volume"` using the prefix, confirming this naming pattern.

After adding a channel select kcontrol named `"RX Channel Select"`, it would appear as:
- `"tas2783-1 RX Channel Select"`
- `"tas2783-2 RX Channel Select"`

### Fix Viability Assessment

#### Option A: kcontrol in codec driver + UCM (matches RT1318 pattern)
- Add `SOC_ENUM` (or `SOC_SINGLE`) to `tas2783_snd_controls[]`
- Set from UCM EnableSequence
- **Pro**: Matches established pattern, upstream-friendly
- **Con**: Small race window between card registration and UCM load; bare ALSA users never get it set

#### Option B: Machine driver init
- Write UDMPU register in `asoc_sdw_ti_spk_rtd_init` via `snd_soc_component_write(codec_dai->component, reg, val)`
- **Pro**: Immediate at boot, no UCM dependency
- **Con**: Hardcoded, no userspace override; not how RT1318 family does it

#### Option C: Both (recommended)
- kcontrol in codec driver for userspace visibility/override
- Default channel set in machine driver `rtd_init` for boot-time correctness
- **Pro**: Most robust - works at boot AND allows userspace control
- **Con**: Two files to patch instead of one; mild complexity

#### Fix location access

`asoc_sdw_ti_spk_rtd_init` already has everything needed for Option B/C:
- Iterates `codec_dai` via `for_each_rtd_codec_dais(rtd, i, codec_dai)`
- Has `codec_dai->component` (used at line 56 for `name_prefix`)
- Already branches on `tas2783-1` vs `tas2783-2` prefix
- Can call `snd_soc_component_write(codec_dai->component, UDMPU_REG, value)`

### ACPI DisCo Cluster Definitions (NEW - discovered 2026-05-25)

The ACPI firmware exposes SDCA DisCo properties for both TAS2783 devices via sysfs:
```
/sys/bus/soundwire/devices/sdw:0:1:0102:0000:01:8/firmware_node/device:26/
```

**Three cluster configurations are defined at function level (identical on both chips):**

| Cluster ID | Channels | Structure | Likely Meaning |
|-----------|----------|-----------|----------------|
| 1 | 1 | channel-1 only | Mono - Left channel |
| 2 | 2 | channel-1 + channel-2 | Stereo passthrough |
| 3 | 1 | channel-1 only | Mono - Right channel |

**UDMPU23 entity (0xE) properties from ACPI:**
- Control 0x10 (Cluster Index) - ACPI path: `\_SB_.PCI0.GPPA.ACP_.SDWC.SW25.AF01.C050`
- Controls 0x20-0x24 (opaque vendor-specific)
- Rich input-pin hierarchy with nested entities (IT, CS, FU etc.)

**Interpretation:** The regmap default of `0x0` means "no cluster selected" = passthrough (both channels, explaining the bug). Writing cluster index 1 or 3 should select mono left or mono right respectively. Cluster 2 = stereo passthrough (explicit, vs 0 = default/implicit passthrough).

**Key hypothesis to test:**
- Left amp (tas2783-1): write UDMPU cluster = **1** (cluster 1, mono left)
- Right amp (tas2783-2): write UDMPU cluster = **3** (cluster 3, mono right)

This is strongly supported by:
1. The ACPI firmware structure defines exactly 3 clusters
2. Only clusters 1 and 3 are mono (single channel) - needed for L/R separation
3. Cluster 2 is stereo - would be passthrough, not useful for separation
4. The header constants `TAS2783_DEVICE_CHANNEL_LEFT=1` and `TAS2783_DEVICE_CHANNEL_RIGHT=2` align with SDCA channel numbering

#### CONFIRMED from SSDT9 ACPI table (decompiled 2026-05-26)

Source: `temp/decompile/SSDT9.dsl` lines 12641-12808 (device SW25 = tas2783-1, duplicated at 17754-17917 for SW2B = tas2783-2)

> **CORRECTION (2026-07-18): The two devices' cluster definitions are NOT identical.** SW2B's CL01 has channel-id=2, relationship=0x03 (Right). See the "2026-07-18 Re-orientation" section at the end of this file - the conclusions below about writing cluster 1/3 are superseded.

**Cluster 1 (CL01)** - 1 channel:
- CH00: channel-id=1, purpose=1 (Left Front), relationship=0x02 (Left of pair)
- **Meaning: LEFT channel only**

**Cluster 2 (CL02)** - 2 channels:
- CH20: channel-id=1, purpose=1 (Left Front), relationship=0x02 (Left of pair)
- CH21: channel-id=2, purpose=1, relationship=0x03 (Right of pair)
- **Meaning: Stereo passthrough (L+R)**

**Cluster 3 (CL03)** - 1 channel:
- CH30: channel-id=2, purpose=1, relationship=0x03 (Right of pair)
- **Meaning: RIGHT channel only**

SDCA `mipi-sdca-cluster-channel-relationship` values:
- 0x02 = Left of stereo pair
- 0x03 = Right of stereo pair

**CONFIRMED: Cluster 1 = Left, Cluster 3 = Right. Write 1 to left amp, 3 to right amp.**

**TI documentation search (2026-05-25):** EVM User's Guide (SLOU557A) and Application Note (SLOA329) do not document UDMPU register values. The TAS2783 full datasheet with SDCA register details appears to be access-restricted on ti.com. However, the ACPI firmware provides definitive cluster definitions.

### Known Unknowns & Risks

#### 1. TAS2783 UDMPU23 Cluster values (RESOLVED)
**CONFIRMED from SSDT9 ACPI decompile**: Cluster 1 = Left (channel-id=1, relationship=0x02), Cluster 3 = Right (channel-id=2, relationship=0x03). Write register value 1 to left amp, 3 to right amp.

#### 2. Chip 0xb (tas2783-2) bus stability (LOW-MEDIUM RISK)
Chip 0xb hangs on some SDCA register reads via debugfs. This was observed during data gathering. May be related to the known IV-sense capture issue (PCM 3). Needs monitoring during testing.

#### 3. Kernel module build/deploy (LOW RISK)
Need to decide: out-of-tree module rebuild for quick testing vs full kernel rebuild. CachyOS kernel headers are at `/usr/lib/modules/$(uname -r)/build/`.

### Step 2 Brainstorm Conclusion (2026-05-25)

#### Chosen Approach: Option C (kcontrol + machine driver default + UCM)

**Three-layer fix matching established kernel patterns (RT1318 precedent):**

1. **Codec driver** (`tas2783-sdw.c` line 554):
   - Add `SOC_SINGLE` kcontrol for UDMPU23 cluster register (range 0-3)
   - Name: `"RX Channel Select"` - auto-prefixed per component
   - Register: `SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_UDMPU23, TAS2783_SDCA_CTL_UDMPU_CLUSTER, 0)`
   - Start with SOC_SINGLE for testing; optionally upgrade to SOC_ENUM later

2. **Machine driver** (`soc_sdw_ti_amp.c` line 52-69 in `asoc_sdw_ti_spk_rtd_init`):
   - After existing prefix branch, add `snd_soc_component_write()` calls:
     - tas2783-1 -> cluster 1 (left)
     - tas2783-2 -> cluster 3 (right)
   - Already has `codec_dai->component` and branches on prefix

3. **UCM** (`HiFi.conf` Speaker EnableSequence):
   - Add: `cset "name='tas2783-1 RX Channel Select' 1"`
   - Add: `cset "name='tas2783-2 RX Channel Select' 3"`

#### Cluster values to test
- **Primary hypothesis** (from ACPI DisCo): cluster 1=left, cluster 3=right
- **Fallback**: empirical sweep of values 0-9 with SOC_SINGLE kcontrol

#### Build strategy
- Out-of-tree module rebuild against `/usr/lib/modules/$(uname -r)/build/`
- Need to rebuild both `snd-soc-tas2783-sdw.ko` and `snd-soc-sdw-utils.ko`

#### DSDT confirmation (optional, reduces risk)
```bash
cd temp/decompile
for s in /sys/firmware/acpi/tables/SSDT*; do
  n=$(basename $s); sudo cp "$s" "${n}.dat"
done
for f in SSDT*.dat; do
  if strings "$f" | grep -q "SW25"; then
    echo "MATCH: $f"; iasl -d "$f" 2>/dev/null
  fi
done
grep -n "CL0\|CH[0-9]\|cluster\|UDMPU" *.dsl
```
Look for `_DSD` packages containing cluster channel mapping properties.

#### Ready for Step 3: Detailed fix implementation plan

## 2026-07-18 re-orientation: actual root cause found

Session context: user returned after ~7 weeks. System now runs kernel **7.2.0-rc3-1-cachyos-rc** as daily driver (bluetooth issue with RC apparently resolved; audio bug persists). Fresh v7.2-rc3 sources cached in `temp/kernel-src-7.2rc3/` (tas2783-sdw.c, tas2783.h, soc_sdw_ti_amp.c, sdca_regmap.c, sdca_functions.c, sdca_device.c).

### Driver drift 6.x to 7.2-rc3 (all minor, fix area untouched)

- tas2783-sdw.c: new firmware-fallback load mechanism (`fw_use_fallback`), tas25xx misc device removed, `sdca_parse_function()` signature changed (function desc now passed via `function_data->desc`), resume path refactored into `tas_io_init()` guarded by `hw_init`
- tas2783.h: misc device declarations removed
- soc_sdw_ti_amp.c: tac5xx2 support appended; `asoc_sdw_ti_spk_rtd_init` unchanged
- Still NO channel/posture kcontrol in `tas2783_snd_controls[]` (only Amp Volume + Speaker Volume). Bug not fixed upstream.

### The actual root cause (supersedes the UDMPU theory)

Boot log (`journalctl -k`):
```
acpi device:24: SDCA function UAJ (type 6) at 0x1        <- rt721, parse OK
acpi device:26: function type only supported as DisCo constant   <- amp 1 parse FAILS
acpi device:28: function type only supported as DisCo constant   <- amp 2 parse FAILS
```

**Failure chain:**
1. `find_sdca_function()` (sound/soc/sdca/sdca_functions.c:~90) reads the function type from entity 0 control 0x5 property `mipi-sdca-control-dc-value`. The rt721's ACPI provides it (access-mode 0x05 = DC, dc-value 6). The TAS amps' ACPI (`Name (C005 ...)` at SSDT9.dsl:8781 and 13894) declares access-mode **0x03 (read-only hardware)** with **no dc-value** - a firmware defect. The kernel refuses to read the type from hardware and bails with -ENODEV/-EINVAL.
2. Result: `slave->sdca_data.num_functions == 0` for both amps -> in `tas_sdw_probe` no function is parsed -> `sa_func_data == NULL`.
3. In `tas_io_init`, driver takes the fallback path: `regmap_multi_reg_write(tas2783_init_seq)` - which writes **identical values to both amps**, including `PPU21 PostureNumber (0x40480800) = 0x01` for BOTH.
4. The ACPI init tables (`mipi-sdca-function-initialization-table`, BUF0 at SSDT9.dsl:8425+7 for amp1, 13538+7 for amp2), which are what `sdca_regmap_write_init()` would have applied, are **identical except one entry**: `0x40480800 = 0x01` (amp1) vs `0x40480800 = 0x04` (amp2). This is the per-amp L/R differentiation - and it never gets written.

**Register 0x40480800 = SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_PPU21 (0x10), ctl 0x10, 0) = PPU21 PostureNumber.** The TI DSP posture (loaded from the RCA firmware blob) encodes which channel each amp renders: posture 1 = amp1 role, posture 4 = amp2 role. Note: NOT a cluster index (there is no cluster 4; amp cluster-id-list is 1,2,3).

### Corrections to earlier findings

- **SW2B's clusters are NOT identical to SW25's** (earlier doc claim was wrong): SW2B CL01 = channel-id 2, relationship 0x03 = **Right**. So cluster 1 means "this amp's own channel" on each device.
- **UDMPU23 Cluster Select** (0x40480700): ACPI declares it access-mode 0x05 (DC = Defined Constant) with dc-value **1 on BOTH amps** (C050 at SSDT9.dsl:10432 and 15545). The SDCA core deliberately skips DC controls in `populate_control_defaults()` (sdca_regmap.c:291) - per spec the device itself implements the constant. The "write 1 to left amp, 3 to right amp" plan from Step 2 was based on the wrong "identical clusters" assumption. If UDMPU is ever written manually: value 1 on BOTH amps is the firmware intent.
- The old Option C (UDMPU kcontrol + machine driver + UCM) is superseded. The correct target register is PPU21 PostureNumber, and the correct proper fix is making the SDCA function parse succeed so the ACPI init tables are applied.

### Precedent in sdca_device.c

`sdca_device_quirk_skip_func_type_patching()` - Dell SKUs 0C62/0C63/0C6B with Cirrus CS42L43 (mfg 0x01fa part 0x4243) already quirk around function-type problems. Template for an upstreamable fix.

### Facts for the fix

- Amps: `sdw:0:1:0102:0000:01:8` (tas2783-1) and `sdw:0:1:0102:0000:01:b` (tas2783-2); driver matches `SDW_SLAVE_ENTRY(0x0102, 0x0000, 0)`; `find_sdca_function` has `slave` in scope via container_of.
- `mipi-sdw-sdca-interface-revision = 0x1000` (>= 0x0801) so `patch_sdca_function_type()` is a no-op - a fallback can just set `function_type = SDCA_FUNCTION_TYPE_SMART_AMP`.
- PPU21 PostureNumber (0x40480800) is already in the driver's `reg_defaults` (default 0x0) and in the readable/mbq list (1 byte) - a plain SOC_SINGLE kcontrol needs no regmap changes; reads come from regcache (no chip-0xb bus-read hang risk); non-default values survive suspend via `regcache_sync`.
- Build environment: Secure Boot enabled but lockdown `[none]`, `CONFIG_MODULE_SIG_FORCE` not set -> unsigned out-of-tree modules load fine. Headers at `/usr/lib/modules/7.2.0-rc3-1-cachyos-rc/build/` (linux-cachyos-rc-headers installed). Modules zstd-compressed (`CONFIG_MODULE_COMPRESS_ZSTD`).
- Amp init table decode (5-byte entries, LE u32 addr + u8 val), amp1: (0x40480800,0x01) (0x00800428,0x40) (0x00800429,0) (0x0080042A,0) (0x0080042B,0) (0x40400108,0) (0x40400109,0) (0x0080005C,0x59) (0x00800082,0x20) (0x008000D2,0x04). Amp2 identical except first entry value 0x04.

See [kernel-fix-plan.md](kernel-fix-plan.md) for the kernel-side plan and `patches/phase1-tas2783-posture-kcontrols.patch` for the kcontrol diff. (Both this file and the plan moved from temp/ to docs/ on 2026-07-18 so they are git-tracked; scratch material - kernel sources, ACPI decompiles, build dir - remains in temp/.)

## 2026-07-18 root cause confirmed by experiment

With the patched module installed, posture amp1=1 / amp2=4 produces correct stereo
separation, verified by ear with per-amp mute isolation: amp1 muted leaves only Front
Right audible, amp2 muted leaves only Front Left, both on gives correct sides. This
confirms the whole causal chain: PPU21 PostureNumber is the channel selector, the ACPI
init table values are correct, and the only defect is that they are never applied
because the SDCA function parse fails. UDMPU writes were not needed.

Two side issues surfaced during the same session:

1. All audio devices had disappeared. alsa-ucm-conf 1.2.16 routes the amd-soundwire
   HiFi verb through the shared `sof-soundwire/HiFi.conf`, which includes a
   per-speaker-codec file named from CardComponents. Kernel 7.2 newly reports
   `spk:tas2783`, so UCM demanded `sof-soundwire/tas2783.conf`, which no alsa-ucm-conf
   release ships, not even upstream master. Writing that file fixed it, and it also
   obsoleted this repo's old `conf.d/amd-soundwire/HiFi.conf` override, dead config
   since the June update.
2. `tas2783-1 Speaker Volume` was restored to 0 at boot from a stale
   `/var/lib/alsa/asound.state` via alsa-restore.service, silencing the left speaker.

The UCM file carries the posture csets in the Speaker EnableSequence, guarded by
`If.ControlExists` on the posture kcontrol, so the profile still loads on a stock
kernel and falls back to a mixed L+R.

**Reboot persistence verified 2026-07-19**: stereo survives a reboot with no manual
intervention (posture 1/4, volumes 200/200 after boot). Two independent layers carry
it: `/var/lib/alsa/asound.state` saved at shutdown and replayed at boot, and the UCM
file re-asserting posture every time the Speaker device is enabled, so a stale state
file cannot break stereo on its own.

## 2026-07-19 s2idle suspend and resume kills the whole SoundWire bus

Separate from the stereo fix (which survives reboots fine - see kernel-fix-plan.md
Phase 1 result). During the Phase 1 suspend/resume verification, resume from s2idle
left ALL THREE SoundWire peripherals dead, including rt721 on the completely stock
driver - so this is a platform/controller bug, not caused by our patched tas2783
module.

Signature (kernel 7.2.0-rc3-1-cachyos-rc, full log in
temp/suspend-resume-failure-2026-07-19.log):

- On resume: `PM: dpm_run_callback(): acpi_subsys_resume returns -110` (ETIMEDOUT)
  for sdw:0:1:025d:0721:01 and both sdw:0:1:0102:0000:01:8/b.
- Afterward all peripherals report "Not enumerated, skip programming BUSCLOCK_SCALE";
  `/sys/bus/soundwire/devices/*/status` = UNATTACHED; every playback attempt fails
  (`Program transport params failed: -61`), making PipeWire retry in a loop (GUI
  devices flap on/off).
- Full driver-stack reload (snd_acp_sdw_legacy_mach + codec drivers + snd_pci_ps)
  does NOT recover the bus: re-probe hits
  `snd_pci_ps 0000:c4:00.5: AMD-Vi: IO_PAGE_FAULT ... address=0xfffffffffffffffc`
  (note: address = -4 cast to a pointer - looks like an errno used as a DMA address),
  amps report "Initialization not complete", peripherals stay UNATTACHED.
  Only a reboot recovers.

History: journal shows only two s2idle suspends on this kernel (both 2026-07-19),
both failed identically. The repo's old profile-cycle service (profile
off/on toggle after boot) hints at earlier suspend-ish trouble, but that mechanism
cannot fix an unattached bus and the service is not installed.

Open paths (in order of preference):
1. Check whether a newer kernel (7.2-rc4+/CachyOS update) fixes resume - rc3 is a
   moving target and this smells like an upstream regression worth searching
   lore.kernel.org for.
2. Workaround: systemd system-sleep hook that unloads the audio module stack before
   suspend and reloads it after resume (avoids the broken resume path entirely) -
   UNTESTED hypothesis; the IO_PAGE_FAULT on reload after a failed resume may or may
   not occur when unloading happens before sleep.
3. Report upstream with the captured log.

## 2026-07-19 sleep-hook workaround: post-mortem of a hard hang

The first version of the sleep hook (commit bcfe749, since removed from the repo) hung the
machine on its first suspend test; only a long-press power-off recovered. Journal
from that boot (boot -1) shows the exact failure:

1. systemd-sleep froze user.slice BEFORE running system-sleep hooks
   ("Successfully froze unit 'user.slice'", 22:50:45).
2. The hook then ran `runuser ... systemctl --user stop wireplumber` - a call into
   the now-frozen user manager: "Cannot start frozen unit Session 4 of User chris" /
   pam_systemd Varlink io.systemd.Login.UnitAllocationFailed. The call hung ~90 s
   (hook start 22:50:45 -> "Performing sleep operation 'suspend'" 22:52:15). During
   that window the whole desktop was frozen (stuck cursor, dead keyboard) - that IS
   the user.slice freeze, visible.
3. WirePlumber, frozen rather than stopped, still held /dev/snd fds, so
   `modprobe -r` necessarily failed EBUSY and suspend entered with the full audio
   stack loaded - the exact path the hook was meant to avoid.
4. Resume then wedged harder than the first failure: journal has NO lines after
   "PM: suspend entry"/"Filesystems sync" - no "PM: suspend exit", nothing.
   Ctrl-Alt-Del was partially processed (Bluetooth links reset and reconnected,
   keyboard backlight turned off) but the display never recovered. Forced power-off.

Lessons (baked into the rewritten, still-UNTESTED v2 script):
- system-sleep hooks must never call into user managers (frozen at that point).
- WirePlumber cannot be stopped from a sleep hook, so module unload is not viable;
  sysfs driver unbind (amd_sdw machine device + amd_sdw_manager.0/.1) works with
  open fds instead.
- Unknown whether the harder wake-wedge was caused by the 90 s hook stall or is
  natural variance of the underlying resume bug (journal was lost at power-off).

Validation protocol before EVER installing v2: manually unbind (sudo tee to sysfs),
suspend once with NO hook installed, resume, manually rebind, check bus status.
Only if that round-trips cleanly does the hook get installed.

Status: hook NOT installed (removed 22:56). Suspend remains broken at the platform
level on this kernel - parked pending either the manual validation test above, a
kernel update, or an upstream fix; full log at temp/suspend-resume-failure-2026-07-19.log
plus this post-mortem are the material for an upstream regression report.

## 2026-08-03 kernel update wiped the fix; rebuilt for rc5, hook added

Roughly two weeks of normal use on kernel 7.2.0-rc5-1-cachyos-rc (updated from
rc3 at some point) before anyone noticed audio was wrong. What happened:

- The kernel package update deleted `/usr/lib/modules/<old>/updates/`, taking
  the patched module with it. The stock driver has no posture kcontrols, so the
  UCM ControlExists guard silently skipped the posture csets (exactly as
  designed) and alsa-restore could not replay them either.
- Observed symptom this time: only the LEFT speaker played, carrying only the
  left stream (not the original both-speakers-L+R-mix). Consistent with both
  amps on fallback posture 1 (= left channel) and the right amp's volume not
  restored (asound.state was saved against the patched kernel's control
  numbering, so alsactl restore partially failed on the stock driver).
- Confirmed rc5 still has the underlying bug: this boot's journal shows
  "function type only supported as DisCo constant" for acpi device:26 and
  device:28. Zero relevant upstream movement between rc3 and rc5;
  sound/soc/codecs/tas2783-sdw.c and tas2783.h are byte-identical between the
  two tags (verified by diff against GitHub raw sources).

Recovery + hardening (all done today):

1. Rebuilt the patched module against rc5 headers (make LLVM=1, vermagic
   7.2.0-rc5-1-cachyos-rc), installed to updates/, depmod.
2. Live swap without reboot: stop wireplumber/pipewire user units (twice, to
   beat socket activation), sudo modprobe -r snd_acp_sdw_legacy_mach
   snd_soc_tas2783_sdw, modprobe both back, restart user units. UCM re-applied
   posture 1/4 on profile activation automatically; volumes 200/200; stereo
   verified by ear with speaker-test.
3. Pacman hook so this never recurs: sources at /usr/local/src/tas2783 (repo
   src/tas2783/), rebuild script at /usr/local/bin/tas2783-module-rebuild (repo
   install/root/usr/local/bin/tas2783-module-rebuild), hook at
   /etc/pacman.d/hooks/99-tas2783-module.hook (repo
   install/root/etc/pacman.d/hooks/99-tas2783-module.hook). Triggers on any kernel or headers
   install/upgrade, rebuilds for every installed kernel that has headers.

Repo cleanup in the same session: removed the obsolete conf.d/amd-soundwire UCM
override (dead since alsa-ucm-conf 1.2.16 symlinked the card to sof-soundwire)
and the fix-sdw-speakers.service profile-cycle workaround (boot-time bus
corruption no longer occurs on 7.2 with the current UCM). Note for installed
systems: /usr/share/alsa/ucm2/conf.d/amd-soundwire/HiFi.conf may linger as a
stray root-owned file from the old approach; it is inert but should be deleted.

Suspend/resume: unchanged, still broken at platform level on rc5 (not retested
this session; nothing landed upstream).

## 2026-08-04 bus corruption is real after all; install scripted; restructure

The claim just above, that the boot-time bus corruption no longer occurs on
7.2, was wrong, and disproven the next day. The user reported the right
speaker silent on a boot where every mixer-level check read correct: postures
1 and 4, all switches on, volumes 200, all peripherals `Attached`, sink
unmuted. The kernel log showed the familiar signature, starting the moment
PipeWire starts and repeating about ten times:

    SDW1-PIN4-CAPTURE-SmartAmp: ASoC error (-22): at snd_soc_link_prepare()
    sdw_deprepare_stream: subdevice #0-Capture: inconsistent state state 1

PipeWire's ACP layer probes every PCM the card exposes regardless of UCM, the
IV-sense probe fails, and the transport is left with the second amp receiving
nothing. Forcing a fresh posture write to amp 2 did not restore output;
cycling the card profile off -> HiFi did, immediately, confirmed by ear. The
failure had been masked in earlier sessions because the manual module-swap
procedure ends in exactly such a profile cycle.

Consequences, all landed the same day:

- The profile-cycle workaround came back, rewritten: `tas2783-bus-reset`
  waits for the card and restores whichever profile is active instead of the
  hardcoded "HiFi (Mic, Speaker)" name that no longer exists, run once per
  boot by `fix-sdw-speakers.service` after WirePlumber. Verified on a cold
  boot: service ran at +56 s, cycled the card, stereo correct with no manual
  step.
- The whole install became `install.sh` (with `--check`, `--listen`,
  `--uninstall`, `--firmware`), verified end to end from a fresh clone. The
  automated checks all pass while an amp is silent, so `--check` ends in a
  listening test and runs the bus reset itself when the answer is "right
  speaker silent".
- Firmware turned out to ship in linux-firmware 20260622+ (byte-identical to
  the ASUS extraction), so extraction is now a fallback only.
- Repo restructure: README is the install guide, the old README's background
  became analysis.md, config/ and ucm2/ became the install/ overlay tree, and
  the unvalidated v2 sleep hook was deleted from the repo without ever being
  tested.

2026-08-05, from an accidental suspend: the suspend failure also resets the
posture controls to 1 and 1, and a profile cycle rewrites them to 1 and 4
without restoring audio. Consistent with the codecs losing state along with
the bus; reboot remains the only recovery.

## 2026-08-05 the audible boot failure is rare; bus reset service demoted to opt-in

A deliberate trial with `fix-sdw-speakers.service` disabled: three consecutive
boots, no manual intervention, and both speakers played correctly every time,
while the IV-sense probe failure appeared in the log on each boot (about 60
error lines at PipeWire start). So the probe storm happens at every boot, but
the transport corruption it was blamed for is intermittent, and the audible
failure is the rare case.

Reassessment of the evidence for the service: exactly one confirmed audible
occurrence (2026-08-04, previous entry). The "masked for weeks by the manual
procedures" argument only shows the historical rate is unknowable, not that it
was high; the every-boot framing in the previous entry overstated it.

Demoted accordingly, same day:

- Default `./install.sh` installs only the `tas2783-bus-reset` helper script.
  The service unit is installed and enabled only with `--with-bus-reset`.
- `--check` no longer fails when the service is absent. When the listening
  test finds the right speaker silent and the bus reset repairs it, it tells
  the user to reinstall with `--with-bus-reset`; that live repair is the
  signal the machine actually needs the service.
- README step 7 rewritten as the optional workaround, analysis.md conclusion
  softened to match: what separates a broken boot from a clean one is not
  known.
