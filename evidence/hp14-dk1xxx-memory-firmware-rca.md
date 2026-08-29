# HP 14-dk1xxx memory and firmware RCA

## Resolution

The two installed Crucial `CT16G4SFD8213.C16FAD` DIMMs are running at their
rated DDR4-2133 speed. The reported 933 MHz state was dynamic FCLK exposed
through the legacy `pp_dpm_mclk` filename, not the trained DRAM clock. No BIOS
flash or DIMM replacement is required to correct memory speed.

Both UMC channels provide the same direct hardware result:

- Register `0x50200` is `0x00000520` on both channels. Bits 7:0 are
  `0x20`, so `(32 / 3) x 200 = 2133.33 MT/s`.
- Register `0x50204` is `0x0f0f240f` on both channels. It decodes to tCL 15,
  tRCDRD 15, tRCDWR 15, and tRAS 36.
- Register `0x50208` is `0x000f0033` on both channels. It decodes to tRP 15
  and tRC 51.

Those timings match the fastest profile in both CRC-valid SPD EEPROMs. The
installed dual-rank, dual-channel population is not being derated to
DDR4-1866. The measured controller peak is `2 x 8 x 2133.33 = 34.13 GB/s`, so
the 15.44 GB/s two-thread host read is about 45% of peak.

Linux kernel `smu10_hwmgr.c` handles the `PP_MCLK` sysfs display by sending
`PPSMC_MSG_GetFclkFrequency`. That source path explains why the selected
933 MHz value can change without retraining DRAM. Retained Vulkan telemetry
contains selected 1067 MHz states, which also falsifies the earlier
"unreachable highest step" claim.

The read-only SMN probe was loaded only for the register capture. The retained
log proves that `ryzen_smu` was absent afterward and the AMDGPU performance
level remained `auto`.

## Firmware comparison

The HP F.69 and F.74 SoftPaqs were downloaded with a Mozilla user agent and
extracted offline. The hashes identify every external input and the Picasso
ROM selected from each package:

- F.69 `sp147034.exe`:
  `703e0a9e32e90a2df2aa7d96fd7de8ede1c1370d157406bd6db8ec0db2c8afab`
- F.69 `BIOS_02.bin`:
  `fde158c338c0a01ed9844771f3321bec7c91d2f8415fce1479be1850bd59e34a`
- F.69 `BIOS_02.sig`:
  `a69bf69848570f7e9afb2558b364b57156c9c42633089ad83d11cc8fd2f28c3b`
- F.74 `sp155974.exe`:
  `e1548d95903ccb8fa054c648c219b7398290ebb7b94ccd28b6cf9b4c00c7e216`
- F.74 `BIOS_02.bin`:
  `87e85c24cf7c09a36bc2532bedc385599450f98bf66960f6f9a0b2bec5d6d1a6`
- F.74 `BIOS_02.sig`:
  `4219a20f6c1be7b5b72dd182c7c3c5288dfef3163f1ecd6dbe7642d38d8983b8`
- F.74 `HpBiosUpdate.efi`:
  `7876851bddce1b5c9a5da87c765dba5a768f59e5bbae261d1562cc6228aa73a5`
- F.74 `CryptRSA.efi`:
  `e110d64c64fb9ff916cb47dda79de40cf9fc4ac3830eea9fbb7cee91d876fb1a`

F.69 contains `PicassoPI-FP5 1.0.0.E`; F.74 contains
`PicassoPI-FP5 1.0.1.2`. Changed memory-init PEI modules include
`AmdMemAm4ZpPei`, `AmdMemChanXLatZpPei`, `AmdMemoryHobInfoPeim`,
`AmdMemRestorePei`, `AmdMemSmbiosV2RvPei`, and `AmdMemoryInfo`. The DXE modules
`AmdMemAm4Dxe`, `AmdMemRestoreDxe`, and `AmdMemSmbiosV2RvDxe` are unchanged.
F.74 therefore contains a real AGESA and memory-init update, but it is not the
fix for this RCA: F.69 demonstrably trains the installed DIMMs at 2133 MT/s.

## Native firmware update paths

The live host runs fwupd 2.0.20 and exposes System Firmware through the
`uefi_capsule` plugin. Its ESRT GUID is
`d60df924-ec58-4ef8-bbbf-9cf34e766f74`; the device is updatable, requires AC,
requires a reboot, and supports verification. The ESP has 529,367,040 bytes
free and Secure Boot is disabled. Native UEFI capsule transport therefore
exists and is operational as a transport.

### LVFS through `fwupdmgr update`

LVFS is enabled, but `get-updates --json` returns no releases and the ESRT GUID
is absent from current metadata. This safe no-op cannot pull F.74 because HP has
not published a matching LVFS release. `fwupdmgr install` also does not turn the
HP SoftPaq into an LVFS release: HP supplies a Windows executable, raw ROMs, and
detached signatures rather than a fwupd cabinet with matching device metadata.

### Raw `fwupdtool install-blob`

fwupd 2.0.20 checks the first 16 bytes for the ESRT GUID and prepends a capsule
header when they differ. Do not use this path for extracted `BIOS_02.bin`; it
does not reproduce HP package model selection or detached-signature checks.

### HP F.74 Windows SoftPaq

HP's release document explicitly supports Windows 10 and 11 and runs the
signed HP update chain. This is the vendor-supported F.74 installation route.
The package can either prepare a direct BIOS update or create an HP BIOS
Recovery USB drive. Its embedded utility states that the recovery drive needs
at least 20 MB and a compatible FAT filesystem, and packages the signed HP EFI
updater, cryptographic verifier, ROM, and detached signature for target-side
execution. Recovery-media creation is therefore a vendor-supplied alternative
to keeping Windows installed on this laptop, but the creator itself remains a
Windows program and HP describes the media as a recovery path for corrupted
firmware rather than the normal F.74 update procedure.

### HP signed EFI updater

The updater with its matched image and signature performs system-ID, AC,
`$BID`, signature, write, and read-back checks. It is a technically viable
recovery or update component, but the SoftPaq does not document manual Linux
invocation and this RCA does not select that path.

The LVFS gzip metadata fetched during the final audit has SHA-256
`ef35117459e9e17920b03e767f8e68cc83f1371fef5a2f40f6883783ee427ee1`
and contains zero occurrences of the system-firmware ESRT GUID. The absence is
therefore a direct metadata result, not an inference from the empty update list.

The raw F.74 ROM begins with 16 `0xff` bytes, so fwupd would treat it as a
headerless payload and synthesize a generic capsule wrapper. The HP updater does
substantially more: it reads the SMBIOS system ID, selects the matching image,
checks AC power and `$BID`, loads the detached signature or its packaged
fallback, verifies through the HP BIOS Image Interface, writes, and verifies
blocks. A generic wrapper is not an equivalent security or compatibility
contract.

F.74 is a security update and its release document states that previous BIOS
versions cannot be reinstalled after it runs. Any independent decision to
install F.74 must therefore be treated as a one-way maintenance operation with
AC power and HP recovery media prepared first. This RCA does not authorize or
require that flash.

## Provenance and replay

External sources were accessed on 2026-08-26:

- HP F.69 package: <https://ftp.hp.com/pub/softpaq/sp147001-147500/sp147034.exe>
- HP F.74 package: <https://ftp.hp.com/pub/softpaq/sp155501-156000/sp155974.exe>
- HP F.74 release document: <https://ftp.hp.com/pub/softpaq/sp155501-156000/sp155974.html>
- BIOSUtilities commit `70c3a0852a6aa2643c8114ea73bc833e3b4cff0d`:
  <https://github.com/Platomav/BIOSUtilities/tree/70c3a0852a6aa2643c8114ea73bc833e3b4cff0d>
- fwupd 2.0.20 capsule fixup source:
  <https://github.com/fwupd/fwupd/blob/2.0.20/plugins/uefi-capsule/fu-uefi-capsule-device.c>
- Linux SMU10 FCLK query path:
  <https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/amd/pm/powerplay/hwmgr/smu10_hwmgr.c>
- TuxTimings DDR4 UMC decoder, commit
  `ffd12bf1ec5e9c2fbd31bde5a0208b9b4a9fd816`:
  <https://github.com/Death4two/TuxTimings/tree/ffd12bf1ec5e9c2fbd31bde5a0208b9b4a9fd816>
- ZenTimings channel-offset implementation, commit
  `0a6d07403f6ab562ef9b503e2ed50816acdddb29`:
  <https://github.com/irusanov/ZenTimings/tree/0a6d07403f6ab562ef9b503e2ed50816acdddb29>

Download replay uses `wget` with the requested browser user agent:

```sh
wget --user-agent='Mozilla/5.0' \
    https://ftp.hp.com/pub/softpaq/sp147001-147500/sp147034.exe
wget --user-agent='Mozilla/5.0' \
    https://ftp.hp.com/pub/softpaq/sp155501-156000/sp155974.exe
```

The private raw SPD, SMBIOS, and ACPI captures remain in the ignored local
`evidence/hp14-dk1xxx-memory-configuration/` directory because they contain
module serial numbers and machine identifiers. Their local `SHA256SUMS` file
retains exact identity without publishing those blobs.
