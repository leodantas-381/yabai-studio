#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests build/module-cache
swiftc -parse-as-library Sources/Navigator.swift Tests/NavigationTests.swift -module-cache-path build/module-cache -o build/tests/navigation
build/tests/navigation
swiftc -parse-as-library Sources/HotkeyConfig.swift Tests/HotkeyTests.swift -module-cache-path build/module-cache -o build/tests/hotkeys
build/tests/hotkeys
swiftc -parse-as-library Sources/HotkeyConfig.swift Sources/StartupPersistence.swift Tests/StartupTests.swift -module-cache-path build/module-cache -o build/tests/startup
build/tests/startup
sed '/^@main struct StudioApp/,$d' Sources/main.swift > build/tests/ServiceModel.swift
swiftc -parse-as-library build/tests/ServiceModel.swift Sources/Hotkeys.swift Sources/HotkeyConfig.swift Sources/Navigator.swift Sources/StartupPersistence.swift Tests/HotkeyServiceTests.swift -framework SwiftUI -framework AppKit -module-cache-path build/module-cache -o build/tests/hotkey-service
build/tests/hotkey-service
