#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/portable
xcrun swiftc -package-name InkFlow \
  Core/Sources/InkFlowDomain/CandidateRanking.swift \
  Core/Portable/tests/RankingReference.swift \
  -o build/portable/ranking-reference
build/portable/ranking-reference Core/Portable/fixtures/ranking-cases.json "$1/ranking-reference.json"
