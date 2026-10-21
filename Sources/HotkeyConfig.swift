import Foundation
import AppKit

struct Hotkey: Identifiable {
    let key: String
    let title: String
    let arguments: [[String]]
    var id: String { key }
}
struct HotkeyConfig {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static var bindings: [Hotkey] {
        var items: [Hotkey] = []
        func add(_ key: String, _ title: String, _ args: [String]...) { items.append(Hotkey(key: key, title: title, arguments: args)) }
        for (key, direction, name) in [("h","west","esquerda"),("j","south","abaixo"),("k","north","acima"),("l","east","direita")] {
            add("alt - \(key)", "Focar janela à \(name)", ["-m","window","--focus",direction])
            add("shift + alt - \(key)", "Trocar janela: \(name)", ["-m","window","--swap",direction])
            add("ctrl + alt - \(key)", "Reposicionar janela: \(name)", ["-m","window","--warp",direction])
        }
        for (key, direction) in [("s","west"),("g","east")] {
            add("alt - \(key)", "Focar monitor \(direction == "west" ? "esquerdo" : "direito")", ["-m","display","--focus",direction])
            add("shift + alt - \(key)", "Enviar janela ao monitor \(direction == "west" ? "esquerdo" : "direito")", ["-m","window","--display",direction], ["-m","display","--focus",direction])
        }
        add("shift + alt - r", "Girar mosaico", ["-m","space","--rotate","270"])
        add("shift + alt - x", "Espelhar eixo X", ["-m","space","--mirror","x-axis"])
        add("shift + alt - y", "Espelhar eixo Y", ["-m","space","--mirror","y-axis"])
        add("shift + alt - t", "Alternar janela flutuante", ["-m","window","--toggle","float"], ["-m","window","--grid","4:4:1:1:2:2"])
        add("shift + alt - m", "Maximizar janela no mosaico", ["-m","window","--toggle","zoom-fullscreen"])
        add("shift + alt - e", "Equilibrar mosaico", ["-m","space","--balance"])
        add("shift + alt - p", "Enviar janela à área anterior", ["-m","window","--space","prev"])
        add("shift + alt - n", "Enviar janela à próxima área", ["-m","window","--space","next"])
        for n in 1...7 {
            add("shift + alt - \(n)", "Enviar janela à área \(n)", ["-m","window","--space",String(n)])
            add("ctrl + alt - \(n)", "Ir para área \(n)", ["-m","space","--focus",String(n)])
        }
        add("ctrl + alt - q", "Parar yabai", ["--stop-service"])
        add("ctrl + alt - s", "Iniciar yabai", ["--start-service"])
        add("ctrl + alt - r", "Reiniciar yabai", ["--restart-service"])
        return items
    }
    static func render(yabai: String, log: String, navigator: String? = nil, skhd: String = "") -> String {
        "# Yabai Studio · baseado no guia do Josean\n# Option = alt. As áreas de destino precisam existir.\n" + bindings.map { binding in
            "# " + binding.title + "\n" + binding.key + " : " + binding.arguments.map { args in
                if args.count == 4 && args[0...2].elementsEqual(["-m","space","--focus"]), let navigator {
                    return "\(quote(navigator)) \(quote(args[3])) \(quote(yabai)) \(quote(skhd)) >> \(quote(log)) 2>&1"
                }
                return "\(quote(yabai)) " + args.map(quote).joined(separator: " ") + " >> \(quote(log)) 2>&1"
            }.joined(separator: " && ")
        }.joined(separator: "\n\n") + "\n"
    }
}
