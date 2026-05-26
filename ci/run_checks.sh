#!/usr/bin/env bash
# CI orchestrator (plan §9.4). Runs the mechanical checks that do NOT need the
# kernel build toolchain (those run in the guest CI job once §15 #3/#4/#5 are
# green). Designed to pass at M0 and tighten as code lands.
set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "== unsafe / MMIO / census discipline =="
bash "$CI/check_unsafe_allowlist.sh" || rc=1
echo
echo "== DCO / Assisted-by policy =="
bash "$CI/check_dco_assistedby.sh" || rc=1
echo
echo "== MDIO bridge lifecycle =="
bash "$CI/check_mdio_bridge.sh" || rc=1
echo
echo "== checksum/stat offload path =="
bash "$CI/check_offload_path.sh" || rc=1
echo
echo "== build wrapper / BTF path =="
bash "$CI/check_build_makefile.sh" || rc=1
echo
echo "== RTL8125B hardware init parity =="
bash "$CI/check_hw_init.sh" || rc=1
echo
echo "== deferred to guest CI (need validated kernel toolchain — §15 #3/#4/#5) =="
cat <<'EOF'
  - make CLIPPY=1            (kernel-build Clippy; NOT cargo clippy — plan §6.1/§11)
  - make -C $KDIR M=$PWD     (empty Rust module builds — §15 #14)
  - KASAN/KCSAN/lockdep/kmemleak/DMA_API_DEBUG guest soak (M1/M3/M5 gates)
These are stubbed, not skipped: enable in CI after the debug+Rust guest kernel
exists (see docs/VALIDATION_REPORT.md finding 2).
EOF
exit $rc
