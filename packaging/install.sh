#!/bin/sh
# scrubbed one-line installer (issue #502, slice of #61).
#
#   curl -fsSL https://raw.githubusercontent.com/schancel/scrubbed/main/packaging/install.sh | sh
#
# Detects platform/arch, downloads the matching release tarball built by
# .github/workflows/release.yml (issue #499), verifies its SHA-256 against
# the release's published SHA256SUMS, and installs the binary + bash/zsh/
# fish completions to a sensible location.
#
# POSIX sh only (no bashisms) -- this is piped into whatever shell the
# invoker's `sh` resolves to. Fails loudly (non-zero exit, message on
# stderr) on any unsupported platform or checksum mismatch; never installs
# an unverified binary.
#
# Overridable via environment variables (all optional):
#   SCRUBBED_VERSION           exact release tag's version, e.g. "1.2.0"
#                               (without the leading "v"); default: latest
#                               published GitHub release.
#   SCRUBBED_INSTALL_BASE_URL  base releases URL, default
#                               "https://github.com/schancel/scrubbed/releases".
#                               A version is fetched from
#                               "$BASE/download/v$VERSION/<asset>" and the
#                               latest from "$BASE/latest/download/<asset>"
#                               -- the same two path shapes GitHub itself
#                               serves, so a local fixture server can mimic
#                               this layout for offline testing (see
#                               packaging/rpm/README or the test harness
#                               this script's own evidence run used).
#   SCRUBBED_INSTALL_PREFIX    install prefix; binary goes to
#                               "$PREFIX/bin/scrubbed". Default:
#                               "/usr/local" if writable (or root/sudo
#                               available), else "$HOME/.local".
#   SCRUBBED_INSTALL_NO_SUDO   set to any nonempty value to never invoke
#                               sudo, even if the default prefix is not
#                               writable (falls back to $HOME/.local
#                               instead of prompting).

set -eu

program_name="scrubbed"
repo="schancel/scrubbed"
default_base_url="https://github.com/${repo}/releases"

die() {
    printf 'scrubbed-install: error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf 'scrubbed-install: %s\n' "$1" >&2
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "required command not found: $1"
    fi
}

need_cmd uname
need_cmd curl
need_cmd mktemp
need_cmd tar

info "installing $program_name"

# --- 1. Platform/arch detection -------------------------------------------
#
# Must match exactly one of release.yml's three build targets: macos-arm64,
# linux-x86_64, linux-aarch64 (see dub.json's own preBuildCommands platform
# gate -- these are the only platforms scrubbed builds for at all).

os_name=$(uname -s)
arch_name=$(uname -m)

case "$os_name" in
    Darwin)
        case "$arch_name" in
            arm64) target="macos-arm64" ;;
            *) die "unsupported platform: macOS $arch_name (only macOS arm64 / Apple Silicon is supported; see issue #353)" ;;
        esac
        ;;
    Linux)
        case "$arch_name" in
            x86_64) target="linux-x86_64" ;;
            aarch64) target="linux-aarch64" ;;
            *) die "unsupported platform: Linux $arch_name (only x86_64 and aarch64 are supported; see issue #353)" ;;
        esac
        ;;
    *)
        die "unsupported platform: $os_name (only macOS and Linux are supported; see issue #353)"
        ;;
esac

info "detected platform: $target"

# --- 2. Resolve version and URLs -------------------------------------------

base_url="${SCRUBBED_INSTALL_BASE_URL:-$default_base_url}"

if [ -n "${SCRUBBED_VERSION:-}" ]; then
    version="$SCRUBBED_VERSION"
    download_dir="download/v${version}"
    info "requested version: $version"
else
    download_dir="latest/download"
    info "requested version: latest"
fi

# The exact archive filename embeds the resolved version, which we don't
# know yet when SCRUBBED_VERSION is unset ("latest"). GitHub's
# "/latest/download/<asset>" convenience redirect requires the literal
# asset name, so resolve the version first via the SHA256SUMS manifest,
# which is published under the same version-independent "latest" path and
# lists every target's real archive filename for that release.

sums_url="${base_url}/${download_dir}/SHA256SUMS"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/scrubbed-install.XXXXXX")
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT INT TERM

sums_file="$workdir/SHA256SUMS"
info "fetching checksums: $sums_url"
if ! curl -fsSL -o "$sums_file" "$sums_url"; then
    die "failed to download SHA256SUMS from $sums_url (bad version, network error, or no matching release)"
fi
if [ ! -s "$sums_file" ]; then
    die "downloaded SHA256SUMS is empty: $sums_url"
fi

archive_name=$(awk -v t="$target" '$0 ~ ("  .*-" t "\\.tar\\.gz$") { print $2; exit }' "$sums_file")
if [ -z "$archive_name" ]; then
    die "SHA256SUMS has no entry for platform '$target' -- release may not have shipped this target"
fi

expected_sha256=$(awk -v n="$archive_name" '$2 == n { print $1; exit }' "$sums_file")
if [ -z "$expected_sha256" ]; then
    die "could not find a checksum line for $archive_name in SHA256SUMS"
fi

archive_url="${base_url}/${download_dir}/${archive_name}"
archive_file="$workdir/$archive_name"

info "downloading: $archive_url"
if ! curl -fsSL -o "$archive_file" "$archive_url"; then
    die "failed to download release archive from $archive_url"
fi

# --- 3. Verify checksum -----------------------------------------------------

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256=$(sha256sum "$archive_file" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual_sha256=$(shasum -a 256 "$archive_file" | awk '{print $1}')
else
    die "no sha256sum/shasum available to verify the download -- refusing to install an unverified binary"
fi

if [ "$actual_sha256" != "$expected_sha256" ]; then
    die "SHA-256 mismatch for $archive_name: expected $expected_sha256, got $actual_sha256 -- refusing to install a corrupted or tampered download"
fi
info "checksum verified: $actual_sha256"

# --- 4. Extract --------------------------------------------------------------

extract_dir="$workdir/pkg"
mkdir -p "$extract_dir"
tar -C "$extract_dir" -xzf "$archive_file"

[ -f "$extract_dir/scrubbed" ] || die "extracted archive is missing the scrubbed binary (unexpected archive layout)"

# --- 5. Choose install prefix ------------------------------------------------

choose_prefix() {
    if [ -n "${SCRUBBED_INSTALL_PREFIX:-}" ]; then
        printf '%s' "$SCRUBBED_INSTALL_PREFIX"
        return
    fi
    if [ -w "/usr/local/bin" ] || [ "$(id -u)" = "0" ]; then
        printf '%s' "/usr/local"
        return
    fi
    if [ -z "${SCRUBBED_INSTALL_NO_SUDO:-}" ] && command -v sudo >/dev/null 2>&1; then
        printf '%s' "/usr/local"
        return
    fi
    printf '%s' "$HOME/.local"
}

prefix=$(choose_prefix)
bin_dir="$prefix/bin"
share_dir="$prefix/share"

use_sudo=""
if [ ! -w "$bin_dir" ] && [ ! -w "$prefix" ] && [ "$(id -u)" != "0" ]; then
    if [ -z "${SCRUBBED_INSTALL_NO_SUDO:-}" ] && command -v sudo >/dev/null 2>&1; then
        use_sudo="sudo"
        info "using sudo to install into $prefix"
    else
        die "cannot write to $prefix and no sudo available -- set SCRUBBED_INSTALL_PREFIX to a writable location (e.g. \$HOME/.local)"
    fi
fi

run() {
    if [ -n "$use_sudo" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

info "installing to $prefix"
run mkdir -p "$bin_dir"
run install -m 0755 "$extract_dir/scrubbed" "$bin_dir/scrubbed"

if [ -d "$extract_dir/completions" ]; then
    if [ -f "$extract_dir/completions/scrubbed.bash" ]; then
        run mkdir -p "$share_dir/bash-completion/completions"
        run install -m 0644 "$extract_dir/completions/scrubbed.bash" \
            "$share_dir/bash-completion/completions/scrubbed"
    fi
    if [ -f "$extract_dir/completions/scrubbed.zsh" ]; then
        run mkdir -p "$share_dir/zsh/site-functions"
        run install -m 0644 "$extract_dir/completions/scrubbed.zsh" \
            "$share_dir/zsh/site-functions/_scrubbed"
    fi
    if [ -f "$extract_dir/completions/scrubbed.fish" ]; then
        run mkdir -p "$share_dir/fish/vendor_completions.d"
        run install -m 0644 "$extract_dir/completions/scrubbed.fish" \
            "$share_dir/fish/vendor_completions.d/scrubbed.fish"
    fi
fi

if [ -f "$extract_dir/LICENSE" ]; then
    run mkdir -p "$share_dir/licenses/scrubbed"
    run install -m 0644 "$extract_dir/LICENSE" "$share_dir/licenses/scrubbed/LICENSE"
    if [ -f "$extract_dir/THIRD_PARTY_NOTICES.md" ]; then
        run install -m 0644 "$extract_dir/THIRD_PARTY_NOTICES.md" \
            "$share_dir/licenses/scrubbed/THIRD_PARTY_NOTICES.md"
    fi
fi

installed_version=$("$bin_dir/scrubbed" --version 2>/dev/null || true)
if [ -z "$installed_version" ]; then
    die "installed binary at $bin_dir/scrubbed did not run successfully (--version failed)"
fi
info "installed: $installed_version"
info "binary: $bin_dir/scrubbed"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) info "note: $bin_dir is not on your PATH -- add it, e.g.: export PATH=\"$bin_dir:\$PATH\"" ;;
esac
