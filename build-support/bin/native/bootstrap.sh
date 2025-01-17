#!/usr/bin/env bash

# Defines:
# + LIB_EXTENSION: The extension of native libraries.
# + KERNEL: The lower-cased name of the kernel as reported by uname.
# + CACHE_ROOT: The pants cache root dir.
# + NATIVE_ENGINE_CACHE_DIR: The directory containing all versions of the native engine for
#                            the current OS.
# + NATIVE_ENGINE_BINARY: The basename of the native engine binary for the current OS.
# + NATIVE_ENGINE_VERSION_RESOURCE: The path of the resource file containing the native engine
#                                   version hash.
# Exposes:
# + calculate_current_hash: Calculates the current native engine version hash and echoes it to
#                           stdout.
# + bootstrap_native_code: Builds native engine binaries.

REPO_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && cd ../../.. && pwd -P)
source ${REPO_ROOT}/build-support/common.sh

readonly KERNEL=$(uname -s | tr '[:upper:]' '[:lower:]')
case "${KERNEL}" in
  linux)
    readonly LIB_EXTENSION=so
    ;;
  darwin)
    readonly LIB_EXTENSION=dylib
    ;;
  *)
    die "Unknown kernel ${KERNEL}, cannot bootstrap pants native code!"
    ;;
esac

readonly NATIVE_ROOT="${REPO_ROOT}/src/rust/engine"
readonly NATIVE_ENGINE_BINARY="native_engine.so"
readonly NATIVE_ENGINE_RESOURCE="${REPO_ROOT}/src/python/pants/engine/${NATIVE_ENGINE_BINARY}"
readonly CFFI_BOOTSTRAPPER="${REPO_ROOT}/build-support/native-engine/bootstrap_cffi.py"

# N.B. Set $MODE to "debug" to generate a binary with debugging symbols.
readonly MODE="${MODE:-release}"
case "$MODE" in
  debug) MODE_FLAG="" ;;
  *) MODE_FLAG="--release" ;;
esac

readonly CACHE_ROOT=${XDG_CACHE_HOME:-$HOME/.cache}/pants
readonly NATIVE_ENGINE_CACHE_DIR=${CACHE_ROOT}/bin/native-engine

# Note(mateo): Upgraded to 1.27 from 1.25 to get fix to trait syntax in getopts.
# This also required using the nightly cargo build so we could enable the rename-feature
# (see "cargo install ensure-install" below.)
readonly RUST_TOOLCHAIN="1.27.0"

function calculate_current_hash() {
  # Cached and unstaged files, with ignored files excluded.
  # NB: We fork a subshell because one or both of `ls-files`/`hash-object` are
  # sensitive to the CWD, and the `--work-tree` option doesn't seem to resolve that.
  (
   cd ${REPO_ROOT}
   (echo "${MODE_FLAG}"
    echo "${RUST_TOOLCHAIN}"
    git ls-files -c -o --exclude-standard \
     "${NATIVE_ROOT}" \
     "${REPO_ROOT}/src/python/pants/engine/native.py" \
     "${REPO_ROOT}/build-support/bin/native" \
     "${REPO_ROOT}/3rdparty/python/requirements.txt" \
   | grep -v -E -e "/BUILD$" -e "/[^/]*\.md$" \
   | git hash-object -t blob --stdin-paths) | fingerprint_data
  )
}

function _ensure_cffi_sources() {
  # N.B. Here we assume that higher level callers have already setup the pants' venv and $PANTS_SRCPATH.
  PYTHONPATH="${PANTS_SRCPATH}:${PYTHONPATH}" python "${CFFI_BOOTSTRAPPER}" "${NATIVE_ROOT}/src/cffi" >&2
}

# Echos directories to add to $PATH.
function ensure_native_build_prerequisites() {
  # Control a pants-specific rust toolchain.

  local RUST_TOOLCHAIN_root="${CACHE_ROOT}/rust"
  export CARGO_HOME="${RUST_TOOLCHAIN_root}/cargo"
  export RUSTUP_HOME="${RUST_TOOLCHAIN_root}/rustup"

  # NB: rustup installs itself into CARGO_HOME, but fetches toolchains into RUSTUP_HOME.
  if [[ ! -x "${CARGO_HOME}/bin/rustup" ]]
  then
    log "A pants owned rustup installation could not be found, installing via the instructions at" \
        "https://www.rustup.rs ..."
    local -r rustup=$(mktemp -t pants.rustup.XXXXXX)
    curl https://sh.rustup.rs -sSf > ${rustup} || (echo "Bad curl, trying wget" && wget https://sh.rustup.rs -O- > ${rustup})
    sh ${rustup} -y --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}" 1>&2
    rm -f ${rustup}
  fi

  # Make sure rust is pinned at the correct version.
  # We sincerely hope that no one ever runs `rustup override set` in a subdirectory of the working directory.
  "${CARGO_HOME}/bin/rustup" override set "${RUST_TOOLCHAIN}" >&2
  "${CARGO_HOME}/bin/rustup" component add rustfmt-preview >&2
  "${CARGO_HOME}/bin/rustup" component add rust-src >&2

  # Sometimes fetching a large git repo dependency can take more than 10 minutes.
  # This times out on travis, because nothing is printed to stdout/stderr in that time.
  # Pre-fetch those git repos and keep writing to stdout as we do.
  # Noisily wait for a cargo fetch. This is not using run_cargo so that the process which is
  # killed by _wait_noisily on ^C is the cargo process itself, rather than a rustup wrapper which
  # spawns a separate cargo process.
  # We need to do this before we install grpcio-compiler to pre-fetch its repo.
  _wait_noisily "${CARGO_HOME}/bin/cargo" fetch --manifest-path "${NATIVE_ROOT}/Cargo.toml" || die

  if [[ ! -x "${CARGO_HOME}/bin/cargo-ensure-installed" ]]; then
    # Enable nightly features to enable full build of getopts and ensure-installed.
    "${CARGO_HOME}/bin/rustup" install nightly >&2
    # Technically only requires the --feature='["rename-dependency"]' flag, but I couldn't get quite right on CLI.
    "${CARGO_HOME}/bin/rustup" run nightly cargo install --all-features cargo-ensure-installed >&2
  fi
  "${CARGO_HOME}/bin/cargo" ensure-installed --package=cargo-ensure-installed --version=0.2.1 >&2
  "${CARGO_HOME}/bin/cargo" ensure-installed --package=protobuf --version=1.4.2 >&2
  "${CARGO_HOME}/bin/cargo" ensure-installed --package=grpcio-compiler --version=0.2.0 >&2

  local download_binary="${REPO_ROOT}/build-support/bin/download_binary.sh"
  local -r cmakeroot="$("${download_binary}" "binaries.pantsbuild.org" "cmake" "3.9.5" "cmake.tar.gz")" || die "Failed to fetch cmake"
  local -r goroot="$("${download_binary}" "binaries.pantsbuild.org" "go" "1.7.3" "go.tar.gz")/go" || die "Failed to fetch go"

  export GOROOT="${goroot}"
  export EXTRA_PATH_FOR_CARGO="${cmakeroot}/bin:${goroot}/bin"
}

function run_cargo() {
  # Exports $EXTRA_PATH_FOR_CARGO which should be put on the $PATH
  ensure_native_build_prerequisites || die

  if [[ "${ensure_cffi_sources}" == "1" ]]; then
    # Must happen in the pants venv and have PANTS_SRCPATH set.
    _ensure_cffi_sources || die
  fi

  local -r cargo="${CARGO_HOME}/bin/cargo"
  # We change to the ${REPO_ROOT} because if we're not in a subdirectory of it, .cargo/config isn't picked up.
  (cd "${REPO_ROOT}" && PATH="${EXTRA_PATH_FOR_CARGO}:${PATH}" "${cargo}" "$@")
}

function _wait_noisily() {
  "$@" &
  pid=$!
  trap 'kill ${pid} ; exit 130' SIGINT

  i=0
  while ps -p "${pid}" >/dev/null 2>/dev/null; do
    [[ "$((i % 60))" -eq 0 ]] && echo >&2 "[Waiting for $@ (pid ${pid}) to complete]"
    i="$((i + 1))"
    sleep 1
  done

  wait "${pid}"

  trap - SIGINT
}

function _build_native_code() {
  # Builds the native code, and echos the path of the built binary.

  ensure_cffi_sources=1 run_cargo build ${MODE_FLAG} --manifest-path ${NATIVE_ROOT}/Cargo.toml -p engine || die
  echo "${NATIVE_ROOT}/target/${MODE}/libengine.${LIB_EXTENSION}"
}

function bootstrap_native_code() {
  # Bootstraps the native code only if needed.
  local native_engine_version="$(calculate_current_hash)"
  local engine_version_header="engine_version: ${native_engine_version}"
  local target_binary="${NATIVE_ENGINE_CACHE_DIR}/${native_engine_version}/${NATIVE_ENGINE_BINARY}"
  local target_binary_metadata="${target_binary}.metadata"
  if [[ ! -f "${target_binary}" || ! -f "${target_binary_metadata}" ]]
  then
    local -r native_binary="$(_build_native_code)"

    # If bootstrapping the native engine fails, don't attempt to run pants
    # afterwards.
    if ! [ -f "${native_binary}" ]
    then
      die "Failed to build native engine."
    fi

    # Pick up Cargo.lock changes if any caused by the `cargo build`.
    native_engine_version="$(calculate_current_hash)"
    engine_version_header="engine_version: ${native_engine_version}"
    target_binary="${NATIVE_ENGINE_CACHE_DIR}/${native_engine_version}/${NATIVE_ENGINE_BINARY}"
    target_binary_metadata="${target_binary}.metadata"

    mkdir -p "$(dirname ${target_binary})"
    cp "${native_binary}" "${target_binary}"

    local -r metadata_file=$(mktemp -t pants.native_engine.metadata.XXXXXX)
    echo "${engine_version_header}" > "${metadata_file}"
    echo "repo_version: $(git describe --dirty)" >> "${metadata_file}"
    mv "${metadata_file}" "${target_binary_metadata}"
  fi

  # Establishes the native engine wheel resource only if needed.
  # NB: The header manipulation code here must be coordinated with header stripping code in
  #     the Native.binary method in src/python/pants/engine/native.py.
  if [[
    ! -f "${NATIVE_ENGINE_RESOURCE}" ||
    "$(head -1 "${NATIVE_ENGINE_RESOURCE}" | tr '\0' '\n')" != "${engine_version_header}"
  ]]
  then
    cat "${target_binary_metadata}" "${target_binary}" > "${NATIVE_ENGINE_RESOURCE}"
  fi
}
