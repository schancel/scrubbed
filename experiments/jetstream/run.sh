#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
. "$here/versions.env"

for command_name in cmake cc curl jq openssl pkg-config sed sort tar lsof; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "jetstream evaluation: missing required command: $command_name" >&2
        exit 2
    }
done

case "$(uname -s):$(uname -m)" in
    Darwin:x86_64)
        platform=darwin-amd64
        server_sha=$NATS_SERVER_DARWIN_AMD64_SHA256
        sbom_sha=$NATS_SERVER_DARWIN_AMD64_SBOM_SHA256
        ;;
    Darwin:arm64)
        platform=darwin-arm64
        server_sha=$NATS_SERVER_DARWIN_ARM64_SHA256
        sbom_sha=$NATS_SERVER_DARWIN_ARM64_SBOM_SHA256
        ;;
    Linux:x86_64)
        platform=linux-amd64
        server_sha=$NATS_SERVER_LINUX_AMD64_SHA256
        sbom_sha=$NATS_SERVER_LINUX_AMD64_SBOM_SHA256
        ;;
    Linux:aarch64|Linux:arm64)
        platform=linux-arm64
        server_sha=$NATS_SERVER_LINUX_ARM64_SHA256
        sbom_sha=$NATS_SERVER_LINUX_ARM64_SBOM_SHA256
        ;;
    *)
        echo "jetstream evaluation: unsupported fixture platform: $(uname -s) $(uname -m)" >&2
        exit 2
        ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/scrubd-jetstream.XXXXXX")
server_pid=
client_pid=
umask 077

stop_pid()
{
    pid=$1
    label=$2
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid"
        waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
            sleep 0.05
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "jetstream evaluation: $label PID $pid did not stop in 5 seconds" >&2
            kill -KILL "$pid"
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup()
{
    stop_pid "$client_pid" client
    client_pid=
    stop_pid "$server_pid" server
    server_pid=
    case "$scratch" in
        "${TMPDIR:-/tmp}"/scrubd-jetstream.*) rm -rf -- "$scratch" ;;
        *) echo "jetstream evaluation: refusing to remove unexpected scratch path: $scratch" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

sha256()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | sed 's/[[:space:]].*//'
    else
        shasum -a 256 "$1" | sed 's/[[:space:]].*//'
    fi
}

fetch()
{
    url=$1
    destination=$2
    expected=$3
    curl -fL --retry 3 --connect-timeout 10 --max-time 60 \
        --output "$destination" "$url"
    actual=$(sha256 "$destination")
    if [ "$actual" != "$expected" ]; then
        echo "jetstream evaluation: checksum mismatch for $destination" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 2
    fi
}

nats_c_archive="$scratch/nats.c-v${NATS_C_VERSION}.tar.gz"
server_archive="$scratch/nats-server-v${NATS_SERVER_VERSION}-${platform}.tar.gz"
server_sbom="$scratch/nats-server-v${NATS_SERVER_VERSION}-${platform}.sbom.spdx.json"
fetch "https://github.com/nats-io/nats.c/archive/refs/tags/v${NATS_C_VERSION}.tar.gz" \
    "$nats_c_archive" "$NATS_C_SOURCE_SHA256"
fetch "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VERSION}/nats-server-v${NATS_SERVER_VERSION}-${platform}.tar.gz" \
    "$server_archive" "$server_sha"
fetch "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VERSION}/nats-server-v${NATS_SERVER_VERSION}-${platform}.sbom.spdx.json" \
    "$server_sbom" "$sbom_sha"
jq -r '.packages[] | select(.name != "nats-server") | [.name, .versionInfo, .licenseConcluded] | @tsv' \
    "$server_sbom" | sort > "$scratch/server-sbom.tsv"
cmp "$here/server-sbom.expected.tsv" "$scratch/server-sbom.tsv"
tar -xzf "$nats_c_archive" -C "$scratch"
tar -xzf "$server_archive" -C "$scratch"

source_dir="$scratch/nats.c-${NATS_C_VERSION}"
install_dir="$scratch/install"
build_dir="$scratch/build"
openssl_prefix=$(pkg-config --variable=prefix openssl)
openssl_version=$(pkg-config --modversion openssl)
openssl_pc_dir=$(pkg-config --variable=pcfiledir openssl)
openssl_link_flags=$(pkg-config --libs openssl)
[ -n "$openssl_prefix" ] && [ -n "$openssl_version" ] &&
    [ -n "$openssl_pc_dir" ] && [ -n "$openssl_link_flags" ] || {
    echo "jetstream evaluation: incomplete OpenSSL pkg-config identity" >&2
    exit 2
}
cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DOPENSSL_ROOT_DIR="$openssl_prefix" \
    -DNATS_BUILD_WITH_TLS=ON \
    -DNATS_BUILD_TLS_FORCE_HOST_VERIFY=ON \
    -DNATS_BUILD_STREAMING=OFF \
    -DNATS_BUILD_USE_SODIUM=OFF \
    -DNATS_BUILD_EXAMPLES=OFF \
    -DNATS_BUILD_LIB_STATIC=ON \
    -DNATS_BUILD_LIB_SHARED=OFF \
    -DNATS_WITH_EXPERIMENTAL=OFF >/dev/null
cmake --build "$build_dir" --parallel 2 >/dev/null
cmake --install "$build_dir" >/dev/null

static_library=$(find "$install_dir" -name 'libnats_static.a' -type f -print | sed -n '1p')
[ -n "$static_library" ] || {
    echo "jetstream evaluation: static nats.c library was not installed" >&2
    exit 2
}
cc -std=c11 -O2 -Wall -Wextra -Werror -I"$install_dir/include" \
    "$here/probe.c" "$static_library" $openssl_link_flags -pthread \
    -o "$scratch/probe"

case "$platform" in
    darwin-*)
        command -v otool >/dev/null 2>&1 || {
            echo "jetstream evaluation: otool is required on macOS" >&2
            exit 2
        }
        otool -L "$scratch/probe" > "$scratch/probe-linkage.txt"
        ;;
    linux-*)
        command -v ldd >/dev/null 2>&1 || {
            echo "jetstream evaluation: ldd is required on Linux" >&2
            exit 2
        }
        ldd "$scratch/probe" > "$scratch/probe-linkage.txt"
        ;;
esac
if grep -q 'libnats' "$scratch/probe-linkage.txt"; then
    echo "jetstream evaluation: probe unexpectedly has a dynamic nats.c dependency" >&2
    exit 2
fi
grep -q 'libssl' "$scratch/probe-linkage.txt" || {
    echo "jetstream evaluation: probe is missing its expected dynamic TLS dependency" >&2
    exit 2
}
grep -q 'libcrypto' "$scratch/probe-linkage.txt" || {
    echo "jetstream evaluation: probe is missing its expected dynamic crypto dependency" >&2
    exit 2
}

server="$scratch/nats-server-v${NATS_SERVER_VERSION}-${platform}/nats-server"
[ -x "$server" ] || {
    echo "jetstream evaluation: server archive layout changed" >&2
    exit 2
}
server_version=$($server --version)
[ "$server_version" = "nats-server: v${NATS_SERVER_VERSION}" ] || {
    echo "jetstream evaluation: server version mismatch: $server_version" >&2
    exit 2
}

mkdir "$scratch/tls" "$scratch/store"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$scratch/tls/ca.key" >/dev/null 2>&1
openssl req -x509 -new -key "$scratch/tls/ca.key" -sha256 -days 1 \
    -subj '/CN=scrubd-jetstream-evaluation-ca' -out "$scratch/tls/ca.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$scratch/tls/server.key" >/dev/null 2>&1
openssl req -new -key "$scratch/tls/server.key" \
    -subj '/CN=localhost' -out "$scratch/tls/server.csr"
printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    'extendedKeyUsage=serverAuth' > "$scratch/tls/server.ext"
openssl x509 -req -in "$scratch/tls/server.csr" -CA "$scratch/tls/ca.pem" \
    -CAkey "$scratch/tls/ca.key" -CAcreateserial -days 1 -sha256 \
    -extfile "$scratch/tls/server.ext" -out "$scratch/tls/server.pem" >/dev/null 2>&1
token=$(openssl rand -hex 24)

write_config()
{
    config_path=$1
    port=$2
    {
        printf 'server_name: scrubd-jetstream-evaluation\n'
        printf 'host: 127.0.0.1\n'
        printf 'port: %s\n' "$port"
        printf 'max_payload: 1024\n'
        printf 'max_pending: 1MB\n'
        printf 'authorization { token: "%s"; timeout: 1 }\n' "$token"
        printf 'tls { cert_file: "%s"; key_file: "%s"; ca_file: "%s"; timeout: 1 }\n' \
            "$scratch/tls/server.pem" "$scratch/tls/server.key" "$scratch/tls/ca.pem"
        printf 'jetstream { store_dir: "%s"; max_file_store: 4MB; max_memory_store: 1MB }\n' \
            "$scratch/store"
    } > "$config_path"
}

write_control_config()
{
    config_path=$1
    port=$2
    {
        printf 'server_name: scrubd-jetstream-plaintext-control\n'
        printf 'host: 127.0.0.1\n'
        printf 'port: %s\n' "$port"
        printf 'max_payload: 1024\n'
        printf 'max_pending: 1MB\n'
        printf 'authorization { token: "%s"; timeout: 1 }\n' "$token"
    } > "$config_path"
}

generation=0
start_server()
{
    config_path=$1
    generation=$((generation + 1))
    server_log="$scratch/server-${generation}.log"
    (
        ulimit -n 64
        exec "$server" -c "$config_path"
    ) >"$server_log" 2>&1 &
    server_pid=$!
    checks=0
    while [ "$checks" -lt 100 ]; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "jetstream evaluation: server exited during startup" >&2
            sed -n '1,120p' "$server_log" >&2
            exit 2
        fi
        grep -q 'Server is ready' "$server_log" && return 0
        sleep 0.05
        checks=$((checks + 1))
    done
    echo "jetstream evaluation: server did not become ready in 5 seconds" >&2
    exit 2
}

wait_probe_pid()
{
    probe_pid=$1
    probe_label=$2
    probe_checks=0
    while kill -0 "$probe_pid" 2>/dev/null && [ "$probe_checks" -lt 320 ]; do
        sleep 0.05
        probe_checks=$((probe_checks + 1))
    done
    if kill -0 "$probe_pid" 2>/dev/null; then
        stop_pid "$probe_pid" "$probe_label"
        echo "jetstream evaluation: $probe_label exceeded exact-PID 16s outer deadline" >&2
        return 2
    fi
    if wait "$probe_pid"; then
        return 0
    else
        probe_status=$?
        echo "jetstream evaluation: $probe_label PID $probe_pid exited $probe_status" >&2
        return "$probe_status"
    fi
}

run_probe()
{
    probe_label=$1
    shift
    (
        ulimit -n 64
        exec "$scratch/probe" "$@"
    ) >> "$results" &
    probe_pid=$!
    wait_probe_pid "$probe_pid" "$probe_label"
}

bootstrap_config="$scratch/server-bootstrap.conf"
fixed_config="$scratch/server.conf"
control_config="$scratch/server-control.conf"
write_control_config "$control_config" -1
export NATS_TOKEN=$token
export NATS_C_EXPECTED_VERSION=$NATS_C_VERSION
results="$scratch/results.tsv"

start_server "$control_config"
control_port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$server_log" | sed -n '1p')
[ -n "$control_port" ] || {
    echo "jetstream evaluation: unable to discover plaintext control port" >&2
    exit 2
}
export NATS_CONTROL_PORT=$control_port
run_probe plaintext-control plaintext-control
stop_pid "$server_pid" plaintext-control-server
server_pid=

write_config "$bootstrap_config" -1
start_server "$bootstrap_config"
port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$server_log" | sed -n '1p')
[ -n "$port" ] || {
    echo "jetstream evaluation: unable to discover loopback port" >&2
    exit 2
}
write_config "$fixed_config" "$port"

export NATS_URL="tls://localhost:$port"
export NATS_CA_FILE="$scratch/tls/ca.pem"
export NATS_TLS_PORT=$port
run_probe auth auth
run_probe setup setup

stop_pid "$server_pid" server
server_pid=
start_server "$fixed_config"
run_probe restart restart

marker="$scratch/reconnect.ready"
(
    ulimit -n 64
    exec "$scratch/probe" reconnect "$marker"
) >> "$results" &
client_pid=$!
checks=0
while [ ! -f "$marker" ] && [ "$checks" -lt 100 ]; do
    if ! kill -0 "$client_pid" 2>/dev/null; then
        wait "$client_pid"
    fi
    sleep 0.05
    checks=$((checks + 1))
done
[ -f "$marker" ] || {
    echo "jetstream evaluation: reconnect client did not become ready" >&2
    exit 2
}
client_fds=$(lsof -a -p "$client_pid" -d 0-63 2>/dev/null | sed '1d' | wc -l | tr -d ' ')
if [ "$client_fds" -lt 4 ] || [ "$client_fds" -gt 64 ]; then
    echo "jetstream evaluation: live client descriptor count outside 4..64: $client_fds" >&2
    exit 2
fi
stop_pid "$server_pid" server
server_pid=
start_server "$fixed_config"
wait_probe_pid "$client_pid" reconnect
client_pid=

run_probe delete delete
cmp "$here/expected.tsv" "$results"

server_fds=$(lsof -a -p "$server_pid" -d 0-63 2>/dev/null | sed '1d' | wc -l | tr -d ' ')
[ "$server_fds" -le 64 ] || {
    echo "jetstream evaluation: server descriptor bound exceeded: $server_fds" >&2
    exit 2
}
store_bytes=$(du -sk "$scratch/store" | awk '{print $1 * 1024}')
[ "$store_bytes" -le 4194304 ] || {
    echo "jetstream evaluation: store bound exceeded: $store_bytes" >&2
    exit 2
}
scratch_bytes=$(du -sk "$scratch" | awk '{print $1 * 1024}')
[ "$scratch_bytes" -le 268435456 ] || {
    echo "jetstream evaluation: scratch bound exceeded: $scratch_bytes" >&2
    exit 2
}

# Exercise the error trap with the real server binary. The inner scratch holds
# its log and throwaway content; only PID/path records survive long enough for
# the parent to prove that the exact child and its artifacts are gone.
stop_pid "$server_pid" server
server_pid=
failure_pid_record="$scratch/failure-server.pid"
failure_path_record="$scratch/failure-server.path"
if (
    failure_scratch=$(mktemp -d "$scratch/failure-server.XXXXXX")
    failure_server_pid=
    failure_cleanup()
    {
        stop_pid "$failure_server_pid" failure-server
        failure_server_pid=
        rm -rf -- "$failure_scratch"
    }
    trap failure_cleanup EXIT HUP INT TERM
    printf '%s\n' "$failure_scratch" > "$failure_path_record"
    generation=100
    start_server "$bootstrap_config"
    failure_server_pid=$server_pid
    printf '%s\n' "$failure_server_pid" > "$failure_pid_record"
    printf 'throwaway-content\n' > "$failure_scratch/content"
    exit 23
); then
    echo "jetstream evaluation: intentional failure fixture unexpectedly succeeded" >&2
    exit 2
fi
failure_server_pid=$(sed -n '1p' "$failure_pid_record")
failure_scratch=$(sed -n '1p' "$failure_path_record")
if kill -0 "$failure_server_pid" 2>/dev/null || [ -e "$failure_scratch" ]; then
    echo "jetstream evaluation: failure cleanup left a server or scratch content" >&2
    exit 2
fi
scratch_bytes=$(du -sk "$scratch" | awk '{print $1 * 1024}')
[ "$scratch_bytes" -le 268435456 ] || {
    echo "jetstream evaluation: post-failure scratch bound exceeded: $scratch_bytes" >&2
    exit 2
}

cat "$results"
printf 'resources\tplatform=%s\tserver-fds=%s/64\tclient-fds=%s/64\tstore-bytes=%s/4194304\tscratch-bytes=%s/268435456\truntime-processes=2\tbuild-jobs=2\n' \
    "$platform" "$server_fds" "$client_fds" "$store_bytes" "$scratch_bytes"
printf 'packaging\tnats-c=%s-static\tnats-server=%s-official-binary\topenssl-pkgconfig=%s-dynamic\topenssl-pc-dir=%s\tsbom-verified=true\n' \
    "$NATS_C_VERSION" "$NATS_SERVER_VERSION" "$openssl_version" "$openssl_pc_dir"
scratch_path=$scratch
cleanup
trap - EXIT HUP INT TERM
[ ! -e "$scratch_path" ] || {
    echo "jetstream evaluation: scratch cleanup failed: $scratch_path" >&2
    exit 2
}
printf 'cleanup\tserver-stopped=true\tclient-stopped=true\tfailure-trap=true\tscratch-removed=true\tephemeral-secrets-removed=true\n'
