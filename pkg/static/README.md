# Static musl build

Build a **fully static, dependency-free `rmlint`** against musl libc inside an
Alpine container. The result is a single self-contained x86-64 executable that
runs on any Linux kernel — old or new glibc, musl distros, minimal containers,
rescue shells — with no shared-library or glibc/NSS dependencies. Drop it onto
arbitrary target machines and run it.

## Host requirements

Just a container engine: **`podman`** (default) or **`docker`**. Nothing else is
installed on the host — every build dependency lives inside the throwaway Alpine
container.

## Usage

Run the **wrapper** from the repo root:

```sh
./pkg/static/build-static-musl.podman.sh              # build -> ./rmlint.static
RUN_TESTS=1 ./pkg/static/build-static-musl.podman.sh  # build + run the test suite
CONTAINER_ENGINE=docker ./pkg/static/build-static-musl.podman.sh   # use docker
```

Output: `./rmlint.static` at the repo root.

Verify it's static:

```sh
file ./rmlint.static     # -> "... statically linked ..."
ldd  ./rmlint.static     # -> "not a dynamic executable"
```

## The two scripts

| Script | Runs where | You run it? |
| --- | --- | --- |
| `build-static-musl.podman.sh` | on the **host** | **yes — this is the entry point** |
| `build-static-musl.sh` | **inside** the Alpine container | no; the wrapper invokes it |

The inner `build-static-musl.sh` uses Alpine's `apk` and only works inside the
container. It guards against being run on the host and will tell you to use the
wrapper.

## Features

All optional features are enabled: json-glib (JSON output + JSON cache reading),
blkid (`+mounts`), libelf (`+nonstripped`), fiemap, sha512, gettext (`+intl`),
xattr, and btrfs clone support.

## Notes

- json-glib has no static archive in Alpine, so it is built from source with
  meson (`--default-library=static`).
- Alpine's static `libblkid.a`/`libmount.a` reference `libeconf` but omit it
  from their `.pc` `Libs.private`; the build installs `libeconf-static` and
  patches the `.pc` files so `-leconf` lands after `-lblkid` on the link line.
- The binary is **x86-64 only**.

CI builds and tests this on every push — see
`.github/workflows/static-musl-build.yml`, which also uploads the binary as the
`rmlint-static-x86_64` artifact.
