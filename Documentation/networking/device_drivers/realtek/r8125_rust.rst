.. SPDX-License-Identifier: GPL-2.0

====================================================
The Realtek RTL8125 Rust 2.5 Gigabit Ethernet driver
====================================================

:Module: ``r8125_rust``
:Maintainer: see ``MAINTAINERS``
:Source: ``drivers/net/ethernet/realtek/r8125_rust/`` (in-tree path)
:Out-of-tree origin: https://github.com/firestrand/rtl8125-rs

This driver targets the Realtek RTL8125-family 2.5 Gigabit Ethernet
PCIe controllers. The currently enabled hardware revisions are listed
below. It is written predominantly in Rust, with a thin C bridge
("cshim") used for the kernel networking APIs that have no stable
safe-Rust abstraction yet.

The in-tree ``r8169`` driver also supports RTL8125 hardware. This
driver exists as a Rust-for-Linux netdev prototype; its
goal is to validate (and motivate) safe-Rust netdev abstractions in
the kernel.  The Realtek RTL8125 family is a useful target because
the in-tree C driver gives us a known-good reference shape for every
hot path.

Supported hardware
==================

Confirmed-tested:

  - ``[10ec:8125]`` rev 0x05 - RTL8125B (Minisforum MS-A2 onboard NIC)

Recognized but not enabled yet:

  - Other RTL8125-family XIDs. Probe refuses them until a reviewed
    ``hw::KNOWN`` dispatch-table row and validation evidence are added.

NOT supported:

  - RTL8126 (5 Gigabit successor) - different MAC family.
  - RTL8169 (1 Gigabit predecessor) - use the in-tree ``r8169`` driver.

Module parameters
=================

All module parameters use the ``u8`` type because
``kernel::module_param`` does not yet expose signed integers or
booleans. Conventions: ``255`` = auto, ``254`` = explicit skip,
``0..253`` = explicit value.

``inject_reset_timeout``
    Force the chip-reset poll to time out so probe returns
    ``-EIO``. Testing knob only; verifies that
    `Documentation/process/probe.rst`-style probe-failure rollback
    leaves no leaked resources. Default ``0``.

``force_aspm``
    When non-zero, leave the chip's Config5 ASPM-en bit set so the
    PCIe link can enter L0s/L1 on idle. Default ``0`` (matches the
    in-tree ``r8169``'s ``rtl_hw_aspm_clkreq_enable(false)`` call).

    .. warning::
       Setting ``force_aspm=1`` is documented to provoke TX
       retransmits on some RTL8125B steppings; see the in-tree
       ``r8169`` driver's quirk list for the same behaviour.

``aspm_force_off``
    Hard-disable ASPM regardless of platform BIOS state. Default
    ``0`` (let platform decide).

``irq_pin_cpu``
    IRQ affinity hint policy. Default ``255`` (auto: pin to the
    first online CPU on the chip's PCI-local NUMA node).
    Set ``254`` to skip pinning (let ``irqbalance`` decide).
    Set ``0..253`` for an explicit CPU index; must be online.

Statistics
==========

``ethtool -S <iface>`` exposes the section 6.3 disposition counters that
the driver uses for its internal invariant check:

  - ``tx_received`` - ``ndo_start_xmit`` calls that reached DMA-map.
  - ``tx_consumed`` - successful TX completions
    (``napi_consume_skb``).
  - ``tx_busy_exception`` - ``NETDEV_TX_BUSY`` (ring full at xmit).
  - ``tx_dropped_error`` - drops before DMA (csum-help failure,
    transport header too far into the skb).
  - ``rx_handed_to_stack`` - successful ``napi_gro_receive``.
  - ``rx_dropped_error`` - skb allocation failures and chip-error
    RX drops.

The invariant
``tx_received == tx_consumed + tx_busy_exception + tx_dropped_error``
holds across module lifetime.

Soft and hardware offloads
==========================

Supported on TX:

  - Hardware TCP/UDP/IPv4 checksum
  - Hardware TCP/UDP/IPv6 checksum
  - Hardware IPv4 header checksum
  - TSO (TCPv4) with ``max_segs = 10`` and ``max_size`` honoring
    the chip's 11-bit MSS field
  - Scatter-gather DMA over the descriptor ring's 4-descriptor
    chain limit

Supported on RX:

  - Hardware TCP/UDP/IPv4/IPv6 checksum offload
  - GRO via ``napi_gro_receive``
  - VLAN strip (when chip-side VLAN ingress is configured by
    upstream userspace)

Limitations
===========

  - **No suspend / resume yet.** The driver does not register
    ``struct pci_driver::driver::pm`` ops; system suspend across the
    NIC is untested. Suspend/resume support is planned for a follow-up
    series.
  - **Single RX / single TX queue.** Multi-queue is documented as
    not-yet (the M6 design notes the additional surface area required
    in the cshim).
  - **No XDP.** The cshim does not export ``XDP_REDIRECT``-shaped
    helpers; an XDP RX path requires either an upstream safe-Rust
    XDP abstraction or a substantially larger cshim.

Performance
===========

Out-of-tree measurements on Minisforum MS-A2 (AMD Ryzen 9 9955HX,
Zen 5, 16C/32T), against an Intel I226-V peer in a peer netns:

  - guest-to-peer TCP, MTU 1500: 2.35 Gbps sustained
  - peer-to-guest TCP, MTU 1500: 1.4 Gbps sustained
  - 24 h active soak at 100 Mbps, ASPM-off: clean (no driver errors,
    no kernel-debug warnings)
  - 100-cycle ``rmmod`` under sustained traffic: clean

The cover letter for the upstream series will carry the full table.

Implementation notes
====================

For maintainers and reviewers reading the source first time:

  - All ``unsafe`` is localized to a single Rust module
    (``unsafe_boundary``), enforced by
    ``ci/check_unsafe_allowlist.sh``.
  - The C bridge (``cshim``) lives in
    ``drivers/net/ethernet/realtek/r8125_rust/`` alongside the Rust
    sources. Each bridge function carries a contract comment and a
    one-paragraph rationale on why the C side is needed.
  - The Rust hot path does not see a raw ``sk_buff`` pointer except
    as an opaque token (``DriverOwnedSkb``); ownership transitions
    are explicit at the function-boundary type level.
  - Atomic counters mutated from independent contexts (IRQ handler,
    NAPI poll, ndo_start_xmit) are cache-padded to avoid false
    sharing across CPUs. The static gate also covers file-scope
    hot-path atomics so debug counters cannot reintroduce false
    sharing.

References
==========

  - The in-tree sibling C driver: ``drivers/net/ethernet/realtek/r8169_main.c``.
  - Realtek vendor reference driver (out-of-tree, GPL): ``r8125``.
  - Rust-for-Linux project: https://rust-for-linux.com
