#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Kbuild sparse gate for the cshim/Rust composite module.

set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$CI/check_kbuild_static_analyzer.sh" sparse
