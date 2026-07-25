//
//  SettingsContent.swift
//  Monobs
//

import AppKit
import Combine
import SwiftUI
import MonobsKit

// CAP-10 (UI) — l'écran de réglages des hôtes.
//
// Jusqu'à v1, la seule façon de configurer Monobs était d'écrire
// `~/.config/monobs/hosts.toml` à la main dans un terminal : un destinataire non
// développeur ne pouvait pas démarrer. Cet écran ferme ce trou, et rien d'autre :
//
//  • il LIT l'état du disque via le parser EXISTANT (`HostConfigLoader`) — c'est
//    ce qui garantit la compatibilité descendante : un fichier d'époque v0.2.0,
//    commentaires compris, est lu à l'identique et arrive pré-rempli ici ;
//  • il ÉCRIT via `HostConfigWriter` (T8), qui reste seul propriétaire de la
//    sérialisation, de l'atomicité et de la garde fail-closed ;
//  • il ne SONDE RIEN. Aucune validation réseau à la saisie : l'app est
//    read-only sur les serveurs (I3) et un hôte encore éteint doit pouvoir être
//    configuré. La validation locale se limite à ce que le format exige.
//
// Fail-closed (décision de tranche) : si le fichier présent sur disque n'est pas
// reproductible par le writer (hors subset documenté, diagnostic du parser,
// UTF-8 illisible), l'édition est REFUSÉE — pas de « Enregistrer », pas de
// bouton « remplacer quand même ». Le writer expose bien un opt-in
// `replacingUnreadableConfiguration`, mais v1 ne l'expose PAS dans l'interface :
// un fichier écrit à la main que nous ne savons pas relire est du travail
// humain, et le seul chemin non destructif est de le montrer, de le localiser,
// et de laisser son auteur le réparer. Aucune surface de l'app ne peut donc
// détruire une configuration qu'elle ne comprend pas.

// MARK: - État du fichier de configuration

/// Ce que l'écran a trouvé sur disque à l'ouverture. Trois cas seulement, et
/// c'est ce qui pilote toute l'interface : premier lancement, édition normale,
/// refus fail-closed.
enum HostConfigurationState {
    /// Aucun fichier : premier lancement. Éditable, liste vide.
    case absent(URL)
    /// Fichier lu sans le moindre diagnostic — donc reproductible par le writer.
    case editable(URL, [ObservedHost])
    /// Fichier hors du subset documenté : jamais écrasé (fail-closed).
    case blocked(URL, [String])

    var url: URL {
        switch self {
        case .absent(let url), .editable(let url, _), .blocked(let url, _): return url
        }
    }

    var hosts: [ObservedHost] {
        if case .editable(_, let hosts) = self { return hosts }
        return []
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

// MARK: - Brouillon d'un hôte

/// Un hôte en cours de saisie. Distinct d'`ObservedHost` : les champs sont des
/// chaînes libres (le port est un texte tant qu'il n'est pas valide) et
/// l'identité stable est un `UUID` de vue, pas le `host` — sans quoi renommer un
/// hôte réinitialiserait la ligne en cours d'édition.
struct HostDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var host: String = ""
    var user: String = ""
    var port: String = ""
    var identity: String = ""

    init() {}

    /// Pré-remplissage depuis le fichier existant (compatibilité descendante).
    init(_ observed: ObservedHost) {
        name = observed.name
        host = observed.host
        user = observed.user
        port = String(observed.port)
        identity = observed.identity ?? ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
    }

    var trimmedName: String { trimmed(name) }
    var trimmedHost: String { trimmed(host) }
    var trimmedUser: String { trimmed(user) }
    var trimmedPort: String { trimmed(port) }
    var trimmedIdentity: String { trimmed(identity) }

    /// Libellé de la ligne — jamais vide, pour que la carte reste identifiable
    /// avant même que l'utilisateur ait tapé quoi que ce soit.
    var rowTitle: String {
        if !trimmedName.isEmpty { return trimmedName }
        if !trimmedHost.isEmpty { return trimmedHost }
        return "Nouvel hôte"
    }

    /// Le port effectif : vide = le défaut documenté (22), comme le parser.
    var effectivePort: Int { Int(trimmedPort) ?? 22 }

    var observedHost: ObservedHost {
        ObservedHost(name: trimmedName,
                     host: trimmedHost,
                     user: trimmedUser,
                     port: effectivePort,
                     identity: trimmedIdentity.isEmpty ? nil : trimmedIdentity)
    }

    /// Les scalaires que le subset ne sait pas représenter (miroir de la liste
    /// privée du writer). Comparaison sur les scalaires unicode, jamais sur les
    /// `Character` : `\r\n` est un seul grapheme et passerait sous le radar.
    private static func containsUnrepresentableScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\"" || $0 == "\n" || $0 == "\r" }
    }

    /// Validation LOCALE minimale : uniquement ce que le format exige. Elle
    /// double volontairement les refus du writer (T8) pour les dire en clair
    /// AVANT le clic, mais elle ne le remplace pas — le writer reste l'autorité.
    var problems: [String] {
        var problems: [String] = []
        if trimmedName.isEmpty { problems.append("« Nom » est obligatoire.") }
        if trimmedHost.isEmpty { problems.append("« Hôte » est obligatoire.") }
        if trimmedUser.isEmpty { problems.append("« Utilisateur » est obligatoire.") }
        if !trimmedPort.isEmpty {
            guard let port = Int(trimmedPort), (1...65535).contains(port) else {
                problems.append("« Port » doit être un entier entre 1 et 65535 (vide = 22).")
                return problems
            }
        }
        // Le subset documenté n'a AUCUNE séquence d'échappement : un guillemet ou
        // un saut de ligne collé dans un champ ne pourrait pas être relu tel
        // quel. Le writer refuserait ; on le dit ici, champ par champ.
        let fields = [("Nom", trimmedName),
                      ("Hôte", trimmedHost),
                      ("Utilisateur", trimmedUser),
                      ("Clé", trimmedIdentity)]
        for (label, value) in fields where HostDraft.containsUnrepresentableScalar(value) {
            problems.append("« \(label) » contient un guillemet ou un saut de ligne, que le format ne sait pas représenter.")
        }
        return problems
    }
}

// MARK: - Modèle de l'écran

/// L'état de l'écran de réglages. Il ne dérive aucun état produit : il lit le
/// disque, tient des brouillons, délègue l'écriture à T8 et la reprise de la
/// surveillance à T9 (via `apply`).
final class SettingsModel: ObservableObject {
    @Published private(set) var configurationState: HostConfigurationState
    @Published var drafts: [HostDraft]
    /// Dernier refus (validation locale ou writer), affiché tel quel.
    @Published private(set) var failure: String?
    /// Dernière réussite, pour que « ça a marché » soit visible sans animation.
    @Published private(set) var confirmation: String?

    /// Reconfiguration du runtime (T9). Injectée : l'écran ne connaît ni la
    /// boucle de polling ni le store.
    private let apply: ([ObservedHost]) -> Void

    init(apply: @escaping ([ObservedHost]) -> Void) {
        self.apply = apply
        let state = SettingsModel.readConfiguration()
        configurationState = state
        drafts = state.hosts.map(HostDraft.init)
    }

    /// Relit le disque et repart de ce qu'il contient. Appelée à chaque
    /// réouverture de la fenêtre : le fichier reste la source de vérité, y
    /// compris s'il a été modifié à la main entre-temps.
    func reload() {
        let state = SettingsModel.readConfiguration()
        configurationState = state
        drafts = state.hosts.map(HostDraft.init)
        failure = nil
        confirmation = nil
    }

    func addDraft() {
        drafts.append(HostDraft())
        confirmation = nil
    }

    func removeDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
        confirmation = nil
    }

    var isBlocked: Bool { configurationState.isBlocked }

    /// Chemin affiché à l'utilisateur, abrégé en `~/…` — l'écran doit pouvoir
    /// dire OÙ vit la configuration sans exposer le nom de compte.
    var displayedPath: String {
        (configurationState.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Problèmes de saisie, ligne par ligne, plus les doublons d'hôte (le `host`
    /// est l'identifiant stable : deux lignes identiques perdraient une entrée à
    /// la relecture).
    var validationProblems: [String] {
        var problems = drafts.flatMap { draft in
            draft.problems.map { "\(draft.rowTitle) : \($0)" }
        }
        var seen = Set<String>()
        for draft in drafts where !draft.trimmedHost.isEmpty {
            if !seen.insert(draft.trimmedHost).inserted {
                problems.append("L'hôte « \(draft.trimmedHost) » apparaît deux fois : il sert d'identifiant unique.")
            }
        }
        return problems
    }

    var canSave: Bool { !isBlocked && validationProblems.isEmpty }

    /// Enregistre puis reconfigure. L'ordre est le contrat : le disque d'abord
    /// (source de vérité), la surveillance ensuite. Si l'écriture échoue, rien
    /// n'est reconfiguré — l'app continue d'observer exactement ce qu'elle
    /// observait.
    func save() {
        failure = nil
        confirmation = nil
        guard !isBlocked else {
            failure = "La configuration présente sur disque n'est pas modifiable depuis l'app."
            return
        }
        let problems = validationProblems
        guard problems.isEmpty else {
            failure = problems.joined(separator: "\n")
            return
        }
        let hosts = drafts.map(\.observedHost)
        do {
            // T8 : sérialisation du subset documenté, écriture ATOMIQUE, garde
            // fail-closed re-vérifiée ici (le fichier a pu changer depuis la
            // lecture — c'est le writer qui tranche, pas notre lecture d'écran).
            try HostConfigWriter.write(hosts)
            // T9 : la surveillance suit, sans relancer l'app.
            apply(hosts)
            configurationState = SettingsModel.readConfiguration()
            drafts = configurationState.hosts.map(HostDraft.init)
            confirmation = hosts.isEmpty
                ? "Configuration enregistrée : plus aucun hôte n'est surveillé."
                : "Configuration enregistrée — la surveillance de \(hosts.count) hôte\(hosts.count > 1 ? "s" : "") a été reprise sans relancer Monobs."
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Relecture : si le refus vient d'un fichier devenu illisible, l'écran
            // bascule immédiatement en mode bloqué plutôt que de laisser croire
            // qu'un nouveau clic passerait.
            configurationState = SettingsModel.readConfiguration()
        }
    }

    /// Montre le fichier dans le Finder. Utile UNIQUEMENT dans le cas bloqué :
    /// c'est le seul état où l'utilisateur doit reprendre la main à la main.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configurationState.url])
    }

    /// Miroir en LECTURE de la garde privée du writer
    /// (`refuseUnreadableExistingConfiguration`) : mêmes règles, aucune écriture.
    /// Il ne remplace pas la garde — il permet seulement à l'interface de refuser
    /// l'édition AVANT que l'utilisateur ait tapé quoi que ce soit, au lieu de le
    /// laisser saisir dix hôtes pour se faire jeter au clic.
    ///
    /// Le chemin passe par `HostConfigWriter.destinationURL()` : même seam
    /// `MONOBS_HOSTS_FILE`, même défaut que le lecteur — l'écran ne peut pas
    /// regarder un autre fichier que celui que l'app observe.
    private static func readConfiguration() -> HostConfigurationState {
        let url = HostConfigWriter.destinationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent(url)
        }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            return .blocked(url, ["le fichier n'est pas de l'UTF-8 lisible"])
        }
        let parsed = HostConfigLoader.parse(text)
        guard parsed.diagnostics.isEmpty else {
            return .blocked(url, parsed.diagnostics)
        }
        return .editable(url, parsed.hosts)
    }
}

// MARK: - Vue

/// L'écran de réglages. Même registre visuel que le popover (thème Braise), en
/// version OPAQUE : une fenêtre n'est pas un popover, elle ne compose pas de
/// vibrancy — et le repli opaque est déjà le rendu d'accessibilité (CAP-6).
/// I8 : aucune animation, aucun état transitoire animé.
struct SettingsContent: View {
    @ObservedObject var model: SettingsModel
    let onClose: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var increasedContrast: Bool { colorSchemeContrast == .increased }
    private var hairline: Color { increasedContrast ? Theme.hairContrast : Theme.hair }
    private var controlBorderColor: Color {
        increasedContrast ? Theme.controlBorderContrast : Theme.controlBorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(hairline)
            content(for: model.configurationState)
            Divider().overlay(hairline)
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .background { Theme.popoverOpaqueGradient.transaction { $0.animation = nil } }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hôtes surveillés")
                    .font(Theme.sans(Theme.fsH1, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(model.displayedPath)
                    .font(Theme.mono(Theme.fsMeta))
                    .foregroundStyle(increasedContrast ? Theme.muted : Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            if !model.isBlocked {
                actionButton(systemImage: "plus", title: "Ajouter un hôte", ink: Theme.ink) {
                    model.addDraft()
                }
            }
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space6)
    }

    // MARK: Corps, selon l'état du fichier

    @ViewBuilder
    private func content(for state: HostConfigurationState) -> some View {
        switch state {
        case .blocked(_, let diagnostics):
            blockedPanel(diagnostics)
        case .absent, .editable:
            if model.drafts.isEmpty {
                emptyState
            } else {
                editor
            }
        }
    }

    /// Premier lancement : l'écran ne montre pas un formulaire vide, il DIT quoi
    /// faire. C'est le point exact où CAP-10 se gagne ou se perd.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aucun hôte pour l'instant")
                .font(Theme.sans(Theme.fsHost, .semibold))
                .foregroundStyle(Theme.ink)
            Text("""
                 Ajoutez un serveur pour démarrer la surveillance. Il vous faut son \
                 adresse (nom Tailscale ou IP) et le nom d'utilisateur SSH utilisé \
                 pour s'y connecter. La surveillance démarre dès l'enregistrement, \
                 sans relancer Monobs.
                 """)
                .font(Theme.sans(Theme.fsBody))
                .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            actionButton(systemImage: "plus", title: "Ajouter un hôte", ink: Theme.ink) {
                model.addDraft()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Refus fail-closed. Aucune action destructive n'est proposée : pas de
    /// « remplacer quand même », pas de sauvegarde automatique. On montre ce
    /// qu'on n'a pas su lire, et où.
    private func blockedPanel(_ diagnostics: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.redText)
                Text("Configuration non modifiable depuis l'app")
                    .font(Theme.sans(Theme.fsHost, .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text("""
                 Le fichier de configuration contient quelque chose que Monobs ne \
                 sait pas relire. Il n'a pas été modifié et ne le sera pas : éditer \
                 depuis l'app le réécrirait entièrement et détruirait ce qui s'y \
                 trouve. Corrigez-le, puis relisez-le.
                 """)
                .font(Theme.sans(Theme.fsBody))
                .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(diagnostic)
                            .font(Theme.mono(Theme.fsMetric))
                            .foregroundStyle(Theme.redText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.space5)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(Theme.surfaceDetail)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(controlBorderColor, lineWidth: 0.5)
            )
            HStack(spacing: 10) {
                actionButton(systemImage: "folder", title: "Afficher dans le Finder", ink: Theme.ink2) {
                    model.revealInFinder()
                }
                actionButton(systemImage: "arrow.clockwise", title: "Relire le fichier", ink: Theme.ink2) {
                    model.reload()
                }
            }
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Le formulaire. Une carte par hôte : ajout, modification et retrait
    /// vivent au même endroit, sans navigation.
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($model.drafts) { $draft in
                    card($draft)
                }
            }
            .padding(.horizontal, Theme.space7)
            .padding(.vertical, Theme.space6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(_ draft: Binding<HostDraft>) -> some View {
        let problems = draft.wrappedValue.problems
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(draft.wrappedValue.rowTitle)
                    .font(Theme.sans(Theme.fsHost, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button {
                    model.removeDraft(id: draft.wrappedValue.id)
                } label: {
                    Image(systemName: "trash")
                        .font(Theme.sans(Theme.fsBody, .medium))
                        .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .fill(Theme.controlFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .strokeBorder(controlBorderColor, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Retirer cet hôte")
                .accessibilityLabel("Retirer l'hôte \(draft.wrappedValue.rowTitle)")
            }
            HStack(alignment: .top, spacing: 10) {
                field("Nom", placeholder: "serveur web", text: draft.name)
                field("Hôte", placeholder: "vps-web.example", text: draft.host)
            }
            HStack(alignment: .top, spacing: 10) {
                field("Utilisateur", placeholder: "deploy", text: draft.user)
                field("Port", placeholder: "22", text: draft.port).frame(width: 84)
                field("Clé SSH (optionnel)", placeholder: "~/.ssh/id_ed25519", text: draft.identity)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(Theme.sans(Theme.fsMeta))
                            .foregroundStyle(Theme.redText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Theme.space5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(Theme.surfaceDetail)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(controlBorderColor, lineWidth: 0.5)
        )
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.sans(Theme.fsMeta, .medium))
                .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.sans(Theme.fsBody))
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pied

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            status
            Spacer(minLength: 12)
            actionButton(systemImage: "xmark", title: "Fermer", ink: increasedContrast ? Theme.ink2 : Theme.muted) {
                onClose()
            }
            if !model.isBlocked {
                actionButton(systemImage: "checkmark",
                             title: "Enregistrer",
                             ink: model.canSave ? Theme.ink : Theme.faint) {
                    model.save()
                }
                .disabled(!model.canSave)
                .help("Écrit la configuration et reprend la surveillance")
            }
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space5)
        .background(increasedContrast ? Theme.surfaceFooterContrast : Theme.surfaceFooter)
    }

    @ViewBuilder
    private var status: some View {
        if let failure = model.failure {
            Text(failure)
                .font(Theme.sans(Theme.fsMeta))
                .foregroundStyle(Theme.redText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if let confirmation = model.confirmation {
            Text(confirmation)
                .font(Theme.sans(Theme.fsMeta))
                .foregroundStyle(Theme.greenText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Les modifications s'appliquent à l'enregistrement.")
                .font(Theme.sans(Theme.fsMeta))
                .foregroundStyle(increasedContrast ? Theme.muted : Theme.faint)
                .lineLimit(1)
        }
    }

    // MARK: Chrome commun

    /// Même registre que les contrôles du popover : pastille mate, jamais un
    /// bouton d'accent — l'accent Braise reste réservé aux ÉTATS.
    private func actionButton(systemImage: String,
                              title: String,
                              ink: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(Theme.sans(Theme.fsBody, .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(Theme.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(controlBorderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
