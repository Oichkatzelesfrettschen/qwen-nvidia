# Graphics Stack Admission Evidence

## Observed package authority

Linux Mint 22.2 uses the Ubuntu Noble package base on the laptop. The enabled
graphics source is already the public `Mesa Almost Stable` PPA:

- Archive: https://launchpad.net/~ernstp/+archive/ubuntu/mesarc
- Automation source: https://github.com/ernstp/ppa-mesarc
- Configured signing fingerprint:
  `F7D9F0EAA92354B674013D4523A159D3E514D90F`
- Fingerprint reported by Launchpad:
  `F7D9F0EAA92354B674013D4523A159D3E514D90F`
- Installed and candidate Mesa after the 2026-08-24 user transaction:
  `26.2.1+git2608201115.88947685514~n~mesarc0`
- Installed libdrm:
  `2.4.134+git2607282030.82f74e7a~n~mesarc2`

The source-list and keyring files are owned by `root:root`, mode `0644`. The
source-list SHA-256 is
`c62e0adf751a12e16f0ebfdc7190dcc84f4a71ad714869ad802a80e267dd2da8`.
The keyring SHA-256 is
`695767a21aa72a0ba4801929dfb847b8a4bf9c9e6205287ce435514f753d6640`.

## Source provenance

Launchpad published the Noble 26.2.1 source on 2026-08-20 and built amd64,
arm64, and i386 successfully. The signed DSC names source commit
`889476855143e855a7f92989251f09fb3b690cda`, which resolves in the upstream
Mesa repository:

- Source publication:
  https://launchpad.net/~ernstp/+archive/ubuntu/mesarc/+sourcepub/18687131
- Upstream commit:
  https://gitlab.freedesktop.org/mesa/mesa/-/commit/889476855143e855a7f92989251f09fb3b690cda
- Source tarball SHA-256:
  `bda72b0751f46668cca239a5d3f913a4e52e27559dfc654f8ace946116175339`

The PPA's Noble quilt series is empty. Its packaging enables the `amd` Vulkan
driver and uses LLVM 19. The public automation checkout still names
`staging/26.1` in `mesa-git/settings2.sh`, while the signed published source is
26.2.1. The signed Launchpad DSC, source tarball, build record, and upstream
commit therefore form the authoritative chain for the candidate package.

## Credible Noble tracks

| Track | Published Noble Mesa | Policy and consequence |
|---|---|---|
| Ubuntu Noble updates | 25.2.8 | Distribution-supported baseline and lowest package churn. |
| Kisak fresh | 26.1.7 | Latest point release plus selected non-invasive backports. Noble is supported. |
| Ernst mesarc | 26.2.1 | Release candidates and release branches. It is already installed and is the freshest active track examined. |
| Oibaf | No active Noble package | The archive reports suspension in 2026; its last Noble 25.0 publication is deleted. |

Primary archive descriptions:

- Kisak: https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa
- Oibaf: https://launchpad.net/~oibaf/+archive/ubuntu/graphics-drivers

Adding Kisak or Oibaf alongside mesarc creates competing origins for Mesa,
libdrm, and related ABI-coupled libraries. It does not increase the kernel's
GTT domain or physical UMA capacity. A second graphics PPA is rejected.

## Candidate transaction

An unprivileged `apt-get -s` simulation for the installed Mesa family upgrades
11 amd64 packages from the same mesarc source version. It reports zero new
packages and zero removals:

- `libegl-mesa0`
- `libegl1-mesa-dev`
- `libgbm1`
- `libgl1-mesa-dev`
- `libgl1-mesa-dri`
- `libglx-mesa0`
- `mesa-common-dev`
- `mesa-drm-shim`
- `mesa-libgallium`
- `mesa-va-drivers`
- `mesa-vulkan-drivers`

The host enables i386 as a foreign architecture but has no installed i386 Mesa
packages in the audited set. The transaction therefore remains amd64-only.

The coherence audit found one obsolete desktop package. Ubuntu's
`mesa-vdpau-drivers` 25.2.8 installs
`libvdpau_radeonsi.so.1.0.0` as a link to
`libgallium-25.2.8-0ubuntu0.24.04.2.so`, which does not exist after the mesarc
Mesa 26 transition. Upstream Mesa 26 no longer contains the Gallium VDPAU
frontend, so neither mesarc 26.2.1 nor Kisak 26.1.7 supplies a replacement
VDPAU link. The installed package has no installed reverse dependencies, and
an APT removal simulation removes only `mesa-vdpau-drivers`.

The supported AMD media path remains healthy through VA-API. A headless DRM
probe opens the mesarc 26.2.0 `radeonsi_drv_video.so` on `renderD128` and
reports hardware decode profiles for H.264, HEVC Main/Main10, VP9 Profile 0/2,
MPEG-2, VC-1, and JPEG, plus H.264 and HEVC encoding. Removing the dangling
VDPAU package is the coherent repair after sudo is refreshed; creating an
unowned compatibility symlink would preserve a removed frontend contract and
is rejected.

The 26.2.1 changelog contains three RADV gang synchronization changes and two
other RADV fixes. None names Raven2, UMA heap sizing, global queue priority, or
ordinary Vulkan compute allocation. The point update may improve correctness,
but the evidence does not predict more usable VRAM or a llama.cpp throughput
increase.

## Admission decision

Keep mesarc as the sole graphics PPA. The planned Mesa 26.2.0 baseline was
superseded when the user installed the 26.2.1 transaction on 2026-08-24. The
post-transaction headless check still selects RADV Raven2, but the complete
desktop, media, suspend, heap, and compute validation remains required before a
model benchmark treats 26.2.1 as the stable baseline.

The rollback command shape is
`ppa-purge -d noble ppa:ernstp/mesarc`, followed by verification that every
Mesa and libdrm package resolves to one coherent Ubuntu origin. The command is
recorded as a plan and has not been run.

## Post-transaction OpenCL finding

The same user transaction installed mesarc's `mesa-opencl-icd` 26.2.1,
`libclc-19`, the Khronos headers and loader, and `clinfo`. The ICD package
declares `Provides: opencl-icd` but has an installed size of 339 KiB and contains
only `/usr/share/bug` and `/usr/share/doc`. It installs no library and no file in
`/etc/OpenCL/vendors`. `clinfo -l` therefore exposes zero platforms.

This is a mesarc package-content defect, not an account-permission failure. The
Ubuntu 25.2.8 package contains an approximately 39 MiB OpenCL implementation,
but substituting that single older Mesa runtime into the 26.2.1 graphics stack
would create an unvalidated mixed-source backend. An exact-source Rusticl build
could preserve the desktop libraries, but the pinned llama.cpp OpenCL backend
rejects every GPU family except Adreno and Intel. Raven2 requires backend
implementation and operation evidence before an isolated ICD becomes useful.

The transaction also reinstalled Ubuntu's `mesa-vdpau-drivers` 25.2.8. Its
`libvdpau_radeonsi` links still target the absent
`libgallium-25.2.8-0ubuntu0.24.04.2.so`. A fresh removal simulation removes only
that package. The retained package-removal task remains the coherent repair.

## Kernel state

The running kernel is `7.0.0-28-generic`. Signed HWE kernels
`7.0.0-29-generic` and `6.14.0-29-generic` remain installed, and APT offers
`7.0.0-30.30~24.04.1`. Secure Boot is disabled and the platform reports Setup
Mode. Kernel admission remains separate from Mesa admission because the kernel
owns amdgpu memory management, scheduling, display, suspend, and firmware
submission while RADV owns Vulkan userspace behavior.

The machine booted `7.0.0-28` on 2026-08-15. A normal APT upgrade installed
`7.0.0-29` on 2026-08-17, after that boot, so `-29` has not been exercised.
No DKMS modules are registered. Complete image, module, header, and initramfs
sets exist for `7.0.0-28`, `7.0.0-29`, and the retained `6.14.0-29` fallback.
Residual configuration records remain for several removed 6.17 kernels, but
their images and modules are absent.

The `7.0.0-29` Ubuntu changelog contains security fixes and removes a retry
loop in `amdgpu_hmm_range_get_pages` that caused an approximately 42-fold SDXL
regression. llama.cpp's RADV Vulkan path does not use the KFD/HMM allocation
path, so this entry does not predict a Vulkan speedup. It still warrants
testing `-29` at the next user-approved maintenance reboot because the kernel
is already installed.

The `7.0.0-30` delta contains one Open vSwitch CVE fix. Open vSwitch is not
installed and its module is not loaded. The delta contains no listed amdgpu,
DRM, memory, scheduler, display, suspend, or firmware change. Installing `-30`
would add six packages and upgrade three HWE metapackages, but it has no
demonstrated benefit for the Raven2 workload. It remains deferred.

The root filesystem has approximately 1.6 TiB free, and the EFI system
partition has approximately 505 MiB free. SHA-256 hashes were captured for all
three initramfs files and the readable 6.14 kernel image. The 7.0 kernel images
and GRUB configuration require the inactive sudo timestamp for hashes and menu
proof.

Kernel admission therefore uses the already-installed `7.0.0-29` as the sole
next comparator. A user-approved reboot must retain `7.0.0-28` and
`6.14.0-29`, capture the new boot ID and kernel log, and rerun desktop,
offscreen RADV, heap, media, suspend, and hazard probes. `7.0.0-30` remains
outside the experiment until a security exposure or Raven2-relevant change
justifies another variable.
