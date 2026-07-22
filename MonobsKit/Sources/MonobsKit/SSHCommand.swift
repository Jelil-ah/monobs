import Foundation

/// Pure argv builder for the system ssh binary. All flag choices are
/// **provisional (Q4.2)** — nothing here is ratified beyond AD-9's
/// non-interactive exec:
///   -n            stdin from /dev/null (no interactive input path)
///   -T            no pty (the forced command refuses pty requests anyway)
///   BatchMode=yes never prompt (passphrase/password prompts fail instead)
///   ConnectTimeout bounded below the poll cadence
///   IdentitiesOnly=yes prevents agent-offered identities outside ssh config
///   -i adds the dedicated key when the host config names one
///   -F /dev/null prevents user/system ssh_config from adding commands,
///      proxies, Match exec hooks, tunnels, or forwarding
///   explicit `-o` policy repeats the read-only constraints as defense in depth
/// T-RO invariant: the destination is the LAST argument — no command is ever
/// requested (the server-side forced command would ignore one anyway, AD-9).
public enum SSHCommand {
    public static func arguments(host: ObservedHost,
                                 connectTimeout: Int) -> [String] {
        arguments(host: host,
                  connectTimeout: connectTimeout,
                  knownHosts: .production)
    }

    static func arguments(host: ObservedHost,
                          connectTimeout: Int,
                          knownHosts: SSHKnownHostsFiles) -> [String] {
        var args = [
            "-F", "/dev/null",
            "-n", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "IdentitiesOnly=yes",
            "-o", "RemoteCommand=none",
            "-o", "LocalCommand=none",
            "-o", "ProxyCommand=none",
            "-o", "ProxyJump=none",
            "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "KnownHostsCommand=none",
            "-o", "GlobalKnownHostsFile=\(knownHosts.global)",
            "-o", "UserKnownHostsFile=\(knownHosts.user)",
            "-o", "StrictHostKeyChecking=yes",
        ]
        if let identity = host.identity {
            // ssh does not tilde-expand -i values passed via argv; resolve
            // "~" against the real home (sandbox is off — B5).
            let expanded = (identity as NSString).expandingTildeInPath
            args += ["-i", expanded]
        }
        args += ["-p", String(host.port)]
        // End option parsing explicitly, so even malformed configuration
        // values cannot be reinterpreted as ssh flags.
        args += ["--", "\(host.user)@\(host.host)"]
        return args
    }
}

/// The test seam can replace only known-hosts paths. Production and tests use
/// the exact same sealed configuration and read-only `-o` policy above.
struct SSHKnownHostsFiles: Equatable, Sendable {
    let global: String
    let user: String

    static var production: SSHKnownHostsFiles {
        SSHKnownHostsFiles(
            global: "/etc/ssh/ssh_known_hosts",
            user: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/known_hosts").path
        )
    }
}
