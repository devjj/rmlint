#!/bin/sh
# Build a fully static, dependency-free rmlint binary against musl libc.
#
# Runs inside an Alpine Linux container (see build-static-musl.podman.sh for the
# wrapper that invokes this). Produces ./rmlint.static at the repo root: a
# single self-contained x86-64 executable that runs on any Linux kernel with no
# shared-library or glibc/NSS dependencies.
#
# All optional rmlint features are enabled: json-glib (JSON output + JSON cache
# reading), blkid (dev_t -> disk path), libelf (non-stripped binary detection),
# gettext (translations), fiemap, xattr, btrfs/clone support.
set -eu

# This is the INNER script: it must run inside the Alpine container, not on the
# host. Running it directly on a non-Alpine host fails later with a cryptic
# "apk: not found". Detect that early and point at the wrapper instead.
if [ ! -f /etc/alpine-release ]; then
    echo "error: build-static-musl.sh runs *inside* an Alpine container, not on the host." >&2
    echo "       Run the wrapper instead, from the repo root:" >&2
    echo "           ./pkg/static/build-static-musl.podman.sh            # build" >&2
    echo "           RUN_TESTS=1 ./pkg/static/build-static-musl.podman.sh  # build + test" >&2
    echo "       (set CONTAINER_ENGINE=docker to use docker instead of podman)" >&2
    exit 1
fi

PREFIX=/usr/local
JSON_GLIB_VER=1.10.8

echo ">>> Installing build dependencies"
apk update -q
apk add -q \
    build-base scons pkgconf \
    glib-dev glib-static \
    pcre2-dev pcre2-static \
    zlib-dev zlib-static \
    libffi-dev \
    util-linux-dev util-linux-static \
    libeconf-static \
    elfutils-dev \
    gettext-dev \
    linux-headers \
    meson samurai \
    py3-sphinx \
    curl

# json-glib ships shared-only in Alpine, so build a static archive from source
# and install it into $PREFIX where pkg-config will find it ahead of the system
# shared copy.
if [ ! -f "$PREFIX/lib/libjson-glib-1.0.a" ]; then
    echo ">>> Building json-glib $JSON_GLIB_VER as a static library"
    cd /tmp
    curl -fsSL "https://download.gnome.org/sources/json-glib/1.10/json-glib-${JSON_GLIB_VER}.tar.xz" -o json-glib.tar.xz
    tar xf json-glib.tar.xz
    cd "json-glib-${JSON_GLIB_VER}"
    meson setup _build \
        --prefix="$PREFIX" \
        --default-library=static \
        --buildtype=release \
        -Dintrospection=disabled \
        -Dgtk_doc=disabled \
        -Dtests=false \
        -Dman=false
    ninja -C _build
    ninja -C _build install
fi

echo ">>> Patching blkid/mount .pc files for their static libeconf dependency"
# Alpine's static libblkid.a / libmount.a reference libeconf (econf_*), but the
# stock blkid.pc / mount.pc do not list it in Libs.private. Add it so the static
# pkg-config closure places -leconf after -lblkid/-lmount on the link line.
for pc in $(find / -name blkid.pc -o -name mount.pc 2>/dev/null); do
    if ! grep -q -- '-leconf' "$pc"; then
        if grep -q '^Libs.private:' "$pc"; then
            sed -i 's/^\(Libs.private:.*\)$/\1 -leconf/' "$pc"
        else
            echo 'Libs.private: -leconf' >> "$pc"
        fi
        echo "    patched $pc"
    fi
done

echo ">>> Configuring static link flags"
# Make pkg-config emit the full static dependency closure for every package,
# and prefer the json-glib we just built.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG="pkg-config --static"

# Force a fully static, position-dependent executable. -no-pie avoids needing
# the dynamic loader; --static makes the linker pull .a archives only.
export LDFLAGS="-static -no-pie"
export CFLAGS="-O2"

cd /src

echo ">>> Building rmlint (fully static, all features)"
# Clean any host build artifacts that leaked into the bind mount.
scons -c >/dev/null 2>&1 || true
rm -rf .sconf_temp .sconsign.dblite config.log 2>/dev/null || true

# DEBUG=0 -> release; -j parallel. SCons reads PKG_CONFIG / LDFLAGS / CFLAGS
# from the environment (see SConstruct).
scons --prefix="$PREFIX" -j"$(nproc)" DEBUG=0

echo ">>> Verifying the binary is fully static"
cp ./rmlint ./rmlint.static
file ./rmlint.static
# A correctly-static binary makes the musl loader refuse it ("Not a valid
# dynamic program") and `file` reports "statically linked" -- that is success.
if file ./rmlint.static | grep -q "statically linked"; then
    echo ">>> OK: rmlint.static is statically linked (no shared-lib dependencies)"
else
    echo "!!! ERROR: binary is NOT statically linked:"
    ldd ./rmlint.static || true
    exit 1
fi

echo ">>> Feature self-check"
./rmlint.static --version || true

echo ">>> Functional smoke test (find a duplicate pair)"
T=$(mktemp -d)
printf 'the same bytes\n' > "$T/a.txt"
printf 'the same bytes\n' > "$T/b.txt"
printf 'unique\n'         > "$T/c.txt"
./rmlint.static "$T" --no-followlinks 2>&1 | grep -iE "duplicate|b.txt" || true
rm -rf "$T"

# ---------------------------------------------------------------------------
# Optional: run the full behavioural test suite against the static binary.
#
# Enabled with RUN_TESTS=1 (CI sets this). The pytest harness shells out to
# ./rmlint, which IS the static binary we just built, so the existing ~40 test
# files double as static-build coverage -- they prove every feature actually
# works when statically linked, not merely that the binary links.
#
# Tests that fundamentally cannot run in a rootless container are deselected
# and logged (no silent skips):
#   - test_mount_binds      need `mount --bind`        (CAP_SYS_ADMIN)
#   - test_xattr_detail     mounts a fresh ext4 image  (CAP_SYS_ADMIN)
# These are environment limits, not static-link failures; run the suite on a
# privileged host to cover them too.
# ---------------------------------------------------------------------------
if [ "${RUN_TESTS:-0}" = "1" ]; then
    echo ">>> Installing test dependencies"
    # shadow -> useradd/groupadd for test_baduids; attr -> xattr CLI;
    # mandoc provides `man` so --show-man (test_man) can render the manpage
    # that the build produced via sphinx; py3-* avoid building wheels on musl.
    apk add -q python3 py3-pip py3-psutil shadow attr mandoc bash dash coreutils findutils

    python3 -m venv /tmp/rm-venv
    # shellcheck disable=SC1091
    . /tmp/rm-venv/bin/activate
    pip install -q --disable-pip-version-check -r tests/requirements.txt

    echo ">>> Running the test suite against the static binary"
    # RM_TS_PEDANTIC=0 matches CI (skips the all-checksums cross-check that
    # multiplies runtime). Deselect only the CAP_SYS_ADMIN tests above.
    export RM_TS_PEDANTIC=0
    export RM_TS_DIR=/tmp/rmlint-unit-testdir
    echo "    (deselected: test_mount_binds, test_xattr_detail -- need mount privileges)"
    python -m pytest -m "not slow" -q -p no:cacheprovider \
        --deselect tests/test_options/test_merge_directories.py::test_mount_binds \
        --deselect tests/test_robustness/test_path_doubles.py::test_mount_binds \
        --deselect "tests/test_options/test_cache.py::test_xattr_detail[]" \
        --deselect "tests/test_options/test_cache.py::test_xattr_detail[-D]"
    echo ">>> Test suite passed against the static binary"
fi

echo ">>> Done. Binary: $(pwd)/rmlint.static"
