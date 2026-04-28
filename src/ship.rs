// Ship cross-machine helper as a Rust subcommand.
//
// Embeds the share/skills/aisync-ship/scripts/ helpers into the binary via
// include_str! and unpacks them to a mode-700 tmpdir at runtime, then execs
// `bash ship.sh "$@"` (via ship.sh's own #!/usr/bin/env bash shebang).
//
// Unix-only: relies on POSIX file modes (700/755) and bash. Phase 1 design
// (docs/SHIP_SKILL_DESIGN.md §7) excluded Windows host explicitly — WSL
// users get the Linux build. The Windows release target still has to
// compile cleanly though, so the module guards the unix-specific code
// behind cfg(unix) and provides a friendly stub on other platforms.

#[cfg(unix)]
pub fn run(args: &[String]) -> i32 {
    unix_impl::run(args)
}

#[cfg(not(unix))]
pub fn run(_args: &[String]) -> i32 {
    eprintln!(
        "aisync ship: unsupported on this platform.\n\
         The ship subcommand requires a POSIX environment (bash, sh, tar, ssh).\n\
         On Windows, run this from WSL or use the Linux release."
    );
    1
}

#[cfg(unix)]
mod unix_impl {
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::process::Command;
    use std::{env, fs};

    const SHIP_SH: &str = include_str!("../share/skills/aisync-ship/scripts/ship.sh");
    const FANOUT_PY: &str = include_str!("../share/skills/aisync-ship/scripts/fanout.py");
    const TRANSFORM_PY: &str =
        include_str!("../share/skills/aisync-ship/scripts/transform-settings.py");
    const INSTALL_REMOTE_SH: &str =
        include_str!("../share/skills/aisync-ship/scripts/install-remote.sh");
    const EXTRACT_CREDS_SH: &str =
        include_str!("../share/skills/aisync-ship/scripts/extract-credentials.sh");

    /// RAII guard that rm -rf's the tmpdir on drop. Only fires for normal
    /// returns; Ctrl+C / SIGTERM bypass it (acceptable for v1 — ship.sh's
    /// own traps handle its staging dir; this dir holds only the script files).
    struct TmpDir(PathBuf);
    impl Drop for TmpDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn make_tmpdir() -> std::io::Result<TmpDir> {
        let base = env::temp_dir();
        // pid + nanoseconds is enough unpredictability since the dir is mode 700.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let path = base.join(format!(
            "aisync-ship-rs.{}.{:08x}",
            std::process::id(),
            nanos
        ));
        fs::create_dir(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(TmpDir(path))
    }

    fn write_helper(dir: &std::path::Path, name: &str, content: &str) -> std::io::Result<PathBuf> {
        let path = dir.join(name);
        fs::write(&path, content)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
        Ok(path)
    }

    pub fn run(args: &[String]) -> i32 {
        let tmp = match make_tmpdir() {
            Ok(t) => t,
            Err(e) => {
                eprintln!("aisync ship: failed to create tmpdir: {e}");
                return 1;
            }
        };
        // Recreate scripts/ subdir so ship.sh's relative SCRIPT_DIR companions
        // (install-remote.sh / fanout.py / transform-settings.py / extract-
        // credentials.sh) resolve as it expects.
        let scripts_dir = tmp.0.join("scripts");
        if let Err(e) = fs::create_dir(&scripts_dir) {
            eprintln!("aisync ship: failed to create scripts dir: {e}");
            return 1;
        }
        let helpers: &[(&str, &str)] = &[
            ("ship.sh", SHIP_SH),
            ("fanout.py", FANOUT_PY),
            ("transform-settings.py", TRANSFORM_PY),
            ("install-remote.sh", INSTALL_REMOTE_SH),
            ("extract-credentials.sh", EXTRACT_CREDS_SH),
        ];
        let mut ship_sh: Option<PathBuf> = None;
        for (name, content) in helpers {
            match write_helper(&scripts_dir, name, content) {
                Ok(p) => {
                    if *name == "ship.sh" {
                        ship_sh = Some(p);
                    }
                }
                Err(e) => {
                    eprintln!("aisync ship: failed to write {name}: {e}");
                    return 1;
                }
            }
        }
        let ship_sh = match ship_sh {
            Some(p) => p,
            None => {
                eprintln!("aisync ship: ship.sh not present in helpers (build bug)");
                return 1;
            }
        };
        // Exec ship.sh directly (uses its #!/usr/bin/env bash shebang).
        // We do NOT prefix with `sh` — ship.sh uses bash-only constructs
        // (process substitution `<(...)`, [[ ]], arrays) that POSIX sh
        // (e.g. dash on Linux) doesn't support.
        let status = Command::new(&ship_sh).args(args).status();
        match status {
            Ok(s) => s.code().unwrap_or(1),
            Err(e) => {
                eprintln!("aisync ship: failed to spawn {}: {e}", ship_sh.display());
                1
            }
        }
    }
}
