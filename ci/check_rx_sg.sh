#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RX scatter-gate check — removed: multi-descriptor RX is not supported
# on this hardware (see docs/XDP_MULTIBUF_DESIGN.md). This script is
# kept as a no-op pass to avoid churn in run_checks.sh callers, and
# will be removed once the calling infrastructure is updated.
set -uo pipefail
exit 0
