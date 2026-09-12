#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only

set -euo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_PASSES="${TEST_PASSES:-1}"

for ((pass = 1; pass <= TEST_PASSES; pass++)); do
	for test_file in "$TEST_ROOT"/tests/test-*.sh; do
		bash "$test_file"
	done
done
