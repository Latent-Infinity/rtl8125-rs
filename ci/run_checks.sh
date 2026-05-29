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
echo "== §6.3 disposition-counter infrastructure (static) =="
bash "$CI/check_counter_infrastructure.sh" || rc=1
echo
echo "== §15.2 cache-padding convention =="
bash "$CI/check_cache_padding.sh" || rc=1
echo
echo "== M5 NAPI contract (poll budget, IRQ masking, queue hysteresis) =="
bash "$CI/check_napi_contract.sh" || rc=1
echo
echo "== clean implementation-contract docs =="
bash "$CI/check_clean_contract_docs.sh" || rc=1
echo
echo "== bare-metal stack / teardown regression guard =="
bash "$CI/check_bare_metal_stack_teardown.sh" || rc=1
echo
echo "== DriverOwnedSkb ownership discipline (task #62) =="
bash "$CI/check_skb_ownership.sh" || rc=1
echo
echo "== cshim per-file LOC caps (task #63) =="
bash "$CI/check_cshim_loc_caps.sh" || rc=1
echo
echo "== M6 design gates (skip vacuously until impl lands) =="
bash "$CI/check_msix_static.sh" || rc=1
bash "$CI/check_isr_v2_paired.sh" || rc=1
bash "$CI/check_irq_mode_contract.sh" || rc=1
bash "$CI/check_rx_pool_pages.sh" || rc=1
bash "$CI/check_jumbo_mtu_chip.sh" || rc=1
echo
echo "== §18 kernel-build Clippy gate =="
bash "$CI/check_clippy.sh" || rc=1
echo
echo "== deferred to guest CI (need validated kernel toolchain — §15 #3/#4/#5) =="
cat <<'EOF'
  - make -C $KDIR M=$PWD     (empty Rust module builds — §15 #14)
  - KASAN/KCSAN/lockdep/kmemleak/DMA_API_DEBUG guest soak (M1/M3/M5 gates)
  - ci/check_counter_invariant.sh (runtime §6.3 invariant — needs chip)
  (the kernel-build Clippy gate above runs locally when rustc-1.93 is
   installed; it skips cleanly on hosts without the validated toolchain)
These are stubbed, not skipped: enable in CI after the debug+Rust guest kernel
exists (see docs/VALIDATION_REPORT.md finding 2).
EOF
exit $rc
