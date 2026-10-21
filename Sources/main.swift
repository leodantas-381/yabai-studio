import SwiftUI
import AppKit
import ApplicationServices

struct Settings: Codable, Equatable {
    var layout = "bsp"
    var gap = 12.0
    var padding = 12.0
    var ratio = 0.5
    var balance = false
    var mouse = true
    var placement = "second_child"
    var modifier = "alt"
    var dropAction = "swap"
    init() {}
    enum CodingKeys: String, CodingKey { case layout, gap, padding, ratio, balance, mouse, placement, modifier, dropAction }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "bsp"
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 12
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 12
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
        balance = try c.decodeIfPresent(Bool.self, forKey: .balance) ?? false
        mouse = try c.decodeIfPresent(Bool.self, forKey: .mouse) ?? true
        placement = try c.decodeIfPresent(String.self, forKey: .placement) ?? "second_child"
        modifier = try c.decodeIfPresent(String.self, forKey: .modifier) ?? "alt"
        dropAction = try c.decodeIfPresent(String.self, forKey: .dropAction) ?? "swap"
    }
}
struct Rule: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: String
    var floating = true
    var label: String { "studio-" + id.uuidString }
    var pattern: String { "^" + NSRegularExpression.escapedPattern(for: app) + "$" }
}
struct Profile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var settings: Settings
}
struct Saved: Codable { var settings: Settings; var rules: [Rule]; var profiles: [Profile]; var binary: String }
struct Workspace: Decodable, Identifiable {
    let index: Int
    let label: String
    let display: Int
    let focused: Bool
    let fullscreen: Bool
    var id: Int { index }
    var name: String { label.isEmpty ? "Área \(index)" : "\(index) · \(label)" }
    enum CodingKeys: String, CodingKey { case index, label, display; case focused = "has-focus"; case fullscreen = "is-native-fullscreen" }
}
struct ManagedWindow: Decodable, Identifiable {
    let id: Int
    let app: String
    let title: String
    let space: Int
    let pid: Int32
    let minimized: Bool
    let hidden: Bool
    var name: String { "\(app) · \(title.isEmpty ? "Sem título" : title)" }
    enum CodingKeys: String, CodingKey { case id, app, title, space, pid; case minimized = "is-minimized"; case hidden = "is-hidden" }
}
enum WindowAction {
    static func swap(id: Int, direction: String) -> [String] { ["-m", "window", String(id), "--swap", direction] }
    static func warp(id: Int, direction: String) -> [String] { ["-m", "window", String(id), "--warp", direction] }
    static func send(id: Int, space: Int) -> [String] { ["-m", "window", String(id), "--space", String(space)] }
    static func focus(space: Int) -> [String] { ["-m", "space", "--focus", String(space)] }
}
struct Result { var code: Int32; var output: String }
func execute(_ path: String, _ args: [String], timeoutSeconds: Double = 8) async -> Result {
    await Task.detached {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); timeout.cancel()
            return Result(code: p.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { return Result(code: -1, output: error.localizedDescription) }
    }.value
}

enum InstallError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let reason) = self { return reason }; return nil }
}
struct ReleaseInfo {
    let version: String
    let hash: String
    init(script: String) throws {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let range = Range(match.range(at: 1), in: script) else { return nil }
            return String(script[range])
        }
        guard let v = capture(#"(?m)^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"\s*$"#),
              let h = capture(#"(?m)^EXPECTED_HASH="([a-f0-9]{64})"\s*$"#) else {
            throw InstallError.failed("O formato do instalador oficial mudou. Tente novamente mais tarde ou consulte o guia oficial.")
        }
        version = v; hash = h
    }
    var downloadURL: String { "https://github.com/asmvik/yabai/releases/download/v\(version)/yabai-v\(version).tar.gz" }
    func verify(_ output: String) throws {
        guard output.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) == hash else {
            throw InstallError.failed("O arquivo recebido não passou na verificação de integridade. Nada foi instalado. Tente novamente.")
        }
    }
}
struct Installer {
    static func binaryEntry(in listing: String) throws -> String {
        let entries = listing.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let entry = entries.first(where: { $0 == "archive/bin/yabai" || $0 == "./archive/bin/yabai" }) else {
            throw InstallError.failed("O pacote oficial não contém o executável esperado. Nada foi instalado.")
        }
        return entry
    }
    typealias Runner = (String, [String], Double) async -> Result
    var runner: Runner = { path, args, timeout in await execute(path, args, timeoutSeconds: timeout) }
    func install(destination: URL, progress: @MainActor (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("yabai-studio-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func checked(_ path: String, _ args: [String], timeout: Double = 20) async throws -> String {
            let r = await runner(path, args, timeout)
            guard r.code == 0 else { throw InstallError.failed("Não foi possível concluir esta etapa da instalação. Detalhes (\(URL(fileURLWithPath: path).lastPathComponent), código \(r.code)): \(r.output.prefix(1500))") }
            return r.output
        }
        await progress("Consultando a versão oficial…")
        let metadata = temp.appendingPathComponent("release.txt")
        _ = try await checked("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "60", "--output", metadata.path, "https://raw.githubusercontent.com/asmvik/yabai/master/scripts/install.sh"], timeout: 65)
        let release = try ReleaseInfo(script: String(contentsOf: metadata, encoding: .utf8))
        await progress("Baixando yabai \(release.version)… Isso pode levar alguns minutos.")
        let archive = temp.appendingPathComponent("yabai.tar.gz")
        _ = try await checked("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "180", "--output", archive.path, release.downloadURL], timeout: 185)
        await progress("Verificando o download…")
        try release.verify(try await checked("/usr/bin/shasum", ["-a", "256", archive.path]))
        let entries = try await checked("/usr/bin/tar", ["-tzf", archive.path])
        let binaryEntry = try Self.binaryEntry(in: entries)
        guard !binaryEntry.isEmpty else { throw InstallError.failed("O pacote oficial não contém o aplicativo esperado. Nada foi instalado.") }
        _ = try await checked("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path, binaryEntry])
        let candidate = temp.appendingPathComponent("archive/bin/yabai")
        let attributes = try fm.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw InstallError.failed("Arquivo inválido no pacote oficial.") }
        // Tar archives can carry Finder metadata that invalidates strict signature checks.
        _ = try await checked("/usr/bin/xattr", ["-c", candidate.path])
        _ = try await checked("/usr/bin/codesign", ["--verify", "--strict", candidate.path])
        _ = try await checked(candidate.path, ["--version"])
        await progress("Instalando no seu usuário…")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A managed destination never replaces an independently installed yabai.
        guard !fm.fileExists(atPath: destination.path) else { throw InstallError.failed("Já existe uma instalação do Studio. Use Verificar conexão para encontrá-la.") }
        try fm.copyItem(at: candidate, to: destination)
        return destination
    }
}

@MainActor final class Model: ObservableObject {
    let hotkeys = HotkeyManager()
    @Published var workspaces: [Workspace] = []
    @Published var windows: [ManagedWindow] = []
    @Published var selectedWindow = 0
    @Published var destinationSpace = 0
    @Published var workspaceMessage = "Clique em Atualizar para carregar suas áreas e janelas."
    @Published var actionError = ""
    @Published var showActionError = false
    @Published var page = "Organização"
    @Published var appName = ""
    @Published var profileName = ""
    @Published var settings = Settings()
    @Published var rules: [Rule] = ["System Settings", "Calculator", "Karabiner-Elements"].map { Rule(app: $0) }
    @Published var profiles: [Profile] = []
    @Published var binary = ""
    @Published var online = false
    @Published var busy = false
    @Published var message = "Verificando conexão…"
    @Published var log = ""
    @Published var version = ""
    @Published var installing = false
    @Published var installStage = ""
    @Published var installError = ""
    @Published var showInstallError = false
    var errorURL: URL { saveURL.deletingLastPathComponent().appendingPathComponent("installation-error.txt") }
    func reportInstallError(_ detail: String) {
        installError = detail; message = detail; showInstallError = true
        log = "Instalação: \(detail)\n" + log
        try? FileManager.default.createDirectory(at: errorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? detail.write(to: errorURL, atomically: true, encoding: .utf8)
    }
    func clearInstallError() {
        installError = ""; showInstallError = false
        try? FileManager.default.removeItem(at: errorURL)
    }
    var managedBinary: URL { URL.applicationSupportDirectory.appendingPathComponent("YabaiStudio/Engine/yabai") }
    var candidates: [String] { [managedBinary.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yabai").path, "/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"] }
    let saveURL = URL.applicationSupportDirectory.appendingPathComponent("YabaiStudio/settings.json")
    init() {
        if let d = try? Data(contentsOf: saveURL), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            settings = s.settings; rules = s.rules; profiles = s.profiles; binary = s.binary
        }
        installError = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        if !FileManager.default.isExecutableFile(atPath: binary) {
            binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(settings: settings, rules: rules, profiles: profiles, binary: binary))
            try data.write(to: saveURL, options: .atomic)
        } catch { message = "Não foi possível salvar: \(error.localizedDescription)" }
    }
    var commandRunner: ((String, [String]) async -> Result)?
    func run(_ args: [String]) async -> Result {
        guard !binary.isEmpty else { return Result(code: -1, output: "Selecione o executável do yabai em Conexão.") }
        let r: Result
        if let commandRunner { r = await commandRunner(binary, args) } else { r = await execute(binary, args) }
        log = ("$ yabai " + args.joined(separator: " ") + "\n" + r.output + "\n\n" + log).prefix(16000).description
        return r
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if !FileManager.default.isExecutableFile(atPath: binary) {
            binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
        guard !binary.isEmpty else { online = false; page = "Conexão"; message = "Vamos preparar seu Mac. Clique em Instalar yabai para começar."; return }
        let v = await run(["--version"]); version = v.output
        let r = await run(["-m", "query", "--spaces"]); online = r.code == 0
        message = online ? "Conectado ao yabai" : "Yabai indisponível: \(r.output)"
    }
    func service(_ command: String) async {
        guard !busy else { return }; busy = true
        let r = await run([command]); busy = false
        if r.code != 0 { message = r.output } else { await refresh() }
    }
    var commands: [[String]] {
        var c = [["-m", "config", "layout", settings.layout], ["-m", "config", "window_gap", "\(Int(settings.gap))"]]
        for key in ["top_padding", "bottom_padding", "left_padding", "right_padding"] { c.append(["-m", "config", key, "\(Int(settings.padding))"]) }
        c += [["-m", "config", "split_ratio", String(format: "%.2f", settings.ratio)], ["-m", "config", "auto_balance", settings.balance ? "on" : "off"], ["-m", "config", "mouse_follows_focus", settings.mouse ? "on" : "off"]]
        c += [["-m", "config", "window_placement", settings.placement], ["-m", "config", "mouse_modifier", settings.modifier], ["-m", "config", "mouse_action1", "move"], ["-m", "config", "mouse_action2", "resize"], ["-m", "config", "mouse_drop_action", settings.dropAction]]
        for r in rules { c.append(["-m", "rule", "--add", "label=\(r.label)", "app=\(r.pattern)", "manage=\(r.floating ? "off" : "on")"]) }
        return c
    }
    func loadRecommended() {
        settings = Settings()
        for name in ["System Settings", "Calculator", "Karabiner-Elements"] {
            if let index = rules.firstIndex(where: { $0.app == name }) { rules[index].floating = true }
            else { rules.append(Rule(app: name)) }
        }
        save(); message = "Padrão inspirado no guia do Josean carregado. Clique em Aplicar ao yabai."
    }
    func apply() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let snapshot = commands
        for c in snapshot {
            let r = await run(c)
            if r.code != 0 { message = "Aplicação interrompida; alguns ajustes podem ter sido aplicados. \(r.output)"; return }
        }
        save(); message = "Ajustes aplicados. Exporte para mantê-los após reiniciar o yabai."
    }
    func importLive() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        var s = settings
        for key in ["layout", "window_gap", "top_padding", "split_ratio", "auto_balance", "mouse_follows_focus"] {
            let r = await run(["-m", "config", key]); guard r.code == 0 else { message = r.output; return }
            switch key {
            case "layout": s.layout = r.output
            case "window_gap": s.gap = Double(r.output) ?? s.gap
            case "top_padding": s.padding = Double(r.output) ?? s.padding
            case "split_ratio": s.ratio = Double(r.output) ?? s.ratio
            case "auto_balance": s.balance = r.output == "on"
            default: s.mouse = r.output == "on"
            }
        }
        settings = s; save(); message = "Ajustes lidos. A margem superior será usada como margem uniforme na próxima aplicação."
    }
    func installYabai() async {
        guard !busy else { return }
        // Reuse an existing installation before downloading anything.
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            binary = found; save(); await service("--start-service"); return
        }
        clearInstallError()
        busy = true; installing = true; installStage = "Preparando instalação…"
        do {
            let installed = try await Installer().install(destination: managedBinary) { stage in
                self.installStage = stage; self.message = stage
            }
            binary = installed.path; save()
            installStage = "Iniciando yabai…"
            let started = await run(["--start-service"])
            installing = false; busy = false
            if started.code != 0 {
                reportInstallError("Yabai instalado, mas o serviço não iniciou. Abra Acessibilidade, autorize o yabai e clique em Já autorizei.\n\nDetalhes: \(started.output)")
                return
            }
            await refresh()
            if !online { message = "Yabai instalado! Agora libere o yabai em Acessibilidade e clique em Já autorizei." }
        } catch {
            installing = false; busy = false
            reportInstallError("Etapa: \(installStage)\n\n\(error.localizedDescription)")
        }
    }
    func permissionGranted() async {
        guard !busy else { return }
        await service("--restart-service")
        if online { message = "Tudo pronto! Escolha como organizar suas janelas."; page = "Organização" }
    }
    func workspaceFailure(_ text: String) {
        actionError = text; showActionError = true; workspaceMessage = text
    }
    func fetchWorkspaceData() async -> Bool {
        let spacesResult = await run(["-m", "query", "--spaces"])
        let windowsResult = await run(["-m", "query", "--windows"])
        guard spacesResult.code == 0, windowsResult.code == 0 else {
            online = false; workspaces = []; windows = []; selectedWindow = 0; destinationSpace = 0
            workspaceFailure("Não foi possível carregar suas janelas. Verifique se o yabai está iniciado e autorizado em Acessibilidade.\n\n\(spacesResult.output)\n\(windowsResult.output)")
            return false
        }
        do {
            let spaces = try JSONDecoder().decode([Workspace].self, from: Data(spacesResult.output.utf8))
            let items = try JSONDecoder().decode([ManagedWindow].self, from: Data(windowsResult.output.utf8))
            workspaces = spaces.sorted { $0.index < $1.index }
            windows = items.filter { $0.pid != ProcessInfo.processInfo.processIdentifier && !$0.hidden && !$0.minimized }.sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
            if !windows.contains(where: { $0.id == selectedWindow }) { selectedWindow = windows.first?.id ?? 0 }
            if !workspaces.contains(where: { $0.index == destinationSpace && !$0.fullscreen }) { destinationSpace = workspaces.first(where: { !$0.fullscreen && !$0.focused })?.index ?? workspaces.first(where: { !$0.fullscreen })?.index ?? 0 }
            online = true
            return true
        } catch {
            workspaces = []; windows = []; selectedWindow = 0; destinationSpace = 0
            workspaceFailure("O yabai retornou dados que o Studio não conseguiu ler.\n\n\(error.localizedDescription)")
            return false
        }
    }
    func refreshWorkspaces() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if await fetchWorkspaceData() { workspaceMessage = "\(workspaces.count) áreas de trabalho · \(windows.count) janelas disponíveis" }
    }
    func switchWorkspace(_ index: Int) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard await fetchWorkspaceData(), workspaces.contains(where: { $0.index == index }) else { return }
        let navigation = await SpaceNavigator(authorizeNative: { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }).navigate(to: index, yabai: binary, skhd: hotkeys.tool.path)
        if !navigation.success { workspaceFailure(navigation.message); return }
        if await fetchWorkspaceData() { workspaceMessage = navigation.message }
    }

    func changeWindow(direction: String, swap: Bool = true) async {
        guard !busy, selectedWindow != 0 else { return }
        let id = selectedWindow
        busy = true; defer { busy = false }
        guard await fetchWorkspaceData() else { return }
        guard windows.contains(where: { $0.id == id }) else { workspaceFailure("Essa janela já foi fechada ou não está disponível. Selecione outra janela."); return }
        let result = await run(swap ? WindowAction.swap(id: id, direction: direction) : WindowAction.warp(id: id, direction: direction))
        if result.code != 0 {
            workspaceFailure("Não foi possível mover essa janela. Ela precisa estar organizada em mosaico e ter uma janela vizinha nessa direção.\n\nDetalhes: \(result.output)"); return
        }
        if await fetchWorkspaceData() { workspaceMessage = swap ? "As janelas trocaram de lugar." : "Janela reposicionada no mosaico." }
    }
    func sendWindow() async {
        guard !busy, selectedWindow != 0, destinationSpace != 0 else { return }
        let id = selectedWindow; let target = destinationSpace
        busy = true; defer { busy = false }
        guard await fetchWorkspaceData() else { return }
        guard let window = windows.first(where: { $0.id == id }), workspaces.contains(where: { $0.index == target && !$0.fullscreen }) else { workspaceFailure("A janela ou a área escolhida não está mais disponível. Atualize e tente novamente."); return }
        guard window.space != target else { workspaceMessage = "A janela já está nessa área de trabalho."; return }
        let result = await run(WindowAction.send(id: id, space: target))
        if result.code != 0 { workspaceFailure("Não foi possível enviar a janela para a área \(target).\n\nDetalhes: \(result.output)"); return }
        if await fetchWorkspaceData() {
            if let moved = windows.first(where: { $0.id == id }), moved.space == target { workspaceMessage = "Janela enviada para a área \(target)." }
            else { workspaceMessage = "Envio solicitado. Atualize para confirmar a posição da janela." }
        }
    }
    func chooseBinary() {
        let p = NSOpenPanel(); p.message = "Selecione o executável yabai"; p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { binary = url.path; save(); Task { await refresh() } }
    }
    func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "yabai-studio.sh"
        if p.runModal() == .OK, let url = p.url {
            func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/sh\n# Gerado pelo Yabai Studio. Execute depois da sua configuração existente.\nset -e\nYABAI=" + quote(binary.isEmpty ? "/opt/homebrew/bin/yabai" : binary) + "\n" + commands.map { "\"$YABAI\" " + $0.map(quote).joined(separator: " ") }.joined(separator: "\n") + "\n"
            do { try script.write(to: url, atomically: true, encoding: .utf8); message = "Configuração exportada para \(url.lastPathComponent)." } catch { message = error.localizedDescription }
        }
    }
}

struct Preview: View {
    @Environment(\.studioCompact) var compact
    var s: Settings
    var body: some View {
        GeometryReader { g in
            let gap = CGFloat(s.gap) / 2
            ZStack {
                LinearGradient(colors: [Color(red: 0.11, green: 0.19, blue: 0.26), Color(red: 0.25, green: 0.40, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if s.layout == "bsp" {
                    HStack(spacing: gap) {
                        tile("Safari", "globe", .teal).frame(width: max(30, (g.size.width - CGFloat(s.padding) - gap) * s.ratio))
                        VStack(spacing: gap) { tile("Notas", "note.text", .orange); tile("Finder", "folder", .blue) }
                    }.padding(CGFloat(s.padding) / 2 + 8)
                } else if s.layout == "stack" { tile("Safari · 3 janelas empilhadas", "square.3.layers.3d", .teal).padding(CGFloat(s.padding) / 2 + 8) }
                else { tile("Safari", "globe", .teal).frame(width: g.size.width * 0.56, height: g.size.height * 0.65).offset(x: -g.size.width * 0.08, y: -g.size.height * 0.04); tile("Notas", "note.text", .orange).frame(width: g.size.width * 0.4, height: g.size.height * 0.5).offset(x: g.size.width * 0.18, y: g.size.height * 0.12) }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }.frame(height: compact ? 180 : 265).clipped().overlay(alignment: .bottomTrailing) { Text("PRÉVIA ILUSTRATIVA").font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(10).foregroundStyle(.white.opacity(0.6)) }
    }
    func tile(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 12) {
            HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 6, height: 6) }; Spacer() }
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.35)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(height: 6).padding(.trailing, 25)
            Spacer(minLength: 0)
        }.padding(compact ? 8 : 13).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.10, green: 0.13, blue: 0.17)).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.35)))
    }
}
private struct CompactStudioKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var studioCompact: Bool {
        get { self[CompactStudioKey.self] }
        set { self[CompactStudioKey.self] = newValue }
    }
}
struct AdaptiveRow<Content: View>: View {
    @Environment(\.studioCompact) var compact
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing)) : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct Content: View {
    var body: some View {
        GeometryReader { geometry in
            ContentBody().environment(\.studioCompact, geometry.size.width < 880)
        }.frame(minWidth: 360, minHeight: 360)
    }
}
struct ContentBody: View {
    @Environment(\.studioCompact) var compact
    @EnvironmentObject var m: Model
    let pages = [("Atalhos", "keyboard"), ("Organização", "rectangle.3.group"), ("Aplicativos", "app.badge"), ("Perfis", "square.stack.3d.up"), ("Conexão", "bolt.horizontal.circle")]
    var body: some View {
        HStack(spacing: 0) {
            if !compact {
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(nsImage: NSImage(named: "AppIcon") ?? NSImage()).resizable().scaledToFit().frame(width: 42, height: 42); VStack(alignment: .leading) { Text("yabai").font(.title2.bold()); Text("STUDIO").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(.secondary) } }.padding(.bottom, 32)
                ForEach(pages, id: \.0) { item in
                    Button { m.page = item.0 } label: { Label(item.0, systemImage: item.1).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(m.page == item.0 ? Color.mint.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).foregroundStyle(m.page == item.0 ? Color.mint : Color.secondary)
                }
                Spacer()
                Label(m.online ? "Yabai conectado" : "Sem conexão", systemImage: "circle.fill").font(.caption).foregroundStyle(m.online ? .mint : .orange)
                Text("Seu espaço, do seu jeito.").font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
            }.frame(width: 205).background(.black.opacity(0.16))
            Divider()
            }
            VStack(alignment: .leading, spacing: 12) {
                if compact {
                    Picker("Seção", selection: $m.page) {
                        ForEach(pages, id: \.0) { item in Text(item.0).tag(item.0) }
                    }.pickerStyle(.menu)
                }
                HStack { VStack(alignment: .leading, spacing: 5) { Text(m.page).font(.system(size: compact ? 23 : 29, weight: .bold)); Text(subtitle).foregroundStyle(.secondary) }; Spacer(); if m.busy { ProgressView().controlSize(.small) } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch m.page {
                        case "Atalhos": HotkeyView(manager: m.hotkeys, yabai: m.binary)
                        case "Organização": organization
                        case "Aplicativos": applications
                        case "Perfis": profiles
                        default: connection
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Text(m.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            }.padding(compact ? 16 : 24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark).tint(.mint)
        .alert("Não foi possível concluir a instalação", isPresented: $m.showInstallError) {
            Button("Copiar detalhes") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.installError, forType: .string) }
            Button("Fechar", role: .cancel) {}
        } message: { Text(m.installError) }
        .alert("Não foi possível concluir a ação", isPresented: $m.showActionError) {
            Button("Copiar detalhes") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.actionError, forType: .string) }
            Button("Fechar", role: .cancel) {}
        } message: { Text(m.actionError) }
        .task { await m.refresh() }
        .onChange(of: m.settings) { m.save() }
        .onChange(of: m.rules) { m.save() }
    }
    var subtitle: String {
        switch m.page { case "Atalhos": "Controle suas janelas sem tirar as mãos do teclado."; case "Organização": "Encontre o equilíbrio entre suas janelas."; case "Aplicativos": "Um comportamento para cada aplicativo."; case "Perfis": "Salve um espaço para cada momento."; default: "Tudo pronto para organizar seu Mac." }
    }
    var workspaceControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdaptiveRow { Label("Áreas de trabalho", systemImage: "rectangle.on.rectangle").font(.headline); Spacer(); Button("Atualizar") { Task { await m.refreshWorkspaces() } }.disabled(m.busy) }
            if m.workspaces.isEmpty {
                Text("Suas áreas aparecem aqui quando o yabai estiver conectado. Crie novas áreas pelo Mission Control do macOS.").foregroundStyle(.secondary)
            }
            ForEach(m.workspaces) { space in
                AdaptiveRow {
                    Image(systemName: space.focused ? "rectangle.inset.filled" : "rectangle") .foregroundStyle(space.focused ? Color.mint : Color.secondary)
                    VStack(alignment: .leading) { Text(space.name).fontWeight(.medium); Text("Monitor \(space.display)" + (space.fullscreen ? " · Tela cheia" : "")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if space.focused { Text("Atual").font(.caption).foregroundStyle(.mint) }
                    else { Button("Ir para esta área") { Task { await m.switchWorkspace(space.index) } }.disabled(m.busy) }
                }.padding(12).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Text("Organizar uma janela").font(.headline)
            Text("Escolha a janela que deseja mover. A seleção permanece a mesma quando você clica no Studio.").font(.callout).foregroundStyle(.secondary)
            Picker("Janela", selection: $m.selectedWindow) {
                Text("Selecione uma janela").tag(0)
                ForEach(m.windows) { window in Text("\(window.name) · Área \(window.space)").tag(window.id) }
            }.disabled(m.busy || m.windows.isEmpty)
            GroupBox("Trocar de lado com uma janela vizinha") {
                VStack(spacing: 10) {
                    directionButton("Acima", icon: "arrow.up", direction: "north")
                    HStack { directionButton("Esquerda", icon: "arrow.left", direction: "west"); directionButton("Direita", icon: "arrow.right", direction: "east") }
                    directionButton("Abaixo", icon: "arrow.down", direction: "south")
                    Text("As duas janelas trocam de posição no mosaico.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity)
            }.disabled(m.busy || m.selectedWindow == 0)
            GroupBox("Enviar para outra área de trabalho") {
                AdaptiveRow {
                    Picker("Destino", selection: $m.destinationSpace) {
                        Text("Selecione uma área").tag(0)
                        ForEach(m.workspaces.filter { !$0.fullscreen }) { space in Text(space.name).tag(space.index) }
                    }
                    Button("Enviar janela") { Task { await m.sendWindow() } }.buttonStyle(.borderedProminent).disabled(m.selectedWindow == 0 || m.destinationSpace == 0)
                }.padding(12)
            }.disabled(m.busy)
            Text(m.workspaceMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Enviar mantém você na área atual. Use Ir para esta área para acompanhar a janela. Janelas flutuantes e em tela cheia podem não aceitar a troca de lado.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func directionButton(_ title: String, icon: String, direction: String) -> some View {
        Button { Task { await m.changeWindow(direction: direction) } } label: { Label(title, systemImage: icon).frame(minWidth: 105) }
    }
    var organization: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 4) { Text("Um bom ponto de partida").font(.headline); Text("Padrão inspirado no setup do Josean.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Usar padrão recomendado") { m.loadRecommended() }.disabled(m.busy)
            }
            Preview(s: m.settings)
            Picker("Organização", selection: $m.settings.layout) { Text("Mosaico").tag("bsp"); Text("Pilha").tag("stack"); Text("Livre").tag("float") }.pickerStyle(.segmented)
            GroupBox { VStack(spacing: 16) { slider("Espaço entre janelas", value: $m.settings.gap, range: 0...40, suffix: "px"); slider("Margens uniformes", value: $m.settings.padding, range: 0...80, suffix: "px"); VStack(alignment: .leading, spacing: 6) { HStack { Text("Proporção da divisão"); Spacer(); Text("\(Int(m.settings.ratio * 100))%").monospacedDigit() }; Slider(value: $m.settings.ratio, in: 0.2...0.8, step: 0.05) } }.padding(10) }
            Toggle("Equilibrar janelas automaticamente", isOn: $m.settings.balance)
            Toggle("Mover o cursor para a janela focada", isOn: $m.settings.mouse)
            GroupBox("Mouse e novas janelas") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Novas janelas", selection: $m.settings.placement) { Text("À direita ou abaixo").tag("second_child"); Text("À esquerda ou acima").tag("first_child") }
                    Picker("Tecla para arrastar", selection: $m.settings.modifier) { Text("Option ⌥").tag("alt"); Text("Control ⌃").tag("ctrl"); Text("Command ⌘").tag("cmd"); Text("Shift ⇧").tag("shift"); Text("Fn").tag("fn") }
                    Picker("Soltar no centro de outra janela", selection: $m.settings.dropAction) { Text("Trocar de lugar").tag("swap"); Text("Empilhar").tag("stack") }
                    Text("Segure a tecla escolhida: arraste com o botão esquerdo para mover ou com o direito para redimensionar.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            Text("Aplicar altera os padrões globais. Áreas de trabalho com ajustes próprios podem manter suas exceções.").font(.caption).foregroundStyle(.secondary)
            AdaptiveRow { Button("Ler do yabai") { Task { await m.importLive() } }.disabled(!m.online || m.busy); Button("Exportar…") { m.export() }; Spacer(); Button("Aplicar ao yabai") { Task { await m.apply() } }.buttonStyle(.borderedProminent).disabled(!m.online || m.busy) }
        }
    }
    func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) \(suffix)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: 1)
        }
    }
    var applications: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Regras pelo nome exato do aplicativo", systemImage: "slider.horizontal.3").font(.headline)
            Text("Use o nome exibido pelo aplicativo, como Finder ou Safari. As regras valem para novas janelas e são enviadas ao clicar em Aplicar.").foregroundStyle(.secondary)
            AdaptiveRow { TextField("Nome do aplicativo", text: $m.appName); Button("Adicionar") { let name = m.appName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty && !m.rules.contains(where: { $0.app == name }) { m.rules.append(Rule(app: name)); m.appName = "" } }.disabled(m.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || m.busy) }
            if m.rules.isEmpty { ContentUnavailableView("Cada app tem seu espaço", systemImage: "macwindow.on.rectangle", description: Text("Adicione um aplicativo para escolher se suas janelas ficam livres ou organizadas.")) }
            ForEach($m.rules) { $r in
                AdaptiveRow { Image(systemName: "app.fill").foregroundStyle(.mint); Text(r.app).fontWeight(.medium); Spacer(); Picker("Modo", selection: $r.floating) { Text("Flutuante").tag(true); Text("Organizado").tag(false) }.labelsHidden().frame(width: 150); Button { let removed = r; Task { if m.online { m.busy = true; let result = await m.run(["-m", "rule", "--remove", removed.label]); m.busy = false; if result.code != 0 { m.message = "Não foi possível remover a regra no yabai: \(result.output)"; return } }; m.rules.removeAll { $0.id == removed.id } } } label: { Image(systemName: "trash") }.disabled(m.busy) }.padding().background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button("Aplicar ajustes e regras") { Task { await m.apply() } }.buttonStyle(.borderedProminent).disabled(!m.online || m.busy)
            Text("Excluir uma regra ativa exige conexão. Excluir não reposiciona janelas já abertas. Regras criadas fora deste app são preservadas.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var profiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdaptiveRow { TextField("Nome do perfil", text: $m.profileName); Button("Salvar atual") { m.profiles.append(Profile(name: m.profileName, settings: m.settings)); m.profileName = ""; m.save() }.disabled(m.profileName.trimmingCharacters(in: .whitespaces).isEmpty) }
            Text("Perfis guardam layout, margens, espaçamento e comportamento do cursor. As regras por aplicativo são compartilhadas entre todos os perfis.").foregroundStyle(.secondary)
            ForEach(m.profiles) { p in AdaptiveRow { Label(p.name, systemImage: "square.stack.3d.up"); Spacer(); Button("Carregar ajustes") { m.settings = p.settings; m.message = "Perfil carregado: \(p.name). Revise e clique em Aplicar na aba Organização." }; Button(role: .destructive) { m.profiles.removeAll { $0.id == p.id }; m.save() } label: { Image(systemName: "trash") } }.padding().background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10)) }
        }
    }
    func setupStep(_ number: String, _ title: String, _ detail: String, done: Bool) -> some View {
        AdaptiveRow(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : number + ".circle").font(.title2).foregroundStyle(done ? Color.mint : Color.secondary)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer()
        }.padding(.vertical, 6)
    }
    var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !m.installError.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A instalação precisa de atenção", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    Text(m.installError).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    AdaptiveRow {
                        Button("Copiar detalhes") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.installError, forType: .string) }
                        if m.binary.isEmpty { Button("Tentar novamente") { Task { await m.installYabai() } }.disabled(m.busy) }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 18) {
                Label(m.online ? "Seu Mac está pronto" : "Vamos preparar seu Mac", systemImage: m.online ? "checkmark.seal.fill" : "sparkles").font(.title2.bold()).foregroundStyle(.mint)
                Text("O Studio cuida da instalação. Você só precisa liberar uma permissão do macOS.").foregroundStyle(.secondary)
                setupStep("1", "Instalar yabai", "Baixamos a versão oficial e instalamos só para seu usuário. Não precisa de Terminal nem de Homebrew.", done: !m.binary.isEmpty)
                if m.installing {
                    AdaptiveRow { ProgressView().controlSize(.small); Text(m.installStage).font(.callout) }.padding(.vertical, 6)
                } else if m.binary.isEmpty {
                    Button { Task { await m.installYabai() } } label: { Label("Instalar yabai", systemImage: "arrow.down.circle.fill").padding(.horizontal, 12).padding(.vertical, 6) }.buttonStyle(.borderedProminent).disabled(m.busy)
                } else {
                    Label("Yabai instalado", systemImage: "checkmark").font(.callout).foregroundStyle(.mint)
                }
                Divider()
                setupStep("2", "Permitir organizar as janelas", "Abra Acessibilidade, ative o yabai na lista e volte aqui. Se ele não aparecer, clique em + e selecione o arquivo pelo botão abaixo.", done: m.online)
                AdaptiveRow {
                    Button("Abrir Acessibilidade") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.disabled(m.binary.isEmpty || m.busy)
                    Button("Mostrar yabai") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.binary)]) }.disabled(m.binary.isEmpty || m.busy)
                }
                AdaptiveRow {
                    if m.online {
                        Button("Começar a organizar") { m.page = "Organização" }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Já autorizei · continuar") { Task { await m.permissionGranted() } }.buttonStyle(.borderedProminent).disabled(m.binary.isEmpty || m.busy)
                    }
                }
            }.padding(22).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 16))
            DisclosureGroup("Opções avançadas e diagnóstico") {
                VStack(alignment: .leading, spacing: 14) {
                    AdaptiveRow { Text(m.binary.isEmpty ? "Nenhuma instalação encontrada" : m.binary).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Spacer(); Button("Selecionar existente…") { m.chooseBinary() }.disabled(m.busy) }
                    AdaptiveRow { Button("Verificar conexão") { Task { await m.refresh() } }; Button("Iniciar yabai") { Task { await m.service("--start-service") } }; Button("Parar yabai") { Task { await m.service("--stop-service") } } }.disabled(m.busy || m.binary.isEmpty)
                    Text(m.version).font(.caption).foregroundStyle(.secondary)
                    Link("Guia oficial de instalação ↗", destination: URL(string: "https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release)")!)
                    ScrollView { Text(m.log.isEmpty ? "Nenhum comando executado." : m.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160)
                }.padding(.top, 12)
            }
        }
    }

}



@main struct StudioApp: App {
    @StateObject var model = Model()
    var body: some Scene {
        WindowGroup("Yabai Studio") { Content().environmentObject(model) }.defaultSize(width: 860, height: 680).windowResizability(.contentMinSize)
        MenuBarExtra("Yabai Studio", systemImage: "square.split.2x2") {
            Text(model.online ? "Yabai conectado" : "Yabai desconectado")
            Button("Abrir Studio") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            Divider()
            Button("Iniciar yabai") { Task { await model.service("--start-service") } }.disabled(model.busy || model.binary.isEmpty)
            Button("Parar yabai") { Task { await model.service("--stop-service") } }.disabled(model.busy || model.binary.isEmpty)
            Button("Verificar conexão") { Task { await model.refresh() } }
            Button("Abrir atalhos") { model.page = "Atalhos"; NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            Divider(); Button("Sair") { NSApp.terminate(nil) }
        }
    }
}
