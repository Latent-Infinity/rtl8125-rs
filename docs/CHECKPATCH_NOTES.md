# `scripts/checkpatch.pl` status

`scripts/checkpatch.pl` is the kernel community's mandatory pre-submission
style check. Run from the kernel headers tree:

```
CHECKPATCH=/usr/src/linux-headers-$(uname -r)/scripts/checkpatch.pl
for f in src/netdev_bridge*.c src/netdev_bridge.h src/netdev_bridge_internal.h; do
    perl "$CHECKPATCH" --no-tree --terse --no-summary --file "$f"
done
```

## Current state

**Clean.** Zero warnings, zero errors across the six cshim C translation
units plus the two cshim headers as of 2026-06-01:

  - `src/netdev_bridge.c`
  - `src/netdev_bridge_offload.c`
  - `src/netdev_bridge_counters.c`
  - `src/netdev_bridge_ethtool.c`
  - `src/netdev_bridge_phy.c`
  - `src/netdev_bridge_rx_pool.c`
  - `src/netdev_bridge.h`
  - `src/netdev_bridge_internal.h`

## Out of scope

  - **Rust files.** `checkpatch.pl` does not understand Rust syntax;
    Rust-side style is enforced by `cargo fmt` (or `rustfmt`) and
    `ci/check_clippy.sh` against the validated rustc-1.93 toolchain.
  - **Generated `r8125_rust.mod.c`.** The kbuild-generated trampoline
    is exempt by community convention.

## Local CI gate

`ci/check_checkpatch.sh` invokes the above loop and fails non-zero on
any warning or error. The script auto-skips when no kernel headers
tree is present (so out-of-tree contributors on minimal hosts can
still run `ci/run_checks.sh` without a Linux kernel install).

## Maintainer expectations

A clean checkpatch run is the **minimum** netdev acceptance bar; it is
not sufficient. Maintainers additionally expect:

  - `sparse` clean (`make C=2 M=$PWD`) -- TODO before RFC.
  - `smatch` clean -- TODO before RFC.
  - `kernel-doc` warnings absent for any parseable `/** ... */`
    blocks. The current cshim header uses detailed contract comments,
    not kernel-doc blocks; convert and verify with
    `scripts/kernel-doc -none src/netdev_bridge.h` if the upstream
    series exposes those contracts as kernel-doc.

The TODOs above are documented in `docs/UPSTREAM_REVIEW.md` section Soft
blockers.
