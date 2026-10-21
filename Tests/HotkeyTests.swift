import Foundation
@main struct HotkeyTests {
    static func main() {
        let bindings = HotkeyConfig.bindings
        assert(Set(bindings.map(\.key)).count == bindings.count)
        for n in 1...7 {
            assert(bindings.contains { $0.key == "shift + alt - \(n)" && $0.arguments == [["-m","window","--space",String(n)]] })
        }
        let config = HotkeyConfig.render(yabai:"/tmp/My App/'yabai",log:"/tmp/log file",navigator:"/tmp/space-switch",skhd:"/tmp/skhd")
        assert(config.contains("'\\''"))
        assert(config.contains("'/tmp/space-switch' '3'"))
        assert(!config.contains("'space' '--focus'"))
        print("PASS: unique bindings, workspace send shortcuts, shell quoting and navigation routing")
    }
}
