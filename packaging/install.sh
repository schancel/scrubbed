#!/bin/sh
# scrubbed installer (issue #502, slice of #61).
#
# Download the checksum-pinned release copy using the command in the
# installation guide: https://github.com/schancel/scrubbed#installing-a-prebuilt-binary
#
# Detects platform/arch, downloads the matching release tarball built by
# .github/workflows/release.yml (issue #499), verifies its SHA-256 against
# the release's published SHA256SUMS, and installs the binary + bash/zsh/
# fish completions to a sensible location.
#
# POSIX sh only (no bashisms). Fails loudly (non-zero exit, message on
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

# `-w` on a path that does not exist yet is always false, so testing it
# directly against an install prefix/bin dir that `mkdir -p` hasn't created
# yet (the common case: a fresh account's $HOME/.local, or any custom
# SCRUBBED_INSTALL_PREFIX nobody pre-created) wrongly reports "not
# writable" even though the nearest existing parent directory is. Walk up
# to that nearest existing ancestor and test writability there instead --
# that is what actually determines whether `mkdir -p "$1"` would succeed.
nearest_existing_ancestor() {
    dir="$1"
    while [ ! -d "$dir" ]; do
        parent=$(dirname "$dir")
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done
    printf '%s' "$dir"
}

writable_prefix() {
    [ -w "$(nearest_existing_ancestor "$1")" ]
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
            arm64)
                need_cmd sw_vers
                macos_version=$(sw_vers -productVersion)
                macos_major=${macos_version%%.*}
                case "$macos_major" in
                    ''|*[!0-9]*) die "could not determine the macOS version: $macos_version" ;;
                esac
                if [ "$macos_major" -lt 15 ]; then
                    die "macOS 15 (Sequoia) or later is required; found macOS $macos_version"
                fi
                target="macos-arm64"
                ;;
            *) die "unsupported platform: macOS $arch_name (only macOS arm64 / Apple Silicon is supported; see issue #353)" ;;
        esac
        ;;
    Linux)
        need_cmd getconf
        glibc_report=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
        case "$glibc_report" in
            "glibc 2."*)
                glibc_minor=${glibc_report#glibc 2.}
                glibc_minor=${glibc_minor%%.*}
                case "$glibc_minor" in
                    ''|*[!0-9]*) die "could not determine the glibc version: $glibc_report" ;;
                esac
                if [ "$glibc_minor" -lt 36 ]; then
                    die "glibc 2.36 or later is required; found $glibc_report"
                fi
                ;;
            "glibc "[3-9]*) ;;
            *) die "glibc 2.36 or later is required; found ${glibc_report:-an unknown C library}" ;;
        esac
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
staged_bin=""
cleanup() {
    rm -rf "$workdir"
    if [ -n "$staged_bin" ]; then
        if [ -n "${use_sudo:-}" ]; then
            sudo rm -f "$staged_bin" >/dev/null 2>&1 || true
        else
            rm -f "$staged_bin"
        fi
    fi
}
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
    if writable_prefix "/usr/local/bin" || [ "$(id -u)" = "0" ]; then
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
if [ "$(id -u)" != "0" ] && ! writable_prefix "$bin_dir"; then
    if [ -z "${SCRUBBED_INSTALL_NO_SUDO:-}" ] && command -v sudo >/dev/null 2>&1; then
        use_sudo="sudo"
        info "using sudo to install into $prefix"
    else
        die "cannot write to $prefix (nearest existing directory $(nearest_existing_ancestor "$bin_dir") is not writable) and no sudo available -- set SCRUBBED_INSTALL_PREFIX to a writable location (e.g. \$HOME/.local)"
    fi
fi

run() {
    if [ -n "$use_sudo" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

verify_runtime() {
    candidate="$1"
    if ! verified_version=$("$candidate" --version 2>/dev/null); then
        return 1
    fi
    [ -n "$verified_version" ]
}

install_license_files() {
    if [ -f "$extract_dir/LICENSE" ]; then
        run mkdir -p "$share_dir/licenses/scrubbed"
        run install -m 0644 "$extract_dir/LICENSE" "$share_dir/licenses/scrubbed/LICENSE"
        if [ -f "$extract_dir/THIRD_PARTY_NOTICES.md" ]; then
            run install -m 0644 "$extract_dir/THIRD_PARTY_NOTICES.md" \
                "$share_dir/licenses/scrubbed/THIRD_PARTY_NOTICES.md"
        fi
    fi
}

info "installing to $prefix"
run mkdir -p "$bin_dir"

if [ -n "$use_sudo" ]; then
    # Consume every remaining file from the user-owned extraction tree before
    # executing downloaded code. The candidate binary is staged into the
    # root-owned destination directory, verified there as the invoking user,
    # and only then atomically replaces the installed binary.
    install_license_files
    staged_bin=$(sudo mktemp "$bin_dir/.scrubbed-install.XXXXXX")
    sudo install -m 0755 "$extract_dir/scrubbed" "$staged_bin"
    if ! verify_runtime "$staged_bin"; then
        die "downloaded binary did not run successfully on this host -- existing binary was not changed"
    fi
    info "verified runtime: $verified_version"
    sudo mv -f "$staged_bin" "$bin_dir/scrubbed"
    staged_bin=""
else
    if ! verify_runtime "$extract_dir/scrubbed"; then
        die "downloaded binary did not run successfully on this host -- existing installation was not changed"
    fi
    info "verified runtime: $verified_version"
    install -m 0755 "$extract_dir/scrubbed" "$bin_dir/scrubbed"
    install_license_files
fi

# Completion initializers embed the path of the binary that generated them.
# Regenerate after installation so custom and fallback prefixes do not retain
# the release builder's /usr/local/bin/scrubbed path.
for shell_name in bash zsh fish; do
    if ! completion_text=$("$bin_dir/scrubbed" completion init "--$shell_name"); then
        die "failed to generate $shell_name completions"
    fi
    case "$shell_name" in
        bash) completion_dir="$share_dir/bash-completion/completions"; completion_file="$completion_dir/scrubbed" ;;
        zsh) completion_dir="$share_dir/zsh/site-functions"; completion_file="$completion_dir/_scrubbed" ;;
        fish) completion_dir="$share_dir/fish/vendor_completions.d"; completion_file="$completion_dir/scrubbed.fish" ;;
    esac
    run mkdir -p "$completion_dir"
    if [ -n "$use_sudo" ]; then
        printf '%s\n' "$completion_text" | sudo tee "$completion_file" >/dev/null
        sudo chmod 0644 "$completion_file"
    else
        printf '%s\n' "$completion_text" > "$completion_file"
        chmod 0644 "$completion_file"
    fi
done

if ! installed_version=$("$bin_dir/scrubbed" --version 2>/dev/null); then
    die "installed binary at $bin_dir/scrubbed did not run successfully (--version failed)"
fi
if [ -z "$installed_version" ]; then
    die "installed binary at $bin_dir/scrubbed did not run successfully (--version failed)"
fi
info "installed: $installed_version"
info "binary: $bin_dir/scrubbed"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) info "note: $bin_dir is not on your PATH -- add it, e.g.: export PATH=\"$bin_dir:\$PATH\"" ;;
esac
