import Foundation
struct NavigationSpace: Decodable {
    let index: Int
    let display: Int
    let focused: Bool
    enum CodingKeys: String, CodingKey { case index, display; case focused = "has-focus" }
}
struct NavigationResult { let success: Bool; let message: String }
struct SpaceNavigator {
    var runner: (String,[String]) async -> (Int32,String) = { path,args in
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now()+5, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
            return (process.terminationStatus,String(decoding:data,as:UTF8.self))
        } catch { return (-1,error.localizedDescription) }
    }
    var authorizeNative: () -> Bool = { true }
    var pause: () async -> Void = { try? await Task.sleep(nanoseconds: 150_000_000) }
    func spaces(_ yabai: String) async -> [NavigationSpace]? {
        let (code,text) = await runner(yabai,["-m","query","--spaces"])
        guard code == 0 else { return nil }
        return try? JSONDecoder().decode([NavigationSpace].self, from: Data(text.utf8))
    }
    func navigate(to target: Int, yabai: String, skhd: String) async -> NavigationResult {
        guard let initial = await spaces(yabai), let destination = initial.first(where: {$0.index == target}) else {
            return NavigationResult(success:false,message:"A área \(target) não existe ou o yabai está desconectado. Crie a área no Mission Control e tente novamente.")
        }
        if destination.focused { return NavigationResult(success:true,message:"Você já está na área \(target).") }
        let (_, directError) = await runner(yabai,["-m","space","--focus",String(target)])
        for _ in 0..<5 {
            await pause()
            if let latest = await spaces(yabai), latest.contains(where: {$0.index == target && $0.focused}) { return NavigationResult(success:true,message:"Área \(target) ativada.") }
        }
        guard FileManager.default.isExecutableFile(atPath:skhd) else {
            return NavigationResult(success:false,message:"O yabai não confirmou a mudança. Instale e autorize o skhd na aba Atalhos para usar a navegação nativa.\n\(directError)")
        }
        guard authorizeNative() else {
            return NavigationResult(success:false,message:"Para mudar de área pelos botões, autorize também o Yabai Studio em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade. Depois tente novamente. O skhd já tem uma permissão separada.")
        }
        if initial.first(where: { $0.focused })?.display != destination.display {
            return NavigationResult(success:false,message:"Não foi possível mudar automaticamente para outro monitor. Foque uma janela nesse monitor e tente novamente.")
        }
        for _ in 0..<initial.count {
            guard let current = await spaces(yabai), let active = current.first(where: {$0.focused}), active.display == destination.display else { break }
            if active.index == target { return NavigationResult(success:true,message:"Área \(target) ativada.") }
            let ordered = current.filter {$0.display == destination.display}.sorted {$0.index < $1.index}
            guard let source = ordered.firstIndex(where: {$0.index == active.index}), let end = ordered.firstIndex(where: {$0.index == target}) else { break }
            let key = source < end ? "right" : "left"
            let (code,error) = await runner(skhd,["--key","ctrl - \(key)"])
            if code != 0 { return NavigationResult(success:false,message:"Não foi possível enviar o atalho nativo. Autorize skhd em Acessibilidade.\n\(error)") }
            var changed = false
            for _ in 0..<10 {
                await pause()
                if let updated = await spaces(yabai), let focused = updated.first(where: {$0.focused}), focused.index != active.index { changed = true; break }
            }
            if !changed { return NavigationResult(success:false,message:"O macOS não respondeu ao atalho. Em Teclado → Atalhos → Mission Control, ative Mover um espaço para a esquerda/direita com Control + setas. Confira também Acessibilidade do skhd e Entrada Segura do Teclado.") }
        }
        if let final = await spaces(yabai), final.contains(where: {$0.index == target && $0.focused}) { return NavigationResult(success:true,message:"Área \(target) ativada.") }
        return NavigationResult(success:false,message:"A mudança de área não foi confirmada. Atualize a lista e tente novamente.")
    }
}
