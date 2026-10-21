import Foundation
@main struct NavigatorMain {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4, let target = Int(args[1]) else { fputs("Uso: space-switch NUMERO YABAI SKHD\n",stderr); exit(2) }
        let result = await SpaceNavigator().navigate(to: target,yabai:args[2],skhd:args[3])
        print(result.message)
        exit(result.success ? 0 : 1)
    }
}
