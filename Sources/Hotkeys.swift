import Foundation
import AppKit

@MainActor final class HotkeyManager: ObservableObject {
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var installed = false
    @Published var running = false
    @Published var busy = false
    @Published var status = "Instale o skhd para usar atalhos em qualquer aplicativo."
    @Published var error = ""
    @Published var showError = false
    @Published var diagnostics = ""
    let root: URL
    let agent: URL
    var navigatorSource: URL? = Bundle.main.resourceURL?.appendingPathComponent("Tools/space-switch")
    let label = "local.yabai.studio.skhd"
    var tool: URL { root.appendingPathComponent("Engine/skhd") }
    var config: URL { root.appendingPathComponent("skhdrc") }
    var output: URL { root.appendingPathComponent("skhd.log") }
    var actionLog: URL { root.appendingPathComponent("hotkey-actions.log") }
    var domain: String { "gui/\(getuid())" }
    var service: String { domain + "/" + label }
    var runner: (String,[String]) async -> Result = { path, args in await execute(path, args) }
    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("YabaiStudio"), agent: URL? = nil) {
        self.root = root
        self.agent = agent ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.yabai.studio.skhd.plist")
        installed = FileManager.default.isExecutableFile(atPath: tool.path)
        error = (try? String(contentsOf: root.appendingPathComponent("skhd-error.txt"), encoding: .utf8)) ?? ""
    }
    func fail(_ text: String) {
        status = "Atalhos precisam de atenção"; error = text; showError = true
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? text.write(to: root.appendingPathComponent("skhd-error.txt"), atomically: true, encoding: .utf8)
    }
    func clearError() { error = ""; try? FileManager.default.removeItem(at: root.appendingPathComponent("skhd-error.txt")) }
    func inspect() async {
        installed = FileManager.default.isExecutableFile(atPath: tool.path)
        let result = await runner("/bin/launchctl", ["print",service])
        running = result.code == 0 && result.output.contains("state = running")
        let logs = [output, actionLog].map { url in "\(url.lastPathComponent):\n" + ((try? String(contentsOf: url, encoding: .utf8))?.suffix(10000).description ?? "Sem registros.") }.joined(separator: "\n\n")
        diagnostics = logs
        if running { status = "skhd em execução · teste os atalhos na janela desejada" }
        else if installed { status = "skhd instalado · ative os atalhos ou libere Acessibilidade" }
    }
    func install(bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("Tools/skhd")) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        clearError()
        do {
            guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) else { throw InstallError.failed("O skhd não está no pacote do app. Baixe novamente a versão completa do Studio.") }
            let check = await runner("/usr/bin/codesign", ["--verify","--strict",bundled.path])
            guard check.code == 0 else { throw InstallError.failed("O skhd incluído no app não passou na verificação de assinatura. Baixe novamente o app.\n\(check.output)") }
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: tool.path) { try FileManager.default.copyItem(at: bundled, to: tool) }
            let version = await runner(tool.path,["--version"])
            guard version.code == 0 else { throw InstallError.failed("Não foi possível executar o skhd.\n\(version.output)") }
            installed = true; status = "skhd instalado! Clique em Ativar atalhos e autorize o skhd em Acessibilidade."
        } catch { fail(error.localizedDescription) }
    }
    func servicePlist() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": label, "ProgramArguments": [tool.path,"--config",config.path],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false, "Crashed": true], "ThrottleInterval": 10,
            "ProcessType": "Interactive", "StandardOutPath": output.path, "StandardErrorPath": output.path,
            "EnvironmentVariables": ["USER": NSUserName(), "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"]
        ], format: .xml, options: 0)
    }
    func activate(yabai: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        clearError()
        guard installed else { fail("Clique primeiro em Instalar skhd."); return }
        guard FileManager.default.isExecutableFile(atPath: yabai) else { fail("Instale ou selecione o yabai na aba Conexão antes de ativar os atalhos."); return }
        do {
            // Never replace or stop an independently configured skhd instance.
            let current = await runner("/bin/launchctl",["print",service])
            let ownRunning = current.code == 0 && current.output.contains("state = running")
            let any = await runner("/usr/bin/pgrep",["-x","skhd"])
            if any.code == 0 && !ownRunning { throw InstallError.failed("Já existe outro skhd em execução. Pare essa instalação antes de ativar o skhd do Studio. Sua configuração existente não foi alterada.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: config.path) {
                let old = try Data(contentsOf: config)
                try old.write(to: root.appendingPathComponent("skhdrc.backup"), options: .atomic)
            }
            guard let helper = navigatorSource else { throw InstallError.failed("Navegador ausente no pacote.") }
            let helperTarget = root.appendingPathComponent("Engine/space-switch")
            let helperData = try Data(contentsOf: helper)
            try helperData.write(to: helperTarget, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperTarget.path)
            try HotkeyConfig.render(yabai: yabai, log: actionLog.path, navigator: helperTarget.path, skhd: tool.path).write(to: config, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try servicePlist().write(to: agent, options: .atomic)
            // Reload the job definition, not just the process: kickstart retains
            // the previously loaded KeepAlive policy until the job is re-bootstrapped.
            if current.code == 0 {
                let unloaded = await runner("/bin/launchctl", ["bootout", service])
                guard unloaded.code == 0 else { throw InstallError.failed("Os atalhos foram salvos, mas não foi possível recarregar o serviço.\n\(unloaded.output)") }
            }
            let enabled = await runner("/bin/launchctl", ["enable", service])
            guard enabled.code == 0 else { throw InstallError.failed("Os atalhos foram salvos, mas o início automático não pôde ser habilitado.\n\(enabled.output)") }
            let result = await runner("/bin/launchctl", ["bootstrap",domain,agent.path])
            guard result.code == 0 else { throw InstallError.failed("Não foi possível iniciar o skhd.\n\(result.output)") }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await inspect()
            if !running { throw InstallError.failed("O skhd ainda não está em execução. Abra Acessibilidade, ative skhd e clique em Já autorizei.\n\n\(diagnostics)") }
        } catch { fail(error.localizedDescription) }
    }
    func stop() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let state = await runner("/bin/launchctl",["print",service])
        if state.code == 0 {
            let result = await runner("/bin/launchctl",["bootout",service])
            guard result.code == 0 else { fail("Não foi possível parar os atalhos.\n\(result.output)"); return }
        }
        do { if FileManager.default.fileExists(atPath: agent.path) { try FileManager.default.removeItem(at: agent) } }
        catch { fail("O serviço parou, mas não foi possível desativar o início no login: \(error.localizedDescription)"); return }
        running = false; clearError(); status = "Atalhos desativados, inclusive no próximo login."
    }
}

import SwiftUI
struct HotkeyView: View {
    @ObservedObject var manager: HotkeyManager
    var yabai: String
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Atalhos globais com skhd", systemImage: "keyboard").font(.title2.bold()).foregroundStyle(.mint)
                Text("Shift + Option + número envia a janela em foco para a área escolhida, mesmo com o Studio fechado.").foregroundStyle(.secondary)
                if manager.busy { ProgressView("Preparando atalhos…") }
                AdaptiveRow {
                    if !manager.installed {
                        Button("Instalar skhd") { Task { await manager.install() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button(manager.running ? "Salvar e reaplicar atalhos" : "Salvar e ativar atalhos") { Task { await manager.activate(yabai: yabai) } }.buttonStyle(.borderedProminent)
                        Button("Desativar") { Task { await manager.stop() } }
                    }
                    Button("Verificar") { Task { await manager.inspect() } }
                }.disabled(manager.busy)
                Text(manager.status).font(.callout).textSelection(.enabled)
                Text("Os atalhos são salvos e iniciam no login, sem abrir o Studio. Se o macOS bloquear o teclado temporariamente durante o login, o serviço tenta novamente a cada 10 segundos. A configuração externa do skhd é preservada.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 14))
            if !manager.error.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Precisamos concluir a configuração", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.headline)
                    Text(manager.error).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Copiar detalhes") { copyError() }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            GroupBox("Permissão do macOS") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Clique em Ativar atalhos para o macOS solicitar a permissão.\n2. Em Acessibilidade, ative skhd. Se ele não aparecer, use Mostrar skhd e adicione o arquivo pelo botão +.\n3. Volte aqui e clique em Já autorizei.")
                    AdaptiveRow {
                        Button("Abrir Acessibilidade") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                        Button("Mostrar skhd") { NSWorkspace.shared.activateFileViewerSelecting([manager.tool]) }.disabled(!manager.installed)
                        Button("Já autorizei") { Task { await manager.activate(yabai: yabai) } }.disabled(!manager.installed || manager.busy)
                    }
                }.padding(10)
            }
            Text("Para mudar de área, os atalhos nativos Control + esquerda/direita precisam estar ativos em Teclado → Atalhos → Mission Control.\nAs áreas 1–7 precisam existir no Mission Control. Os atalhos atuam na janela em foco: clique nela antes de testar. Se um terminal estiver usando Entrada Segura do Teclado, desative essa opção para o skhd receber os atalhos.").font(.callout).foregroundStyle(.secondary)
            DirectWorkspaceGuideView()
            MotionGuideView(manager: manager)
            GroupBox("Atalhos recomendados") {
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("⇧ ⌥ 1–7", "Enviar janela para uma área")
                    HStack(spacing: 8) {
                        Text("Mudar para uma área").font(.callout)
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
                        } label: {
                            Image(systemName: "info.circle").foregroundStyle(.mint)
                        }
                        .buttonStyle(.plain)
                        .help("Use Control + número (por exemplo, Control + 3), o atalho nativo do macOS para ir direto à Mesa. Ative em Ajustes do Sistema → Teclado → Atalhos de Teclado → Mission Control → Mudar para Mesa. Clique para abrir os ajustes de Teclado.")
                        .accessibilityLabel("Como mudar de área com Control mais número. Abrir ajustes de Teclado do macOS.")
                        Spacer(minLength: 0)
                    }
                    shortcut("⌥ H / J / K / L", "Focar: esquerda / abaixo / acima / direita")
                    shortcut("⇧ ⌥ H / J / K / L", "Trocar posição com a janela vizinha")
                    shortcut("⌃ ⌥ H / J / K / L", "Mover e dividir o mosaico")
                    shortcut("⌥ S / G", "Focar monitor esquerdo / direito")
                    shortcut("⇧ ⌥ S / G", "Enviar janela ao monitor esquerdo / direito")
                    shortcut("⇧ ⌥ P / N", "Enviar à área anterior / próxima")
                    shortcut("⇧ ⌥ R / X / Y", "Girar / espelhar X / espelhar Y")
                    shortcut("⇧ ⌥ T / M / E", "Flutuante / maximizar / equilibrar")
                    shortcut("⌃ ⌥ Q / S / R", "Parar / iniciar / reiniciar yabai")
                }.padding(10)
            }
            DisclosureGroup("Diagnóstico e configuração") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Mostrar arquivo de atalhos") { NSWorkspace.shared.activateFileViewerSelecting([manager.config]) }.disabled(!FileManager.default.fileExists(atPath: manager.config.path))
                    Text("Reaplicar atalhos restaura o padrão do Studio e salva uma cópia do arquivo anterior em skhdrc.backup.").font(.caption).foregroundStyle(.secondary)
                    Text(manager.diagnostics.isEmpty ? "Clique em Verificar para consultar o diagnóstico." : manager.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 10)
            }
        }.task { await manager.inspect() }
        .alert("Atalhos precisam de atenção", isPresented: $manager.showError) {
            Button("Copiar detalhes") { copyError() }; Button("Fechar", role: .cancel) {}
        } message: { Text(manager.error) }
    }
    func shortcut(_ keys: String, _ title: String) -> some View {
        AdaptiveRow { Text(keys).font(.system(.caption, design: .monospaced)).foregroundStyle(.mint).frame(minWidth: 0, alignment: .leading); Text(title).font(.callout); Spacer(minLength: 0) }
    }
    func copyError() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(manager.error, forType: .string) }
}

struct MotionGuideView: View {
    @ObservedObject var manager: HotkeyManager
    var body: some View {
        GroupBox("Troca de workspace com menos animação") {
            VStack(alignment: .leading, spacing: 14) {
                Label(manager.reduceMotion ? "Reduzir movimento está ativado" : "Reduzir movimento está desativado", systemImage: manager.reduceMotion ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.headline).foregroundStyle(manager.reduceMotion ? Color.mint : Color.secondary)
                Text("O macOS controla a transição entre áreas. Ative Reduzir movimento para diminuir o efeito ao trocar de workspace.")
                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Abra Ajustes do Sistema → Acessibilidade.")
                    step("2", "Entre em Movimento. Em versões anteriores do macOS, procure em Tela ou Monitor.")
                    step("3", "Ative Reduzir movimento e volte ao Studio.")
                    step("4", "Teste Control + Option + 1 ou 2 para comparar a troca entre áreas existentes.")
                }
                AdaptiveRow {
                    Button("Abrir ajustes de Acessibilidade") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!)
                    }
                    Button("Verificar ajuste") { refresh() }
                }
                Text("Esse ajuste afeta o movimento em todo o macOS. Pode continuar existindo uma transição breve; ele não garante remover toda animação. Para desfazer, desative Reduzir movimento no mesmo local.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Ver instruções da Apple ↗", destination: URL(string: "https://support.apple.com/pt-br/guide/mac-help/mchlc03f57a1/mac")!).font(.caption)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).foregroundStyle(.mint).frame(width: 20, height: 20).background(.mint.opacity(0.1)).clipShape(Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
    func refresh() { manager.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

struct DirectWorkspaceGuideView: View {
    var body: some View {
        GroupBox("Ir direto a uma Mesa, sem passar pelas outras") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Para sair da Mesa 1 e chegar à Mesa 3 diretamente, use o atalho nativo da Mesa 3. Control + setas percorre as Mesas uma por uma; Reduzir movimento não muda esse caminho.").font(.callout)
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Crie as Mesas que deseja usar no Mission Control. As opções numeradas podem aparecer somente depois que as Mesas existirem.")
                    Text("2. Abra Ajustes do Sistema → Teclado → Atalhos de Teclado → Mission Control. Expanda a seção Mission Control, se necessário.")
                    Text("3. Ative Mudar para Mesa 1, Mudar para Mesa 2, Mudar para Mesa 3 e as demais que você usa. O nome pode aparecer como Alternar para Mesa nesta versão do macOS.")
                    Text("4. Defina Control + 1, Control + 2, Control + 3 etc. Se houver conflito, escolha outra combinação nos ajustes do macOS.")
                    Text("5. Teste Control + 3 na Mesa 1. Esse atalho escolhe a Mesa 3 diretamente; uma animação breve do macOS ainda pode existir.")
                }.font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Abrir ajustes de Teclado") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
                }
                Text("Use os atalhos configurados no macOS, como Control + 3. Os atalhos Control + Option + número do Studio ainda podem recorrer a Control + setas e passar pelas Mesas intermediárias. Ativar as opções acima não muda esse comportamento do Studio.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shift + Option + número tem outra função: enviar a janela para uma Mesa, sem acompanhar a janela.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Guia da Apple sobre várias Mesas ↗", destination: URL(string: "https://support.apple.com/pt-br/guide/mac-help/mh14112/mac")!).font(.caption)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
