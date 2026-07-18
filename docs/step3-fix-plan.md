# Step 3: Detailed Fix Plan (2026-07-18)

Target kernel: 7.2.0-rc3-1-cachyos-rc (daily driver). Sources: `temp/kernel-src-7.2rc3/`.

Root cause (see investigation doc, 2026-07-18 section): SDCA function parse fails for both
amps because ASUS firmware omits the DisCo constant for the function type. The per-amp ACPI
init tables (PPU21 PostureNumber = 1 on amp1, 4 on amp2 - the L/R differentiation) are
therefore never written; the driver's hardcoded fallback configures both amps identically.

## Phase 1 - Empirical validation via kcontrols (smallest change, fastest signal)

Goal: prove that PPU21 PostureNumber 1-vs-4 produces stereo separation, with runtime
sweep capability so no rebuild is needed to try other values.

### Patch A: tas2783-sdw.c - add two SOC_SINGLE kcontrols

In `tas2783_snd_controls[]` (line ~556):

```c
	SOC_SINGLE("DSP Posture Select",
		   SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_PPU21, 0x10, 0),
		   0, 15, 0),
	SOC_SINGLE("UDMPU Cluster Select",
		   SDW_SDCA_CTL(1, TAS2783_SDCA_ENT_UDMPU23,
				TAS2783_SDCA_CTL_UDMPU_CLUSTER, 0),
		   0, 3, 0),
```

- Both registers are in reg_defaults and the readable/mbq list already - no other changes.
- ASoC name-prefixing yields `tas2783-1 DSP Posture Select`, `tas2783-2 ...`.
- Plain snd_soc_get/put_volsw path == what the existing volume controls use.

### Build (out-of-tree)

Workdir `temp/build/tas2783/`: copy patched `tas2783-sdw.c` + `tas2783.h`, Makefile:

```make
obj-m := snd-soc-tas2783-sdw.o
snd-soc-tas2783-sdw-y := tas2783-sdw.o
```

```bash
make -C /usr/lib/modules/$(uname -r)/build M=$PWD modules
modinfo ./snd-soc-tas2783-sdw.ko | head   # sanity: vermagic matches
```

### Deploy

```bash
sudo install -Dm644 snd-soc-tas2783-sdw.ko \
  /usr/lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko
sudo depmod -a
modinfo -F filename snd_soc_tas2783_sdw   # must now point at updates/
```

Reload: try live first, reboot if it fights back:

```bash
systemctl --user stop wireplumber pipewire pipewire-pulse
sudo modprobe -r snd_acp_sdw_legacy_mach snd_soc_tas2783_sdw
sudo modprobe snd_soc_tas2783_sdw
sudo modprobe snd_acp_sdw_legacy_mach
systemctl --user start wireplumber pipewire pipewire-pulse
```

Rollback: `sudo rm /usr/lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko && sudo depmod -a` (stock module untouched).

### Test procedure

1. Confirm controls exist: `amixer -c1 controls | grep -i -E 'posture|cluster'`
2. Baseline check (expect posture=1 on both, from fallback init_seq):
   `amixer -c1 cget name='tas2783-1 DSP Posture Select'` (and -2)
3. Apply firmware-intended config:
   `amixer -c1 cset name='tas2783-2 DSP Posture Select' 4`
4. Channel check: `speaker-test -c2 -t wav` (announces "Front Left"/"Front Right");
   verify each side plays only its own channel and the L/R assignment is correct
   (left speaker = Front Left).
5. If no separation: sweep posture 0-15 on each amp; also try UDMPU Cluster = 1 on both
   (the ACPI DC value); record all observations in the investigation doc.
6. Check dmesg for SoundWire errors after each write (chip 0xb history).

Decision gate: identify the (register, value-per-amp) combo giving correct stereo.
Expected: posture amp1=1, amp2=4.

## Phase 2 - Proper fix: make the SDCA function parse succeed

Goal: the ACPI init tables get applied by the existing code, amps differentiated at boot
with no userspace involvement. This also exercises the full SDCA parse path (entities,
clusters, controls), taking us onto the intended upstream code path.

### Patch B: sdca_functions.c - function-type fallback in find_sdca_function()

Replace the `if (ret < 0) { dev_err(...); return ret; }` after the dc-value read (~line 137):

```c
	if (ret < 0) {
		/*
		 * Some firmware (e.g. ASUS ProArt PX13) declares Control 0x5
		 * as read-only hardware access without a DisCo constant.
		 * The TAS2783 (mfg 0x0102) only implements a SmartAmp
		 * function, so the type is known.
		 */
		if (slave->id.mfg_id == 0x0102 && slave->id.part_id == 0x0000) {
			function_type = SDCA_FUNCTION_TYPE_SMART_AMP;
		} else {
			dev_err(dev, "function type only supported as DisCo constant\n");
			return ret;
		}
	}
```

(interface revision 0x1000 makes patch_sdca_function_type a no-op; verify
SDCA_FUNCTION_TYPE_SMART_AMP in include/sound/sdca_function.h at build time.)

### Build

snd-soc-sdca is multi-object: fetch all of `sound/soc/sdca/` (Makefile + sources) for
v7.2-rc3, patch sdca_functions.c, build as external module, deploy to updates/ like Phase 1.

### Test procedure

1. Reboot (parse happens at ACPI scan / slave registration).
2. `journalctl -k -b | grep -i "SDCA function"` - expect
   `SDCA function SmartAmp (type 1) at 0x1` for device:26 AND device:28, and no
   "only supported as DisCo constant".
3. Watch for NEW downstream errors: entity/cluster/control parse, `sdca_regmap_write_init`
   failures, "smartamp function parse failed ... using defaults".
4. Verify posture registers WITHOUT manual csets:
   `amixer -c1 cget name='tas2783-2 DSP Posture Select'` -> expect 4 (Phase 1 module
   still installed gives us this visibility).
5. Full audio test: stereo separation, volume controls, suspend/resume cycle
   (regcache_sync must replay posture), several reboots for stability.
6. Regression watch: with sa_func_data set the driver skips tas2783_init_seq entirely
   (ACPI table writes 10 regs vs init_seq's 30). If audio degrades (volume/EQ/protection
   quirks), the RCA firmware blob + ACPI table were expected to cover it - document
   whatever differs.

Fallback if Phase 2 misbehaves beyond quick iteration: keep Phase 1 module and add the
per-amp posture defaults in the codec driver fallback path (write posture 4 when
unique_id == 0xb after init_seq) - local hack, but 3 lines and robust.

## Phase 3 - Persistence + upstream

1. **Persistence across kernel updates**: modules in `updates/` die with each kernel
   package update. Options (pick after Phase 2 results):
   - pacman hook that rebuilds + reinstalls both modules post kernel upgrade (DKMS-lite)
   - proper DKMS package
   - accept manual rebuild until upstream fix lands
2. **UCM**: only if Phase 2 is abandoned - add posture csets to Speaker EnableSequence
   (requires Phase 1 kcontrols present; csets on stock kernel would error).
3. **Upstream**: report to linux-sound with the firmware analysis; proposed shape is a
   quirk (sdca_device.c, Dell precedent) or the TAS2783 fallback from Patch B. Also
   report the missing DisCo constant to ASUS (BIOS fix would obsolete everything).
4. Update README with final solution; remove the pro-audio-profile-hack remnants if any.

## Open questions to resolve during execution

- Does posture 1/4 alone give correct L/R, or is UDMPU cluster also needed? (Phase 1 answers)
- Does the full SDCA parse succeed once the type is known? (Phase 2 answers)
- Does skipping init_seq in favor of the ACPI table regress anything? (Phase 2 step 6)
