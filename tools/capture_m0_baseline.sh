#!/usr/bin/env bash
# capture_m0_baseline.sh — NON-DESTRUCTIVE M0 fact discovery (plan §7 M0, §15).
#
# Captures everything in plan §7 M0 that does NOT disturb the live NIC or the
# system: hardware inventory, lspci, ethtool (read-only), IOMMU groups, kernel
# config, vermagic, Module.symvers hash, Secure Boot state, the kernel-build
# Rust-toolchain feasibility check, and a trivial OOT Rust module BUILD attempt
# (build only — never insmod; that is a later, operator-driven step).
#
# It does NOT: unbind r8169, bind vfio-pci, run iperf3, change link state, or
# install packages. Those are the destructive M0 steps (plan §15) and are out
# of scope for this script.
#
# Root is optional. Without it, root-only facts (dmidecode, full lspci -vv,
# restricted dmesg) are marked SKIPPED-NEEDS-ROOT; re-run with `sudo` to fill.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/docs/baseline"
mkdir -p "$OUT"
PCI="0000:03:00.0"            # RTL8125 on this MS-A2 (plan's 07:00.0 was an example)
IFACE="enp3s0"               # RTL8125 netdev on this host
KDIR="/lib/modules/$(uname -r)/build"
TS="$(date -u +%FT%TZ)"
have(){ command -v "$1" >/dev/null 2>&1; }
ROOT=0; [[ $(id -u) -eq 0 ]] && ROOT=1

sec(){ echo; echo "===== $* ====="; }
cap(){ # cap <file> <command...>
  local f="$OUT/$1"; shift
  { echo "# $* "; echo "# captured $TS"; echo; "$@" 2>&1; } > "$f"
  echo "  -> $f"
}

echo "M0 baseline capture @ $TS  (root=$ROOT)"
echo "RTL8125 PCI=$PCI iface=$IFACE KDIR=$KDIR"

# --- 1. Hardware inventory (plan §15 first checkbox) -------------------------
sec "1. Hardware inventory"
if [[ $ROOT -eq 1 ]] && have dmidecode; then
  cap "hw_dmidecode.txt" dmidecode -t system -t processor -t memory
else
  echo "  dmidecode: SKIPPED-NEEDS-ROOT (re-run with sudo)" | tee "$OUT/hw_dmidecode.txt"
fi
cap "hw_cpu.txt"      bash -c 'lscpu; echo; grep -m1 "model name" /proc/cpuinfo'
cap "hw_meminfo.txt"  bash -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo; free -h'
cap "hw_uname.txt"    bash -c 'uname -a; echo; cat /etc/os-release'

# --- 2. RTL8125 PCI + driver + link (read-only) -----------------------------
sec "2. RTL8125 device facts"
if [[ $ROOT -eq 1 ]]; then cap "lspci_rtl8125_vv.txt" lspci -nnvv -s "$PCI"
else cap "lspci_rtl8125_vv.txt" bash -c "lspci -nnvv -s $PCI; echo; echo '# NOTE: some capability fields require root; re-run with sudo for full ASPM/LTR/L1ss dump (plan §3.3)'"; fi
cap "lspci_rtl8125_k.txt"   lspci -nnk -s "$PCI"
cap "pci_config_ids.txt"    bash -c "cd /sys/bus/pci/devices/$PCI && for f in vendor device subsystem_vendor subsystem_device revision class; do printf '%-18s %s\n' \"\$f\" \"\$(cat \$f 2>/dev/null)\"; done"
if have ethtool; then
  cap "ethtool_drvinfo.txt" ethtool -i "$IFACE"
  cap "ethtool_link.txt"    ethtool "$IFACE"
  cap "ethtool_eee.txt"     ethtool --show-eee "$IFACE"
  cap "ethtool_features.txt" ethtool -k "$IFACE"
else
  echo "ethtool not installed" > "$OUT/ethtool_drvinfo.txt"
fi
cap "iface_state.txt" bash -c "ip -d link show $IFACE; echo; cat /sys/class/net/$IFACE/operstate 2>/dev/null; echo carrier=\$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"

# --- 3. Chip revision (plan §3.1, §16 Q1) -----------------------------------
sec "3. Chip revision"
{
  echo "# captured $TS"
  echo "PCI revision (config space): 0x$(cat /sys/bus/pci/devices/$PCI/revision 2>/dev/null | sed 's/0x//')"
  echo
  echo "## r8169/RTL8125 MAC-version lines from kernel log (authoritative sub-revision):"
  if dmesg -t >/dev/null 2>&1; then dmesg -t | grep -iE "r8169|rtl8125|RTL_GIGA|XID" | tail -20
  elif have journalctl; then journalctl -k -b 2>/dev/null | grep -iE "r8169|rtl8125|XID" | tail -20 || echo "  (dmesg restricted & journalctl empty — re-run with sudo: sudo dmesg | grep -i rtl8125)"
  else echo "  SKIPPED-NEEDS-ROOT: sudo dmesg | grep -i rtl8125"; fi
} > "$OUT/chip_revision.txt"; echo "  -> $OUT/chip_revision.txt"

# --- 4. IOMMU group + isolation (plan §8.1, §15, §16 Q2) --------------------
sec "4. IOMMU group / VFIO isolation"
{
  echo "# captured $TS"
  G=$(basename "$(readlink -f /sys/bus/pci/devices/$PCI/iommu_group 2>/dev/null)" 2>/dev/null)
  if [[ -z "$G" || "$G" == "." ]]; then
    echo "RESULT: NO IOMMU GROUP for $PCI — IOMMU likely OFF or device not bound."
    echo "        VFIO passthrough (plan §8) is NOT possible until amd_iommu=on iommu=pt is set."
  else
    echo "RTL8125 $PCI is in IOMMU group: $G"
    echo "Group $G members:"
    for d in /sys/kernel/iommu_groups/$G/devices/*; do
      dd=$(basename "$d"); echo "  $dd  $(lspci -nns "$dd" 2>/dev/null | sed "s/^$dd //")"
    done
    N=$(ls /sys/kernel/iommu_groups/$G/devices/ 2>/dev/null | wc -l)
    if [[ "$N" -eq 1 ]]; then
      echo "VERDICT: ISOLATED (group contains only the RTL8125). Plan §8 passthrough is isolation-safe."
    else
      echo "VERDICT: SHARED ($N functions). Per plan §8.2/§16 Q2 this is TEST-ONLY, NOT isolation-safe"
      echo "         unless pcie_acs_override is used (and then host memory is NOT protected)."
    fi
  fi
} > "$OUT/iommu_group.txt"; echo "  -> $OUT/iommu_group.txt"

# --- 5. Kernel config feasibility (plan §7 M0, §15) -------------------------
sec "5. Kernel config (debug/Rust feasibility)"
CFG="/boot/config-$(uname -r)"
{
  echo "# captured $TS  from $CFG"
  for k in CONFIG_RUST CONFIG_RUST_IS_AVAILABLE CONFIG_RUSTC_VERSION_TEXT \
           CONFIG_RUSTC_LLVM_VERSION CONFIG_MODVERSIONS CONFIG_DMA_API_DEBUG \
           CONFIG_DEBUG_LOCK_ALLOC CONFIG_PROVE_LOCKING CONFIG_KASAN CONFIG_KCSAN \
           CONFIG_DEBUG_KMEMLEAK CONFIG_PCIEASPM CONFIG_PCIEASPM_DEFAULT \
           CONFIG_VFIO CONFIG_VFIO_PCI CONFIG_R8169 CONFIG_PREEMPT_RT CONFIG_PREEMPT_DYNAMIC; do
    grep -E "^($k=| *# $k )" "$CFG" 2>/dev/null || echo "# $k not set / absent"
  done
} > "$OUT/kernel_config.txt"; echo "  -> $OUT/kernel_config.txt"

# --- 6. vermagic / Module.symvers / Secure Boot -----------------------------
sec "6. vermagic / Module.symvers / Secure Boot"
{
  echo "# captured $TS"
  echo "uname -r        : $(uname -r)"
  echo "vermagic(r8169) : $(modinfo -F vermagic r8169 2>/dev/null || echo '?')"
  if [[ -f "$KDIR/Module.symvers" ]]; then
    echo "Module.symvers  : $KDIR/Module.symvers"
    echo "  sha256        : $(sha256sum "$KDIR/Module.symvers" | awk '{print $1}')"
    echo "  size/lines    : $(wc -lc < "$KDIR/Module.symvers")"
  else echo "Module.symvers  : MISSING at $KDIR"; fi
} > "$OUT/vermagic_symvers.txt"; echo "  -> $OUT/vermagic_symvers.txt"
{
  echo "# captured $TS"
  if have mokutil; then mokutil --sb-state 2>&1; echo; echo "## MOK list:"; mokutil --list-enrolled 2>&1 | head -20
  else echo "mokutil absent"; fi
  echo; [[ -d /sys/firmware/efi ]] && echo "firmware: UEFI" || echo "firmware: legacy BIOS"
} > "$OUT/secureboot.txt"; echo "  -> $OUT/secureboot.txt"

# --- 7. Toolchain authority: make LLVM=1 rustavailable (plan §2, §15) -------
sec "7. Kernel-authoritative Rust toolchain"
{
  echo "# captured $TS"
  echo "## Userspace (NOT the build path — plan §6.1):"
  echo "rustc: $(rustc --version 2>/dev/null || echo absent)"
  echo "cargo: $(cargo --version 2>/dev/null || echo absent)"
  echo
  echo "## Kernel-authoritative (CONFIG_*):"
  grep -E '^CONFIG_RUSTC_VERSION_TEXT|^CONFIG_RUSTC_LLVM_VERSION' "$CFG" 2>/dev/null
  echo
  echo "## make -C $KDIR rustavailable :"
  if [[ -d "$KDIR" ]]; then make -C "$KDIR" LLVM=1 rustavailable 2>&1; echo "exit=$?"
  else echo "KDIR missing"; fi
} > "$OUT/rust_toolchain.txt"; echo "  -> $OUT/rust_toolchain.txt"

# --- 8. Trivial OOT Rust module BUILD attempt (plan §15 blocker, build-only) -
sec "8. Trivial OOT Rust module build feasibility (build only; no insmod)"
TMPD="$(mktemp -d)"
cat > "$TMPD/hello_rust_oot.rs" <<'EOF'
// Minimal OOT Rust kernel module — toolchain/metadata feasibility probe only.
// Not driver code. Plan §15 "trivial OOT Rust module builds" gate.
use kernel::prelude::*;
module! {
    type: HelloRustOot,
    name: "hello_rust_oot",
    license: "GPL",
}
struct HelloRustOot;
impl kernel::Module for HelloRustOot {
    fn init(_m: &'static ThisModule) -> Result<Self> { pr_info!("hello_rust_oot loaded\n"); Ok(HelloRustOot) }
}
EOF
echo 'obj-m += hello_rust_oot.o' > "$TMPD/Kbuild"
{
  echo "# captured $TS"
  RUSTLNK="$(readlink -f "$KDIR/rust" 2>/dev/null)"
  echo "KDIR/rust -> ${RUSTLNK:-<dangling/absent>}"
  if [[ -z "$RUSTLNK" || ! -d "$RUSTLNK" ]]; then
    echo "RESULT: BLOCKED — kernel Rust metadata tree absent (linux-lib-rust-$(uname -r) NOT installed)."
    echo "        This is the plan §13/§16 High risk. MITIGATION (operator, system change):"
    echo "          sudo apt-get install linux-lib-rust-$(uname -r)"
    echo "        then re-run this script. NOT auto-installed by this script."
  else
    echo "kernel Rust metadata present; attempting build..."
  fi
  echo
  echo "## make -C $KDIR M=$TMPD (build only):"
  make -C "$KDIR" M="$TMPD" LLVM=1 modules 2>&1 | tail -30
  echo "exit=${PIPESTATUS:-?}"
  [[ -f "$TMPD/hello_rust_oot.ko" ]] && echo "RESULT: .ko BUILT OK (load step deferred to operator with root)" \
                                     || echo "RESULT: build did NOT produce .ko (see above; expected if metadata pkg missing)"
} > "$OUT/oot_rust_buildtest.txt"; echo "  -> $OUT/oot_rust_buildtest.txt"
rm -rf "$TMPD"

# --- 9. Physical topology template (operator must complete; plan §15) -------
sec "9. Physical topology template (operator fills)"
if [[ ! -s "$OUT/TOPOLOGY.md" ]]; then
cat > "$OUT/TOPOLOGY.md" <<'EOF'
# RTL8125 physical test topology (plan §7 M0 / §15 — OPERATOR MUST COMPLETE)

Not auto-detectable. Without this, link-stability and ASPM results (plan §3.3,
M5) are not reproducible. Fill every field:

- RTL8125 RJ45 connected to: [ ] direct cable to peer  [ ] managed switch
- Switch model / firmware (if any):
- Switch port EEE / 802.3az / power-save state:
- Negotiated link speed (from ethtool_link.txt):
- Peer device NIC model:
- Peer OS / kernel version:
- Peer driver in use + version:
- Peer MTU:
- L2 isolation: is the RTL8125 port on the SAME switch domain as host mgmt? [ ] no (required) [ ] yes (NOT allowed — plan §8.1.6)
EOF
fi
echo "  -> $OUT/TOPOLOGY.md (template; complete by hand)"

sec "DONE"
echo "Artifacts in $OUT/ . Review docs/VALIDATION_REPORT.md for interpretation."
