#!/usr/bin/env bash
# Note: This script is not used by CI, and is only for manually building/signing the .app.
# Changes made to this script should also be made in ci-macos.yml.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "$script_dir/.." && pwd)"
build_dir="${VIBEPOLLO_BUILD_DIR:-$source_dir/build/macos}"
cd "$source_dir"

# Default value for arguments
num_processors=$(sysctl -n hw.ncpu)
publisher_name="Nonary"
publisher_website="https://github.com/Nonary/Vibepollo"
publisher_issue_url="https://github.com/Nonary/Vibepollo/issues"
step="all"
build_docs="OFF"
build_type="Release"
sign_app="${APPLE_CODESIGN_IDENTITY:-}"
notarize=""
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion)}"

# environment variables
# BUILD_VERSION should be empty or cmake will assume a CI build
BUILD_VERSION=""
BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git rev-parse --short HEAD)

export BUILD_VERSION
export BRANCH
export COMMIT

# boost could be included here but cmake will build the right version we need
required_formulas=(
  "cmake"
  "ninja"
  "node"
  "pkgconf"
  "icu4c@78"
  "miniupnpc"
  "openssl@3"
  "opus"
  "libpng"
  "jpeg-turbo"
  "webp"
)

function _usage() {
  local exit_code=$1

  cat <<EOF
This script builds a macOS .app bundle packaged inside a .dmg.

If the environment variable APPLE_CODESIGN_IDENTITY is set, the app will be signed.
This must be a "Developer ID" identity.

For others to be able to open the .dmg, it must be notarized. Create a keychain profile named
"notarytool-password" based on the instructions at
https://developer.apple.com/documentation/security/customizing-the-notarization-workflow?language=objc

Usage:
  $0 [options]

Options:
  -h, --help               Display this help message.
  --num-processors         The number of processors to use for compilation. Default: ${num_processors}.
  --publisher-name         The name of the publisher (not developer) of the application.
  --publisher-website      The URL of the publisher's website.
  --publisher-issue-url    The URL of the publisher's support site or issue tracker.
                           If you provide a modified version of Sunshine, we kindly request that you use your own url.
  --step=STEP              Which step(s) to run: deps, cmake, build, test, dmg, or all (default: all)
  --debug                  Build in debug mode.
  --build-docs             Build docs.
  --skip-codesign          Don't sign/notarize the bundle.
  --skip-notarize          Don't notarize the dmg.
  --notarize               Notarize using the notarytool-password keychain profile.

VIBEPOLLO_BUILD_DIR overrides the build directory (default: build/macos).
MACOSX_DEPLOYMENT_TARGET overrides the minimum OS (default: this Mac's OS).
Local builds do not require an Apple Developer certificate.

Steps:
  deps                     Install dependencies only
  cmake                    Run cmake configure only
  build                    Build the project only
  test                     Run the test suite
  dmg                      Create a DMG package
  all                      Run all steps (default)
EOF

  exit "$exit_code"
}

function run_step_deps() {
  echo "Running step: Install dependencies"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "${required_formulas[@]}"
  if [[ "$build_docs" == "ON" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install doxygen graphviz
  fi
  # The build-deps checkout identifies a prebuilt FFmpeg release. Its nested
  # FFmpeg source repositories are not needed to build the host.
  git submodule update --init third-party/build-deps
  git submodule update --init --recursive \
    third-party/Simple-Web-Server third-party/TPCircularBuffer \
    third-party/googletest third-party/libdisplaydevice \
    third-party/libvirtualdisplay third-party/libvirtualgamepad \
    third-party/moonlight-common-c third-party/nanors \
    third-party/nv-codec-headers third-party/tray
  return 0
}

function run_step_cmake() {
  echo "Running step: CMake configure"

  # prepare CMAKE args
  cmake_args=(
    "-B=${build_dir}"
    "-S=${source_dir}"
    "-G=Ninja"
    "-DBUILD_DOCS=${build_docs}"
    "-DBUILD_TESTS=ON"
    "-DBUILD_WERROR=OFF"
    "-DCMAKE_BUILD_TYPE=${build_type}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deployment_target}"
    "-DICU_ROOT=$(brew --prefix icu4c@78 2>/dev/null)"
    "-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3 2>/dev/null)"
    "-DOpus_ROOT_DIR=$(brew --prefix opus 2>/dev/null)"
    "-DSUNSHINE_ENABLE_TRAY=ON"
    "-DSUNSHINE_ENABLE_WEBRTC=OFF"
    "-DSUNSHINE_ENABLE_PYROWAVE=OFF"
    "-DSUNSHINE_USE_SYSTEM_BOOST=OFF"
  )

  if [[ -n "${sign_app}" ]]; then
    if [[ -n "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
      cmake_args+=("-DAPPLE_CODESIGN_IDENTITY=${APPLE_CODESIGN_IDENTITY}")
    else
      echo "Please set the APPLE_CODESIGN_IDENTITY environment variable or use --skip-codesign"
      exit 1
    fi
  fi

  # Publisher metadata
  if [[ -n "$publisher_name" ]]; then
    cmake_args+=("-DSUNSHINE_PUBLISHER_NAME=${publisher_name}")
  fi
  if [[ -n "$publisher_website" ]]; then
    cmake_args+=("-DSUNSHINE_PUBLISHER_WEBSITE=${publisher_website}")
  fi
  if [[ -n "$publisher_issue_url" ]]; then
    cmake_args+=("-DSUNSHINE_PUBLISHER_ISSUE_URL=${publisher_issue_url}")
  fi

  # Cmake stuff here
  mkdir -p "$build_dir"
  echo "cmake args:"
  echo "${cmake_args[@]}"
  cmake "${cmake_args[@]}"
  return 0
}

function run_step_build() {
  echo "Running step: Build"
  cmake --build "${build_dir}" -j "${num_processors}"
  return 0
}

function run_step_dmg() {
  echo "Running step: Creating DMG package"

  # This variable is needed by cmake/packaging/macos.cmake
  SHOULD_SIGN=false
  if [[ -n "${sign_app}" ]]; then
    SHOULD_SIGN=true
  fi
  export SHOULD_SIGN

  cpack -G DragNDrop --config "${build_dir}/CPackConfig.cmake" --verbose

  if [[ -n "${sign_app}" && -n "${notarize}" ]]; then
    time xcrun notarytool submit "${build_dir}/cpack_artifacts/Vibepollo.dmg" \
      --keychain-profile "notarytool-password" \
      --wait \
      --timeout 15m
    xcrun stapler staple -v "${build_dir}/cpack_artifacts/Vibepollo.dmg"
  fi
  return 0
}

function run_install() {
  case "$step" in
    deps)
      run_step_deps
      ;;
    cmake)
      run_step_cmake
      ;;
    build)
      run_step_build
      ;;
    test)
      ctest --test-dir "$build_dir" --output-on-failure -j "$num_processors"
      ;;
    dmg)
      run_step_dmg
      ;;
    all)
      run_step_deps
      run_step_cmake
      run_step_build
      ctest --test-dir "$build_dir" --output-on-failure -j "$num_processors"
      run_step_dmg
      ;;
    *)
      echo "Invalid step: $step"
      echo "Valid steps are: deps, cmake, build, test, dmg, all"
      exit 1
      ;;
  esac
  return 0
}

# Parse named arguments
while getopts ":h-:" opt; do
  case ${opt} in
    h ) _usage 0 ;;
    - )
      case "${OPTARG}" in
        help) _usage 0 ;;
        num-processors=*)
          num_processors="${OPTARG#*=}"
          ;;
        publisher-name=*)
          publisher_name="${OPTARG#*=}"
          ;;
        publisher-website=*)
          publisher_website="${OPTARG#*=}"
          ;;
        publisher-issue-url=*)
          publisher_issue_url="${OPTARG#*=}"
          ;;
        step=*)
          step="${OPTARG#*=}"
          ;;
        debug)
          build_type="Debug"
          ;;
        build-docs)
          build_docs="ON"
          ;;
        skip-codesign)
         sign_app=""
          ;;
        skip-notarize)
         notarize=""
          ;;
        notarize)
          notarize="true"
          ;;
        *)
          echo "Invalid option: --${OPTARG}" 1>&2
          _usage 1
          ;;
      esac
      ;;
    \? )
      echo "Invalid option: -${OPTARG}" 1>&2
      _usage 1
      ;;
  esac
done
shift $((OPTIND -1))

if [[ -n "$notarize" && -z "$sign_app" ]]; then
  echo "--notarize requires APPLE_CODESIGN_IDENTITY" >&2
  exit 1
fi

# get directory of this script
echo "Script Directory: $script_dir"
echo "Build Directory: $build_dir"
mkdir -p "$build_dir"

run_install
