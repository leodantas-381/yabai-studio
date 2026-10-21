import Foundation
@main struct StartupTests {
    static func main() throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("studio-startup-tests-"+UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        let home=root.appendingPathComponent("home")
        let support=root.appendingPathComponent("App Support/Studio's folder")
        try fm.createDirectory(at:home,withIntermediateDirectories:true)
        let paths=StartupPaths(home:home,support:support,environment:[:])
        let store=StartupPersistence(paths:paths)
        let log=root.appendingPathComponent("arguments.txt")
        let fake=root.appendingPathComponent("fake yabai's binary")
        try "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$*\" >> \(HotkeyConfig.quote(log.path))\n".write(to:fake,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:fake.path)
        let config=try paths.config()
        try fm.createDirectory(at:config.deletingLastPathComponent(),withIntermediateDirectories:true)
        let original="#!/bin/sh\n# User configuration\n/usr/bin/true\n"
        try original.write(to:config,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:config.path)
        _ = try store.install(binary:fake.path,commands:[["-m","config","window_gap","12"]])
        let saved=try String(contentsOf:config,encoding:.utf8)
        assert(saved.contains("# User configuration"))
        assert(fm.isExecutableFile(atPath:config.path))
        let backups=try fm.contentsOfDirectory(at:config.deletingLastPathComponent(),includingPropertiesForKeys:nil).filter {$0.lastPathComponent.contains("studio-backup-")}
        assert(backups.count == 1)
        assert(try! String(contentsOf:backups[0],encoding:.utf8) == original)
        func simulateStartup() throws {
            let process=Process(); process.executableURL=URL(fileURLWithPath:"/bin/sh"); process.arguments=[config.path]
            try process.run(); process.waitUntilExit(); assert(process.terminationStatus==0)
        }
        try simulateStartup()
        assert(try! String(contentsOf:log,encoding:.utf8).contains("window_gap 12"))
        _ = try store.install(binary:fake.path,commands:[["-m","config","window_gap","24"]])
        let updated=try String(contentsOf:config,encoding:.utf8)
        assert(updated.components(separatedBy:StartupPersistence.begin).count==2)
        try simulateStartup()
        assert(try! String(contentsOf:log,encoding:.utf8).split(separator:"\n").last!.contains("window_gap 24"))
        let old=home.appendingPathComponent(".yabairc")
        try "# legacy".write(to:old,atomically:true,encoding:.utf8)
        try fm.removeItem(at:config)
        assert(try! paths.config()==old)
        let link=home.appendingPathComponent(".config/yabai/yabairc")
        try fm.createSymbolicLink(at:link,withDestinationURL:old)
        assert(try! paths.config()==old)
        let custom=home.appendingPathComponent("custom-config")
        let agent=home.appendingPathComponent("Library/LaunchAgents/com.asmvik.yabai.plist")
        try fm.createDirectory(at:agent.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data=try PropertyListSerialization.data(fromPropertyList:["ProgramArguments":[fake.path,"--config",custom.path]],format:.xml,options:0)
        try data.write(to:agent)
        assert(try! paths.config()==custom)
        for invalid in ["# BEGIN YABAI STUDIO STARTUP\n", "#!/bin/sh\nexit 0\n", "#!/usr/bin/python\npass\n"] {
            do { _ = try StartupPersistence.updatedConfig(invalid,script:paths.script); fatalError("Unsupported config accepted") } catch {}
        }
        print("PASS: startup without Studio, latest saved values, exact backup, executable permissions, idempotent block, spaces/quotes, legacy config, symlink, custom launchd config, unsupported configs")
    }
}
