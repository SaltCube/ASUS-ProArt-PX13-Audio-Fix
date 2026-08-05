# Kernel fix plan

The shipped fix works around the bug from userspace: two kcontrols added to the
codec module, written by UCM. This document covers the outstanding work, which
is to fix it in the kernel so no patched module or UCM sequence is needed.

Root cause, in one paragraph: ASUS firmware declares the SDCA function type
without a DisCo constant, so `find_sdca_function()` bails, the per-amp ACPI
initialization tables are never applied, and both amps are left with the same
DSP posture instead of 1 and 4. Evidence in
[investigation-log.md](investigation-log.md), current understanding in
[analysis.md](analysis.md).

What is already done: the kcontrols (Phase 1, validated 2026-07-18), the UCM
posture sequence, and a pacman hook that rebuilds the module across kernel
upgrades. Those are described in the log and installed by the repo.

## Make the SDCA function parse succeed

Goal: the ACPI initialization tables get applied by existing kernel code, the
amps differentiate themselves at boot, and userspace does nothing. This also
exercises the whole SDCA parse path (entities, clusters, controls) rather than
stopping at the function type.

### The change

In `find_sdca_function()` in `sound/soc/sdca/sdca_functions.c`, the read of the
function type currently fails hard. Replace that error path with a fallback for
this device:

```c
	if (ret < 0) {
		/*
		 * Some firmware (ASUS ProArt PX13 among them) declares
		 * Control 0x5 as read-only hardware access with no DisCo
		 * constant. The TAS2783 (mfg 0x0102) implements only a
		 * SmartAmp function, so the type is known regardless.
		 */
		if (slave->id.mfg_id == 0x0102 && slave->id.part_id == 0x0000) {
			function_type = SDCA_FUNCTION_TYPE_SMART_AMP;
		} else {
			dev_err(dev, "function type only supported as DisCo constant\n");
			return ret;
		}
	}
```

Supporting facts:

- The amps are `sdw:0:1:0102:0000:01:8` and `sdw:0:1:0102:0000:01:b`; the driver
  matches `SDW_SLAVE_ENTRY(0x0102, 0x0000, 0)`, and `find_sdca_function()` has
  `slave` in scope via `container_of`.
- `mipi-sdw-sdca-interface-revision` is `0x1000`, which is at least `0x0801`, so
  `patch_sdca_function_type()` is a no-op and the fallback can simply assign.
- Verify `SDCA_FUNCTION_TYPE_SMART_AMP` still exists in
  `include/sound/sdca_function.h` at build time.
- Precedent for quirking function-type problems:
  `sdca_device_quirk_skip_func_type_patching()` in `sdca_device.c`, used for
  Dell SKUs 0C62/0C63/0C6B with the Cirrus CS42L43.

### Building it

`snd-soc-sdca` is a multi-object module, so the whole of `sound/soc/sdca/`
(Makefile and sources) is needed for the running kernel version, with
`sdca_functions.c` patched. Build out of tree and install to `updates/` the same
way the codec module is built:

```fish
make -C /usr/lib/modules/$(uname -r)/build M=$PWD LLVM=1 modules
sudo install -Dm644 snd-soc-sdca.ko /usr/lib/modules/$(uname -r)/updates/snd-soc-sdca.ko
sudo depmod $(uname -r)
```

`LLVM=1` is required: CachyOS kernels are clang-built, and a gcc build produces
a module the kernel will refuse.

### Testing it

1. Reboot; the parse happens at ACPI scan and slave registration.
2. `journalctl -k -b | grep -i "SDCA function"` should report
   `SDCA function SmartAmp (type 1) at 0x1` for both `device:26` and
   `device:28`, with no "function type only supported as DisCo constant".
3. Watch for new downstream failures that the old error hid: entity, cluster and
   control parsing, `sdca_regmap_write_init()`, or a "smartamp function parse
   failed, using defaults" message.
4. Read the postures without writing them. With the Phase 1 kcontrols still
   installed for visibility, `amixer -c amdsoundwire cget name='tas2783-2 DSP
   Posture Select'` should already be 4.
5. Then the full check: `./install.sh --check`, several reboots for stability.
6. Regression watch: with `sa_func_data` set, the driver skips
   `tas2783_init_seq` entirely, so 10 registers from the ACPI table replace 30
   from the fallback sequence. If volume, EQ or speaker protection behave
   differently, the RCA firmware blob and ACPI table were expected to cover
   that; document whatever differs.

If this misbehaves beyond quick iteration, the cheap alternative is to keep the
current module and set the posture in the codec driver's fallback path directly:
write posture 4 when `unique_id == 0xb` after `init_seq`. Three lines, robust,
and a local hack rather than something upstreamable.

## Upstreaming

1. **Kernel**: report to linux-sound with the firmware analysis. The likely
   shapes are a quirk in `sdca_device.c` following the Dell precedent, or the
   fallback above.
2. **alsa-ucm-conf**: no release ships `sof-soundwire/tas2783.conf`, so any
   machine whose CardComponents reports `spk:tas2783` gets no UCM devices at
   all. The file in this repo is a candidate.
3. **ASUS**: report the missing DisCo constant. A firmware fix would make all of
   the above unnecessary.

The suspend and resume failure is a separate upstream matter; see
[analysis.md](analysis.md). The captured log referenced by the 2026-07-19 entry
in the investigation log is the evidence for that report, and it lives outside
this repo.

## Open questions

- Does the full SDCA parse succeed once the type is known, or does it fail
  further along on this firmware?
- Does using the ACPI table instead of `init_seq` regress anything audible?
