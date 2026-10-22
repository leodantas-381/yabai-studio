import Foundation
@main struct HotkeyServiceTests {
 @MainActor static func main() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("skhd-service-tests-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let manager=HotkeyManager(root:root,agent:root.appendingPathComponent("LaunchAgents/skhd.plist"))
    let data=try manager.servicePlist()
    let plist=try PropertyListSerialization.propertyList(from:data,format:nil) as! [String:Any]
    assert(plist["RunAtLoad"] as? Bool == true)
    let keepAlive=plist["KeepAlive"] as! [String:Bool]
    assert(keepAlive["SuccessfulExit"] == false && keepAlive["Crashed"] == true)
    assert(plist["ThrottleInterval"] as? Int == 10)
    assert(plist["ProgramArguments"] as! [String] == [manager.tool.path,"--config",manager.config.path])
    manager.installed=true; manager.navigatorSource=URL(fileURLWithPath:"/usr/bin/true")
    try FileManager.default.createDirectory(at:manager.tool.deletingLastPathComponent(),withIntermediateDirectories:true)
    var calls: [[String]]=[]
    var loaded=true
    var active=true
    manager.runner={ path,args in
        if path=="/usr/bin/pgrep" { return Result(code: active ? 0 : 1,output:active ? "123" : "") }
        calls.append(args)
        switch args.first {
        case "print": return Result(code:loaded ? 0 : 1,output:active ? "state = running" : "state = waiting")
        case "bootout": loaded=false;active=false
        case "bootstrap": loaded=true;active=true
        default: break
        }
        return Result(code:0,output:"")
    }
    await manager.activate(yabai:"/usr/bin/true")
    assert(manager.error.isEmpty)
    let unload=calls.firstIndex(where:{$0.first=="bootout"})!
    let enable=calls.firstIndex(where:{$0.first=="enable"})!
    let bootstrap=calls.firstIndex(where:{$0.first=="bootstrap"})!
    assert(unload<enable && enable<bootstrap)
    assert(!calls.contains(where:{$0.first=="kickstart"}))
    let saved=try PropertyListSerialization.propertyList(from:Data(contentsOf:manager.agent),format:nil) as! [String:Any]
    assert(saved["KeepAlive"] is [String:Bool])
    await manager.stop()
    assert(!loaded && !active && !FileManager.default.fileExists(atPath:manager.agent.path))
    print("PASS: login startup, retry after failure, throttle, stable config path, loaded job migration, enable before bootstrap, explicit stop removes login job")
 }
}
