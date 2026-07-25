import XCTest
@testable import MonobsKit

/// T10 / CAP-10 — la COMPOSITION que l'écran de réglages exécute au clic
/// « Enregistrer ».
///
/// T8 (`HostConfigWriter`) et T9 (`HostPollingLoop.reconfigure`) sont déjà
/// couverts chacun de leur côté. Ce qui ne l'était pas, c'est leur enchaînement
/// — et c'est là que vit la promesse CAP-10 : *écrire le fichier, puis
/// reconfigurer la surveillance, dans cet ordre, et ne rien reconfigurer du tout
/// si l'écriture a été refusée*. L'interface n'est pas testable ici (cible app) ;
/// sa SÉQUENCE l'est, et c'est elle qui porte le risque.
///
/// Tout passe par le seam `MONOBS_HOSTS_FILE` et un répertoire `mkdtemp` par
/// exécution : rien ici ne peut toucher un vrai `~/.config/monobs/`. Tous les
/// noms d'hôtes sont fictifs (RFC 2606 — AD-15).
final class SettingsRuntimeIntegrationTests: XCTestCase {

    private let web = ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy")
    private let db = ObservedHost(name: "database", host: "vps-db.example", user: "deploy",
                                  port: 2222, identity: "~/.ssh/monobs_report_ed25519")

    private func seam(_ file: URL) -> [String: String] {
        [HostConfigLoader.environmentVariable: file.path]
    }

    private func temporaryConfigFile() throws -> URL {
        let directory = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("hosts.toml")
    }

    /// L'ordre d'opérations de `SettingsModel.save()` : le disque d'abord
    /// (source de vérité), le runtime ensuite, et le runtime UNIQUEMENT si le
    /// disque a accepté. Rejoué ici plutôt qu'appelé depuis l'app pour que le
    /// test reste dans MonobsKit — si l'app dévie de cet ordre, c'est une revue
    /// de diff qui l'attrape, pas ce test. L'app ajoute par-dessus un
    /// `requestImmediateCycle()` (confort d'affichage) ; il ne change ni la
    /// liste observée ni l'ordre prouvé ici.
    @discardableResult
    private func save(_ hosts: [ObservedHost], to file: URL, loop: HostPollingLoop) throws -> Bool {
        try HostConfigWriter.write(hosts, environment: seam(file))
        return loop.reconfigure(hosts: hosts)
    }

    // MARK: - Premier lancement : ajouter un hôte démarre la surveillance

    func testSavingTheFirstHostStartsMonitoringWithoutRelaunch() throws {
        let file = try temporaryConfigFile()
        let scheduler = VirtualSettingsScheduler(now: 10_000_000_000)
        let polled = SettingsEventLog()

        // Premier lancement réel : aucun fichier, donc aucun hôte.
        let boot = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(boot.hosts, [])
        XCTAssertFalse(boot.diagnostics.isEmpty, "l'absence de configuration se dit, elle ne crashe pas")

        let loop = HostPollingLoop(
            hosts: boot.hosts,
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            })
        XCTAssertFalse(loop.start(), "zéro hôte : la boucle reste inerte, elle n'invente pas de cycle")
        XCTAssertEqual(scheduler.pendingCount, 0)

        // L'utilisateur saisit son premier hôte et enregistre.
        XCTAssertTrue(try save([web], to: file, loop: loop))

        // Le fichier est la source de vérité : il est relu par le parser EXISTANT.
        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, [web])
        XCTAssertEqual(reread.diagnostics, [])

        XCTAssertTrue(scheduler.runNext(), "la reconfiguration était en attente sur la file du poller")
        XCTAssertEqual(loop.observedHosts, [web])
        XCTAssertTrue(scheduler.runNext(), "l'ajout du premier hôte rallume la cadence")
        XCTAssertEqual(polled.values, ["vps-web.example"],
                       "la surveillance a démarré sans relancer l'app")
        loop.stop()
    }

    // MARK: - Modification et retrait suivent le même chemin

    func testRemovingAHostThroughTheSaveSequenceStopsPollingItAndPurgesIt() throws {
        let file = try temporaryConfigFile()
        let scheduler = VirtualSettingsScheduler(now: 10_000_000_000)
        let store = SnapshotStore()
        let polled = SettingsEventLog()
        let facts = ReportFacts(metrics: ["sample": .number(1)],
                                serverTimestamp: "2026-01-01T12:00:00Z")

        try HostConfigWriter.write([web, db], environment: seam(file))
        let boot = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(boot.hosts, [web, db], "les entrées existantes reviennent à l'identique")

        let loop = HostPollingLoop(
            hosts: boot.hosts,
            snapshotStore: store,
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .validReport(facts)
            })
        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(Set(store.allSnapshots().keys), ["vps-web.example", "vps-db.example"])

        // L'utilisateur retire `db` dans les réglages et enregistre.
        XCTAssertTrue(try save([web], to: file, loop: loop))
        XCTAssertTrue(scheduler.runNext())

        XCTAssertEqual(loop.observedHosts, [web])
        XCTAssertEqual(Set(store.allSnapshots().keys), ["vps-web.example"],
                       "l'hôte retiré ne laisse aucun état résiduel affichable")
        XCTAssertEqual(HostConfigLoader.load(environment: seam(file)).hosts, [web],
                       "le retrait est allé jusqu'au disque, pas seulement en mémoire")

        polled.reset()
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(polled.values, ["vps-web.example"], "l'hôte retiré n'est plus jamais visité")
        loop.stop()
    }

    // MARK: - Fail-closed : un refus ne touche NI le fichier NI la surveillance

    func testRefusedSaveLeavesBothTheFileAndTheMonitoringExactlyAsTheyWere() throws {
        let file = try temporaryConfigFile()
        // Configuration écrite à la main, hors du subset : la clé inconnue produit
        // un diagnostic. Les hôtes sont pourtant lisibles — c'est précisément le
        // cas piégeux : « ça se lit presque » n'autorise pas à réécrire.
        let handWritten = """
            # ma flotte — écrite à la main
            [[hosts]]
            name = "web frontend"
            host = "vps-web.example"
            user = "deploy"
            region = "eu-west"
            """
        try handWritten.write(to: file, atomically: true, encoding: .utf8)
        let existing = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(existing.hosts, [web], "le fichier reste LU comme avant — compat descendante")
        XCTAssertFalse(existing.diagnostics.isEmpty, "mais il n'est pas reproductible par le writer")

        let scheduler = VirtualSettingsScheduler(now: 10_000_000_000)
        let loop = HostPollingLoop(hosts: existing.hosts,
                                   snapshotStore: SnapshotStore(),
                                   cadence: 60,
                                   scheduler: scheduler,
                                   pollHost: { _ in .reportAbsent(exitCode: 3) })
        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())

        // L'utilisateur tente d'ajouter un hôte depuis l'app.
        XCTAssertThrowsError(try save([web, db], to: file, loop: loop)) { error in
            guard let writeError = error as? HostConfigWriteError,
                  case .existingConfigurationNotUnderstood(let diagnostics) = writeError else {
                return XCTFail("le refus doit nommer ce qui n'a pas été compris, pas échouer en silence")
            }
            XCTAssertEqual(diagnostics, existing.diagnostics,
                           "les diagnostics du parser sont remontés verbatim à l'interface")
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), handWritten,
                       "le fichier écrit à la main est intact, au commentaire près")
        XCTAssertEqual(loop.observedHosts, [web],
                       "l'écriture ayant échoué, RIEN n'a été reconfiguré")
        XCTAssertEqual(scheduler.pendingCount, 1, "aucun travail supplémentaire n'a été enfilé")
        loop.stop()
    }

    // MARK: - Compat descendante : lue à l'identique, seuls les commentaires tombent

    func testPreExistingCommentedConfigurationIsReadIdenticallyAndOnlyLosesItsComments() throws {
        let file = try temporaryConfigFile()
        let handWritten = """
            # hosts.toml — époque v0.2.0, écrit à la main
            [[hosts]]
            name = "web frontend"   # le front
            host = "vps-web.example"
            user = "deploy"

            [[hosts]]
            name = "database"
            host = "vps-db.example"
            user = "deploy"
            port = 2222
            identity = "~/.ssh/monobs_report_ed25519"
            """
        try handWritten.write(to: file, atomically: true, encoding: .utf8)

        // Point 3 de CAP-10 : mêmes hôtes, aucun diagnostic — donc l'éditeur les
        // pré-remplit tels quels.
        let preFilled = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(preFilled.hosts, [web, db])
        XCTAssertEqual(preFilled.diagnostics, [])

        // L'utilisateur ouvre les réglages et enregistre sans rien changer.
        try HostConfigWriter.write(preFilled.hosts, environment: seam(file))

        let after = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(after.hosts, preFilled.hosts, "aucune donnée perdue : les cinq clés survivent")
        XCTAssertEqual(after.diagnostics, [])

        // La perte assumée et documentée (docs/host-config.md) : les commentaires
        // de l'auteur, pas ses données.
        let rewritten = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("époque v0.2.0"))
        XCTAssertFalse(rewritten.contains("le front"))
        XCTAssertTrue(rewritten.contains("written by Monobs"),
                      "le fichier régénéré dit d'où il vient")
    }
}

// MARK: - Doubles déterministes (locaux à ce fichier)

/// Ordonnanceur virtuel mono-thread tenant lieu de file sérielle du poller.
/// Même contrat que celui des tests T9, redéclaré ici : les doubles de l'autre
/// fichier sont `private`, et un test ne modifie pas un fichier de test existant
/// pour se rendre service (I9).
private final class VirtualSettingsScheduler: HostPollingScheduling, @unchecked Sendable {
    private struct Scheduled { let deadline: UInt64; let order: UInt64; let action: @Sendable () -> Void }
    private let lock = NSLock()
    private var currentTime: UInt64
    private var nextOrder: UInt64 = 0
    private var actions: [Scheduled] = []

    init(now: UInt64) { currentTime = now }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return actions.count }

    func nowNanoseconds() -> UInt64 { lock.lock(); defer { lock.unlock() }; return currentTime }

    func schedule(at deadline: UInt64, action: @escaping @Sendable () -> Void) {
        lock.lock()
        actions.append(Scheduled(deadline: deadline, order: nextOrder, action: action))
        nextOrder &+= 1
        lock.unlock()
    }

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard let index = actions.indices.min(by: {
            (actions[$0].deadline, actions[$0].order) < (actions[$1].deadline, actions[$1].order)
        }) else { lock.unlock(); return false }
        let scheduled = actions.remove(at: index)
        currentTime = max(currentTime, scheduled.deadline)
        lock.unlock()
        scheduled.action()
        return true
    }
}

private final class SettingsEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    func reset() { lock.lock(); storage.removeAll(); lock.unlock() }
}
