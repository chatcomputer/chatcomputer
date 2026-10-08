#!/usr/bin/env bash
# Builds and tests the platform-neutral modules in a Linux Swift container.
# The macOS-only modules compile to empty modules there; build them with Xcode on a Mac.
set -euo pipefail
# Both packages are mounted: ChatComputerKit depends on ../ChatComputerAgentKit.
cd "$(dirname "$0")/../Packages"
docker run --rm -v "$PWD":/pkgs -w /pkgs/ChatComputerKit swift:6.2-noble \
  bash -c "swift build --build-path /tmp/.build && swift test --build-path /tmp/.build"
