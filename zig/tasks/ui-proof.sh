#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target/frontend" || exit 1

node ui_test/prepare.mjs
npx playwright test --config ui_test/playwright.proof.config.mjs
