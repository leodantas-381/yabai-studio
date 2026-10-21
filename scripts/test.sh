#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests build/module-cache
swiftc -parse-as-library Sources/Navigator.swift Tests/NavigationTests.swift -module-cache-path build/module-cache -o build/tests/navigation
build/tests/navigation
swiftc -parse-as-library Sources/HotkeyConfig.swift Tests/HotkeyTests.swift -module-cache-path build/module-cache -o build/tests/hotkeys
build/tests/hotkeys
