import Foundation
@main struct Checks {
    static func main() async {
        var focused = 1
        var keys = 0
        var allow = true
        let nav = SpaceNavigator(runner: { _,args in
            if args.contains("--spaces") {
                let rows = (1...3).map { "{\"index\":\($0),\"display\":1,\"has-focus\":\($0 == focused ? "true" : "false")}" }.joined(separator:",")
                return (0,"["+rows+"]")
            }
            if args.first == "--key" { keys += 1; if allow { focused += args[1].contains("right") ? 1 : -1 } }
            return (0,"")
        }, pause: {})
        let fallback = await nav.navigate(to:3,yabai:"/test/yabai",skhd:"/usr/bin/true")
        assert(fallback.success && focused == 3 && keys == 2)
        let current = await nav.navigate(to:3,yabai:"/test/yabai",skhd:"/usr/bin/true")
        assert(current.success && keys == 2)
        let missing = await nav.navigate(to:7,yabai:"/test/yabai",skhd:"/usr/bin/true")
        assert(!missing.success && keys == 2)
        let back = await nav.navigate(to:1,yabai:"/test/yabai",skhd:"/usr/bin/true")
        assert(back.success && focused == 1)
        allow = false
        let blocked = await nav.navigate(to:2,yabai:"/test/yabai",skhd:"/usr/bin/true")
        assert(!blocked.success && blocked.message.contains("Mission Control"))
        print("PASS: silent yabai failure fallback, verified destination, current area no-op, missing area, left/right, disabled native shortcut")
    }
}
