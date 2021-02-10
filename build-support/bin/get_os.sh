#!/bin/bash -eu

# Outputs the current operating system and variant, as used by BinaryUtils.
# Example output: mac/10.13
# Example output: linux/x86_64

# NOTE(mateo): Hardcoding the 10.13 OSX version because the upstream Pants binaries
# for the JVM backend are no longer being ported forward for every OS. Internally we also
# assume similar binary compatability, hardcoding all OSX to 10.13 in internal upkeep env.sh.

case "$(uname)" in
  "Darwin")
    os="mac"
    base="$(uname -r)"
    os_version="10.13"
    ;;
  "Linux")
    os="linux"
    os_version="$(uname -m)"
    ;;
  *)
    echo >&2 "Unknown platform"
    exit 1
    ;;
esac

echo "${os}/${os_version}"
