#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

grep -Fq 'build_swift_test bundle-artifact-smoke-tests build/bundle-artifact-smoke-tests' macOS/scripts/check-bundle.sh
grep -Fq 'DYLD_LIBRARY_PATH="$app/Contents/Frameworks" build/bundle-artifact-smoke-tests "$app" "$user_dir"' macOS/scripts/check-bundle.sh
! grep -Fq 'build_swift_test engine-tests build/bundle-engine-tests' macOS/scripts/check-bundle.sh
grep -Fq '("bundle-artifact-smoke-tests", "BundleArtifactSmokeTests")' Package.swift
grep -Fq 'executableTestTarget("BundleArtifactSmokeTests", sources: ["BundleArtifactSmokeTests.swift"]' Package.swift
grep -Fq 'IFPackagedCache.descriptor(resources: resources)' macOS/Tests/BundleArtifactSmokeTests.swift
grep -Fq 'try IFEngine.start(configuration)' macOS/Tests/BundleArtifactSmokeTests.swift
grep -Fq 'try select("你好", from: engine, label: "Chinese")' macOS/Tests/BundleArtifactSmokeTests.swift
grep -Fq 'try select("hello", from: engine, label: "English Lua")' macOS/Tests/BundleArtifactSmokeTests.swift
grep -Fq 'try require(engine.takeCommit() == expected, "\(label) commit mismatch")' macOS/Tests/BundleArtifactSmokeTests.swift
grep -Fq 'PASS bundle artifact smoke:' macOS/Tests/BundleArtifactSmokeTests.swift

echo 'PASS bundle artifact smoke contract: packaged cache and minimal bundled runtime replace full engine regression'
