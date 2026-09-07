#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-common.sh
build_swift_test build/ai-runtime-tests macOS/Tests/AIDiagnosticTestSupport.swift macOS/Tests/AIRuntimeTestSupport.swift macOS/Tests/AIRuntimeTests.swift
build/ai-runtime-tests
