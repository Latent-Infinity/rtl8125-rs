#!/usr/bin/env bash
# CI orchestrator. Runs the mechanical checks that do NOT need the
# kernel build toolchain (those run in the guest CI job once the
# validated kernel toolchain is available). Designed to pass early and
# tighten as code lands.
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
echo "== hardware offload feature advertisement =="
bash "$CI/check_hw_offload_features.sh" || rc=1
echo
echo "== RX skb-build hot path =="
bash "$CI/check_rx_skb_build.sh" || rc=1
echo
echo "== native XDP contract =="
bash "$CI/check_xdp_contract.sh" || rc=1
echo
echo "== full-RSS queue-aware bridge contract =="
bash "$CI/check_rss_queue_contract.sh" || rc=1
echo
echo "== RTL8125B RSS hardware programming contract =="
bash "$CI/check_rss_hw_programming.sh" || rc=1
echo
echo "== ethtool RSS control-plane contract =="
bash "$CI/check_rss_ethtool.sh" || rc=1
echo
echo "== Wake-on-LAN suspend-path contract =="
bash "$CI/check_wol_suspend.sh" || rc=1
echo
echo "== PHY LED netdev-trigger offload contract =="
bash "$CI/check_led.sh" || rc=1
echo
echo "== AF_XDP zero-copy datapath contract =="
bash "$CI/check_xsk.sh" || rc=1
echo
echo "== TX-slot disposition parity (hot vs stop reaper) =="
bash "$CI/check_tx_disposition.sh" || rc=1
echo
echo "== TX-offload descriptor-bit policy boundary (Rust) =="
bash "$CI/check_tx_offload_policy.sh" || rc=1
echo
echo "== devlink health-reporter contract =="
bash "$CI/check_devlink.sh" || rc=1
echo
echo "== PCIe AER recovery contract =="
bash "$CI/check_aer.sh" || rc=1
echo
echo "== PCI runtime-PM (autosuspend) contract =="
bash "$CI/check_runtime_pm.sh" || rc=1
echo
echo "== multi-queue RSS hazard harness contract =="
bash "$CI/check_rss_multiqueue_hazard.sh" || rc=1
echo
echo "== build/test orchestration contract =="
bash "$CI/check_orchestration_contract.sh" || rc=1
echo
echo "== statistical sweep harness (stats self-test) =="
bash "$CI/check_sweep_stats.sh" || rc=1
echo
echo "== netdev robustness contract (MAC fallback / tx_timeout / get_stats64) =="
bash "$CI/check_netdev_robustness.sh" || rc=1
echo
echo "== netdev/ethtool surface inventory (upstream gap-closure tracking) =="
bash "$CI/check_surface_inventory.sh" || rc=1
echo
echo "== build wrapper / BTF path =="
bash "$CI/check_build_makefile.sh" || rc=1
echo
echo "== Rust source formatting =="
bash "$CI/check_rustfmt.sh" || rc=1
echo
echo "== Host-side Rust contract fuzz/test gate =="
bash "$CI/check_driver_contract_fuzz.sh" || rc=1
echo
echo "== RTL8125B hardware init parity =="
bash "$CI/check_hw_init.sh" || rc=1
echo
echo "== disposition-counter infrastructure (static) =="
bash "$CI/check_counter_infrastructure.sh" || rc=1
echo
echo "== cache-padding convention =="
bash "$CI/check_cache_padding.sh" || rc=1
echo
echo "== NAPI contract (poll budget, IRQ masking, queue hysteresis) =="
bash "$CI/check_napi_contract.sh" || rc=1
echo
echo "== RX descriptor stride agreement (read/write/publish vs format) =="
bash "$CI/check_rx_desc_stride.sh" || rc=1
echo
echo "== host unit tests (pure layout/RSS math - rustc --test) =="
bash "$CI/check_rust_unit_tests.sh" || rc=1
echo
echo "== BQL sent/completed accounting contract =="
bash "$CI/check_bql_accounting.sh" || rc=1
echo
echo "== clean implementation-contract docs =="
bash "$CI/check_clean_contract_docs.sh" || rc=1
echo
echo "== no panic-style driver exits =="
bash "$CI/check_no_panic_paths.sh" || rc=1
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
echo "== Tier 3c aspm_force_off operator-knob contract =="
bash "$CI/check_aspm_force_off_param.sh" || rc=1
echo
echo "== Latency-aligned discipline (TSTATS, IRQ affinity, tx_queue_len) =="
bash "$CI/check_latency_knobs.sh" || rc=1
echo
echo "== soak harness false-pass guards =="
bash "$CI/check_soak_harness.sh" || rc=1
echo
echo "== DMA barriers (RX read + TX/RX publish) =="
bash "$CI/check_dma_barriers.sh" || rc=1
echo
echo "== checkpatch.pl on cshim (kernel-community style gate) =="
bash "$CI/check_checkpatch.sh" || rc=1
echo
echo "== cshim global-symbol hygiene =="
bash "$CI/check_no_bridge_exports.sh" || rc=1
echo
echo "== sparse/smatch on cshim (kernel static-analysis gates) =="
bash "$CI/check_sparse.sh" || rc=1
bash "$CI/check_smatch.sh" || rc=1
echo
echo "== upstream-style selftest shape =="
bash "$CI/check_selftest_smoke.sh" || rc=1
echo
echo "== MSI-X / RSS design gates =="
bash "$CI/check_msix_static.sh" || rc=1
bash "$CI/check_isr_v2_paired.sh" || rc=1
bash "$CI/check_irq_mode_contract.sh" || rc=1
bash "$CI/check_rx_pool_pages.sh" || rc=1
bash "$CI/check_jumbo_mtu_chip.sh" || rc=1
echo
echo "== kernel-build Clippy gate (default cfgs) =="
bash "$CI/check_clippy.sh" || rc=1
echo
echo "== full-cfg Clippy gate (cfg-gated PCI surfaces, patched tree) =="
bash "$CI/check_clippy_fullcfg.sh" || rc=1
echo
echo "== deferred to guest CI (need validated kernel toolchain) =="
cat <<'EOF'
  - make -C $KDIR M=$PWD     (empty Rust module builds)
  - KASAN/KCSAN/lockdep/kmemleak/DMA_API_DEBUG guest soak
  - ci/check_counter_invariant.sh (runtime invariant — needs chip)
  (the kernel-build Clippy gate above runs locally when rustc-1.93 is
   installed; it skips cleanly on hosts without the validated toolchain)
These are stubbed, not skipped: enable in CI after the debug+Rust guest kernel
exists (see docs/VALIDATION_REPORT.md finding 2).
EOF
exit $rc
