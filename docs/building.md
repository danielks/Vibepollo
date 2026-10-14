# Building
Sunshine binaries are built using [CMake](https://cmake.org) and requires `cmake` > 3.25.
The browser interface is built with Node.js and npm. CMake's `web_ui` target
installs the locked dependencies with lifecycle scripts disabled, generates the
design tokens, type-checks the Vue source, and writes the production bundle to
`<build-dir>/assets/web`. The `sunshine` target and installer packaging depend on
this target, and packaging fails rather than shipping an incomplete
configuration interface.

For frontend-only development, run `npm ci --ignore-scripts` and `npm run dev`
from `src_assets/common/assets/web`. Use `npm run build` for a production bundle.

## Building Locally

### Compiler
It is recommended to use one of the following compilers:

| Compiler    | Version |
|:------------|:--------|
| GCC         | 14+     |
| Clang       | 17+     |
| Apple Clang | 15+     |

### Linux release CUDA compatibility

Linux release packages pin CUDA Toolkit **12.9.1** (runfile build **575.57.08**)
to retain Maxwell, Pascal (including GTX 1070), and Volta GPU targets. CUDA 13
cannot compile those targets. Use GCC 14 as the CUDA host compiler; older
supported builders may use GCC 13. The runfile installs only the toolkit,
not a GPU driver.

The shared Linux build script uses the pinned runfile in `build/cuda` by
default, ignoring a newer system toolkit. It rejects an incompatible cached
toolkit. Arch's PKGBUILD downloads architecture-specific, SHA-256-verified
runfiles into its source directory and explicitly selects GCC 14. Arch CI
installs the signed, versioned GCC 14 packages from the Arch Linux Archive,
because rolling Arch repositories no longer provide them. Manual Arch package
builds also need the `gcc14` build dependency installed.

Release packaging enables `SUNSHINE_REQUIRE_CUDA_PASCAL=ON`, which requires
CUDA 12.9 and the `sm_61` target. Flatpak retains its existing 12.9.1 pin.
When changing toolchain versions, run
`python3 tests/unit/test_cuda_release_policy.py` and build the affected
packages locally before publishing. Developer builds can leave that option
off to use newer CUDA toolkits with a reduced set of GPU targets.

### Dependencies

#### FreeBSD
> [!CAUTION]
> Sunshine support for FreeBSD is experimental and may be incomplete or not work as expected

##### Install dependencies
```sh
pkg install -y \
  audio/opus \
  audio/pulseaudio \
  devel/cmake \
  devel/evdev-proto \
  devel/git \
  devel/libayatana-appindicator \
  devel/libevdev \
  devel/libnotify \
  devel/ninja \
  devel/pkgconf \
  ftp/curl \
  graphics/libdrm \
  graphics/wayland \
  multimedia/libva \
  net/miniupnpc \
  ports-mgmt/pkg \
  security/openssl \
  shells/bash \
  x11/libX11 \
  x11/libxcb \
  x11/libXfixes \
  x11/libXrandr \
  x11/libXtst
```

#### Linux
Dependencies vary depending on the distribution. You can reference our
[linux_build.sh](https://github.com/LizardByte/Sunshine/blob/master/scripts/linux_build.sh) script for a list of
dependencies we use in Debian-based, Fedora-based and Arch-based distributions. Please submit a PR if you would like to extend the
script to support other distributions.

##### KMS Capture
Do **not** add file capabilities to the `vibepollo` binary. On Linux the public `/usr/bin/vibepollo`
must stay unprivileged; KMS capture runs inside the private `/usr/libexec/vibeshine/vibepollo-host`,
which the package installs with exactly `cap_sys_admin,cap_sys_nice=p`, and the package hook
verifies that the public binary has no capabilities. Install through the Arch package (or follow the
staged-install recipe in `AGENTS.md`) rather than running a capability-patched build directly.

##### CUDA Toolkit
CUDA-enabled builds require CUDA Toolkit **12.0 or newer**. The native
[local build/deploy script](linux/local-development.md#build-settings) uses an
installed toolkit and compiler; it does not pin CUDA 13 or GCC 15. Choose a
host compiler supported by that toolkit and a C++ compiler/standard library
that meets the project's C++23 requirements.

The selected toolkit determines which GPU generations can be targeted. Release
packages deliberately use **CUDA 12.9.1 with GCC 14**, as described above, to
cover both older and newer GPUs. This release pin is not the minimum for local
builds. CUDA 13 removes compilation support for Maxwell, Pascal, and Volta;
upgrading the toolkit can therefore reduce GPU compatibility. See NVIDIA's
[CUDA 13 release notes](https://docs.nvidia.com/cuda/archive/13.0.0/cuda-toolkit-release-notes/index.html)
and [CUDA compatibility guide](https://docs.nvidia.com/deploy/cuda-compatibility/index.html).

The native Arch/CachyOS release package uses a private build-time toolkit and
does not require users to install the CUDA toolkit to run Vibepollo.

> [!NOTE]
> To install older versions, select the appropriate run file based on your desired CUDA version and architecture
> according to [CUDA Toolkit Archive](https://developer.nvidia.com/cuda-toolkit-archive)

#### macOS
The native host requires macOS 14.2 or newer for Core Audio process taps.
Build on the target architecture using the Xcode Command Line Tools, Homebrew,
and Node.js/npm for the web UI. Apple Silicon is the locally validated path;
the macOS workflow also builds a separate Intel artifact.

##### Homebrew
From the repository root:

```bash
bash scripts/macos_build.sh --step=deps
bash scripts/macos_build.sh --step=cmake
bash scripts/macos_build.sh --step=build
bash scripts/macos_build.sh --step=test
build/macos/Vibepollo.app/Contents/MacOS/Vibepollo
```

The script uses AppleClang, Ninja, pinned Boost sources, and the prepared
FFmpeg archive. It initializes only the submodules needed by the host; the
nested FFmpeg source checkouts inside `build-deps` are unnecessary. WebRTC and
the PyroWave host backend remain disabled on macOS.

Local builds default to the current macOS version because Homebrew libraries
may require that version. `MACOSX_DEPLOYMENT_TARGET=14.2` is appropriate only
when **all** dependencies were built for 14.2 or earlier; the compiler flag
alone does not make a newer Homebrew installation compatible with older Macs.
`VIBEPOLLO_BUILD_DIR` overrides the build directory.

To create a self-contained app with bundled dynamic libraries and an ad-hoc
signature, without an Apple Developer account:

```bash
cmake --install build/macos --prefix "$PWD/build/macos/package" --component Runtime
```

The resulting `build/macos/package/Vibepollo.app` can be opened in Finder.
Opening the bundle launches the configuration page in the default browser
after the HTTPS listener is ready. Opening it again while it is running also
opens that page. The host stays in the menu bar and has no separate main window.
`bash scripts/macos_build.sh --step=dmg` additionally creates a disk image.
Distribution with Developer ID signing requires `APPLE_CODESIGN_IDENTITY`;
notarization is opt-in with `--notarize` and the `notarytool-password` keychain
profile. Ad-hoc signing is for local use and does not replace notarization.

On first launch, open `https://127.0.0.1:47990` and create the local web login.
The host uses a self-signed certificate. In System Settings → Privacy & Security,
enable Vibepollo in Screen & System Audio Recording and Accessibility, then
relaunch the app. The web UI can run before capture permission is granted;
that alone does not validate a working video stream. Pair a Moonlight/Artemis
client and verify video, system audio, mouse and keyboard after granting access.
Virtual gamepads and virtual displays are not implemented by this macOS backend.

Local validation (2026-10-14, M1 Pro, macOS 26.6.2): the packaged ARM64 app
starts, discovers the display, serves the web UI, and captures/encodes frames
with H.264 and HEVC VideoToolbox, including HEVC 10-bit. Its ad-hoc signature
and bundled library dependencies pass verification. The configured suite has
89 passing tests and one skipped Playnite/.NET test; two Windows CRT emulation
fixtures are excluded on Darwin. End-to-end client playback, system audio and
remote input still require a paired-client test.

##### PyroWave GPU diagnostic

The standalone diagnostic keeps codec compatibility work separate from capture
and the host's encoder selection. It uses the actual vendored GPU codec through
MoltenVK, starting with CPU buffers for upload/readback, packetizing the output,
and comparing a decoded test frame with its input.

```bash
brew install molten-vk
cmake -S tools/pyrowave_macos_probe -B build/pyrowave-probe -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/pyrowave-probe -j 4
GRANITE_VULKAN_LIBRARY="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib" \
  ctest --test-dir build/pyrowave-probe --output-on-failure
```

Exit code 77 means no Vulkan device was available; a codec failure returns 1.
A successful Vulkan device creation is not sufficient to enable the encoder.
On the tested M1 Pro with MoltenVK 1.4.2, device creation succeeds, but the
encoder is rejected: the driver reports a subgroup range of 4–32 and
`requiredSubgroupSizeStages=0`, while the current codec requires explicitly
selectable full subgroups of 16, 32 or 64 lanes. Do not enable the host or remove
that check until the shaders and subgroup selection have a verified Apple path.
The next integration steps are to pass this roundtrip on Apple GPUs, implement
the macOS `pyrowave::host` adapter, convert captured BGRA/NV12 frames, and verify
negotiation and streaming with a PyroWave-capable client. Shared IOSurface/Metal
interop and latency optimization follow a working upload-based path.

##### MacPorts
```bash
dependencies=(
  "cmake"
  "curl"
  "doxygen"  # Optional, for docs
  "graphviz"  # Optional, for docs
  "libopus"
  "miniupnpc"
  "ninja"
  "pkgconfig"
)
sudo port install "${dependencies[@]}"
```

#### Windows

> [!WARNING]
> Cross-compilation is not supported on Windows. You must build on the target architecture.

First, you need to install [MSYS2](https://www.msys2.org).

For AMD64 startup "MSYS2 UCRT64" (or for ARM64 startup "MSYS2 CLANGARM64") then execute the following commands.

##### Update all packages
```bash
pacman -Syu
```

##### Set toolchain variable
For UCRT64:
```bash
export TOOLCHAIN="ucrt-x86_64"
```

For CLANGARM64:
```bash
export TOOLCHAIN="clang-aarch64"
```

##### Install dependencies
```bash
dependencies=(
  "git"
  "mingw-w64-${TOOLCHAIN}-boost"  # Optional
  "mingw-w64-${TOOLCHAIN}-cmake"
  "mingw-w64-${TOOLCHAIN}-cppwinrt"
  "mingw-w64-${TOOLCHAIN}-curl-winssl"
  "mingw-w64-${TOOLCHAIN}-doxygen"  # Optional, for docs... better to install official Doxygen
  "mingw-w64-${TOOLCHAIN}-graphviz"  # Optional, for docs
  "mingw-w64-${TOOLCHAIN}-libjpeg-turbo"
  "mingw-w64-${TOOLCHAIN}-libpng"
  "mingw-w64-${TOOLCHAIN}-libwebp"
  "mingw-w64-${TOOLCHAIN}-miniupnpc"
  "mingw-w64-${TOOLCHAIN}-onevpl"
  "mingw-w64-${TOOLCHAIN}-openssl"
  "mingw-w64-${TOOLCHAIN}-opus"
  "mingw-w64-${TOOLCHAIN}-toolchain"
)
if [[ "${MSYSTEM}" == "UCRT64" ]]; then
  dependencies+=(
    "mingw-w64-${TOOLCHAIN}-MinHook"
    "mingw-w64-${TOOLCHAIN}-nsis"
  )
fi
pacman -S "${dependencies[@]}"
```

##### WebRTC (optional, Windows only)
Sunshine can link against the libwebrtc C++ wrapper when `SUNSHINE_ENABLE_WEBRTC=ON`. The wrapper source is vendored as
the `third-party/libwebrtc` submodule, but you must build WebRTC separately and provide a staging directory that
contains `include/` and `lib/` (e.g., `libwebrtc.dll` and its import library). We use the `third-party/depot_tools`
submodule for `gclient`/`gn`.

###### Quickstart (recommended)
A helper script automates the full depot_tools / gclient / gn / ninja flow:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_mingw_webrtc.ps1
```

By default the script builds under `%LOCALAPPDATA%\Vibepollo\deps\libwebrtc\src`, stages the reusable SDK under
`%LOCALAPPDATA%\Vibepollo\deps\libwebrtc\out`, and removes the large source workspace only after verifying the
staged headers, DLL, import library, and completed-build DLL identity. The retained `out` directory is **shared
across every Vibepollo build dir, worktree, and git checkout on the machine**. This means:

- Wiping `build/` does not destroy libwebrtc — the next CMake configure picks it back up.
- A successful local dependency build does not leave the multi-gigabyte Chromium/WebRTC source and Git cache behind.
- A failed build retains its source workspace for diagnosis and retry.
- Multiple Vibepollo build dirs share one small staged libwebrtc SDK.

Pass `-RetainBuildSources` while actively iterating on WebRTC itself. `-Stage Sync` always retains sources because
its purpose is to prepare a later `-Stage Build`; a successful `All` or `Build` stage cleans sources by default.
Explicit `WEBRTC_GIT_CACHE_DIR` or `WEBRTC_DEPOT_TOOLS_DIR` paths outside `WEBRTC_BUILD_DIR` are treated as shared
external caches and are not removed.

`cmake/dependencies/webrtc.cmake` looks at the same default location, so no `-DWEBRTC_ROOT=...` is needed after the
first build. To relocate the cache, set `VIBEPOLLO_DEPS_DIR=<path>` in your environment before invoking either the
script or CMake.

For finer control the script accepts overrides via `-BuildDir`/`-OutDir` parameters or the legacy
`WEBRTC_BUILD_DIR` / `WEBRTC_OUT_DIR` env vars (these still take precedence if set).

###### Manual build (advanced / first-time porting)

If you cannot use the helper script, the underlying steps are:

1. Create a checkout directory and add a `.gclient` that points to
   `https://github.com/webrtc-sdk/webrtc.git@m137_release` with `target_os = ['win']`.
2. Run `gclient sync`.
3. In `src`, add the libwebrtc sources (you can copy or link `third-party/libwebrtc` into `src/libwebrtc`).
4. Apply the audio patch:
   `git apply libwebrtc/patchs/custom_audio_source_m137.patch`
5. Update `src/BUILD.gn` to include `//libwebrtc` in `group("default")`.
6. Generate and build (adjust `GYP_MSVS_OVERRIDE_PATH` if Visual Studio is installed elsewhere; our local install is
   under `D:\Software\Visual Studio`):
   ```bash
   set PATH=D:\sources\sunshine\third-party\depot_tools;%PATH%
   set DEPOT_TOOLS_WIN_TOOLCHAIN=0
   set GYP_MSVS_VERSION=2022
   set GYP_GENERATORS=ninja,msvs-ninja
   set GYP_MSVS_OVERRIDE_PATH=D:\Software\Visual Studio
   set vs2022_install=D:\Software\Visual Studio
   set WINDOWSSDKDIR=D:\Software\WinSDK
   cd src
   gn gen out-debug/Windows-x64 --args="target_os=\"win\" target_cpu=\"x64\" is_component_build=false is_clang=true is_debug=true rtc_use_h264=true ffmpeg_branding=\"Chrome\" rtc_include_tests=false rtc_build_examples=false libwebrtc_desktop_capture=true" --ide=vs2022
   ninja -C out-debug/Windows-x64 libwebrtc
   ```
7. Stage the artifacts into a directory with `include/` and `lib/` subfolders. Either place them at the default
   shared cache location (`%LOCALAPPDATA%\Vibepollo\deps\libwebrtc\out`) so CMake finds them automatically, or
   point CMake at your staging directory with `-DWEBRTC_ROOT=<path>`. Copy `libwebrtc.dll` and `libwebrtc.dll.lib`
   into `lib/`.
8. Configure Sunshine with `-DSUNSHINE_ENABLE_WEBRTC=ON`. If CMake still fails to find libwebrtc, pass
   `WEBRTC_INCLUDE_DIR` and `WEBRTC_LIBRARY` explicitly.

The Windows build requires the [.NET SDK](https://dotnet.microsoft.com/download)
to compile the bundled Playnite plugin. It is also used when creating a WiX installer.

### Clone
Ensure [git](https://git-scm.com) is installed on your system, then clone the repository using the following command:

```bash
git clone https://github.com/ClassicOldSong/Apollo.git --recurse-submodules
cd Apollo
mkdir build
```

### Build

```bash
cmake -B build -G Ninja -S .
ninja -C build
```

> [!TIP]
> Available build options can be found in
> [options.cmake](https://github.com/LizardByte/Sunshine/blob/master/cmake/prep/options.cmake).

### Package

@tabs{
  @tab{FreeBSD | @tabs{
    @tab{pkg | ```bash
      cpack -G FREEBSD --config ./build/CPackConfig.cmake
      ```}
  }}
  @tab{Linux | @tabs{
    @tab{deb | ```bash
      cpack -G DEB --config ./build/CPackConfig.cmake
      ```}
    @tab{rpm | ```bash
      cpack -G RPM --config ./build/CPackConfig.cmake
      ```}
  }}
  @tab{macOS | @tabs{
    @tab{DragNDrop | ```bash
      cpack -G DragNDrop --config ./build/CPackConfig.cmake
      ```}
  }}
  @tab{Windows | @tabs{
    @tab{Installer | ```bash
      cpack -G WIX --config ./build/CPackConfig.cmake
      # note: MSI packaging requires WiX Toolset v3 to be installed (e.g. `choco install wixtoolset`)
      ```}
    @tab{WiX Installer | ```bash
      cpack -G WIX --config ./build/CPackConfig.cmake
      ```}
    @tab{Portable | ```bash
      cpack -G ZIP --config ./build/CPackConfig.cmake
      ```}
  }}
}

### Remote Build
It may be beneficial to build remotely in some cases. This will enable easier building on different operating systems.

1. Fork the project
2. Activate workflows
3. Trigger the *CI* workflow manually
4. Download the artifacts/binaries from the workflow run summary

<div class="section_buttons">

| Previous                              |                            Next |
|:--------------------------------------|--------------------------------:|
| [Troubleshooting](troubleshooting.md) | [Contributing](contributing.md) |

</div>

<details style="display: none;">
  <summary></summary>
  [TOC]
</details>

### CUDA compatibility for scripted Linux builds

`scripts/linux_build.sh` pins CUDA 12.9.1 and a compatible host compiler to
retain Maxwell, Pascal (including GTX 10-series), and Volta targets. It rejects
incompatible cached toolkits before configuration. Direct CMake builds may
still use newer CUDA with `SUNSHINE_REQUIRE_CUDA_PASCAL=OFF` (the default);
CUDA 13 builds omit those older GPU targets. Set the option to `ON` when
producing a Pascal-compatible build with CUDA 12.9. This does not enable Linux
release publishing in Vibepollo's Windows release workflow.
