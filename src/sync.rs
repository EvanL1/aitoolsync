use std::fs;
use std::path::{Path, PathBuf};
use crate::platforms::{Platform, PLATFORMS, UNIVERSAL_ROOT_MD};

const SOURCE_DIR: &str = ".agents";
const INIT_TEMPLATE: &str = "# Agent Instructions\n\nShared instructions for all AI coding agents.\n";

pub struct SyncResult {
    pub platform: String,
    pub files_synced: usize,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
}

pub fn detect_platforms(project_dir: &Path) -> Vec<&'static Platform> {
    PLATFORMS
        .iter()
        .filter(|p| project_dir.join(p.project_dir).exists())
        .collect()
}

/// Sync from .agents/ source to all (or specified) platforms
pub fn sync_project(project_dir: &Path, targets: &[&str], dry_run: bool) -> Vec<SyncResult> {
    let source = project_dir.join(SOURCE_DIR);
    if !source.exists() {
        eprintln!("No {} directory found. Run `aisync init` first.", SOURCE_DIR);
        return vec![];
    }

    let platforms: Vec<&Platform> = if targets.is_empty() {
        PLATFORMS.iter().collect()
    } else {
        targets.iter().filter_map(|t| crate::platforms::find_platform(t)).collect()
    };

    // Sync AGENTS.md to project root (universal)
    let root_md_src = source.join("AGENTS.md");
    if root_md_src.exists() && !dry_run {
        let _ = fs::copy(&root_md_src, project_dir.join(UNIVERSAL_ROOT_MD));
    }

    platforms.iter().map(|p| sync_platform(project_dir, &source, p, dry_run)).collect()
}

fn sync_platform(project_dir: &Path, source: &Path, platform: &Platform, dry_run: bool) -> SyncResult {
    let mut result = SyncResult {
        platform: platform.name.to_string(),
        files_synced: 0,
        errors: vec![],
        warnings: vec![],
    };

    let target_base = project_dir.join(platform.project_dir);

    // 1. Root MD: AGENTS.md → platform's root md
    let root_md_src = source.join("AGENTS.md");
    if root_md_src.exists() {
        let dest = if platform.root_md_in_subdir {
            target_base.join(platform.root_md)
        } else {
            project_dir.join(platform.root_md)
        };

        if dry_run {
            result.files_synced += 1;
        } else {
            match ensure_copy(&root_md_src, &dest) {
                Ok(_) => result.files_synced += 1,
                Err(e) => result.errors.push(format!("{}: {e}", platform.root_md)),
            }
        }
    }

    // 2. Rules — respect platform's extension convention
    if let Some(rules_subdir) = platform.rules_dir {
        let rules_src = source.join("rules");
        if rules_src.is_dir() {
            let rules_dest = target_base.join(rules_subdir);
            result.files_synced += sync_rules(&rules_src, &rules_dest, platform.rules_ext, &mut result.errors, dry_run);
        }
    }

    // 3. Skills
    if let Some(skills_subdir) = platform.skills_dir {
        let skills_src = source.join("skills");
        if skills_src.is_dir() {
            let skills_dest = target_base.join(skills_subdir);
            if platform.skills_as_dir {
                result.files_synced += sync_skills_dir(&skills_src, &skills_dest, &mut result.errors, dry_run, &mut result.warnings);
            } else {
                result.files_synced += copy_md_dir(&skills_src, &skills_dest, &mut result.errors, dry_run, &mut result.warnings);
            }
        }
    }

    // 4. Agents
    if let Some(agents_subdir) = platform.agents_dir {
        let agents_src = source.join("agents");
        if agents_src.is_dir() {
            let agents_dest = target_base.join(agents_subdir);
            result.files_synced += copy_md_dir(&agents_src, &agents_dest, &mut result.errors, dry_run, &mut result.warnings);
        }
    }

    // 5. Platform-specific extras
    let extras_src = source.join("platforms").join(platform.name);
    if extras_src.is_dir() {
        result.files_synced += sync_extras(&extras_src, &target_base, platform, &mut result.errors, dry_run);
    }

    result
}

/// Sync rules with extension conversion:
///   .md source → .mdc for Cursor
///   .md source → .instructions.md for Copilot
fn sync_rules(src: &Path, dest: &Path, target_ext: &str, errors: &mut Vec<String>, dry_run: bool) -> usize {
    let mut count = 0;
    let entries = match fs::read_dir(src) {
        Ok(e) => e,
        Err(e) => { errors.push(format!("read {}: {e}", src.display())); return 0; }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") { continue; }

        let stem = path.file_stem().unwrap().to_string_lossy();
        let dest_name = if target_ext == "md" {
            format!("{stem}.md")
        } else if target_ext == "mdc" {
            format!("{stem}.mdc")
        } else if target_ext == "instructions.md" {
            format!("{stem}.instructions.md")
        } else {
            format!("{stem}.{target_ext}")
        };

        let dest_file = dest.join(&dest_name);
        if dry_run {
            count += 1;
        } else {
            match ensure_copy(&path, &dest_file) {
                Ok(_) => count += 1,
                Err(e) => errors.push(format!("{dest_name}: {e}")),
            }
        }
    }
    count
}

/// Copy all .md files and subdirectories recursively
fn copy_md_dir(src: &Path, dest: &Path, errors: &mut Vec<String>, dry_run: bool, warnings: &mut Vec<String>) -> usize {
    let mut count = 0;
    let entries = match fs::read_dir(src) {
        Ok(e) => e,
        Err(e) => { errors.push(format!("read {}: {e}", src.display())); return 0; }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let sub_dest = dest.join(path.file_name().unwrap());
            count += copy_md_dir(&path, &sub_dest, errors, dry_run, warnings);
        } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
            if let Some(w) = check_frontmatter(&path) {
                warnings.push(w);
            }
            let dest_file = dest.join(path.file_name().unwrap());
            if dry_run {
                count += 1;
            } else {
                match ensure_copy(&path, &dest_file) {
                    Ok(_) => count += 1,
                    Err(e) => errors.push(format!("{}: {e}", path.file_name().unwrap().to_string_lossy())),
                }
            }
        }
    }
    count
}

/// Sync skills as directories: foo.md → foo/SKILL.md
fn sync_skills_dir(src: &Path, dest: &Path, errors: &mut Vec<String>, dry_run: bool, warnings: &mut Vec<String>) -> usize {
    let mut count = 0;
    let entries = match fs::read_dir(src) {
        Ok(e) => e,
        Err(e) => { errors.push(format!("read {}: {e}", src.display())); return 0; }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") { continue; }

        if let Some(w) = check_frontmatter(&path) {
            warnings.push(w);
        }
        let stem = path.file_stem().unwrap().to_string_lossy();
        let dest_file = dest.join(stem.as_ref()).join("SKILL.md");
        if dry_run {
            count += 1;
        } else {
            match ensure_copy(&path, &dest_file) {
                Ok(_) => count += 1,
                Err(e) => errors.push(format!("{}/SKILL.md: {e}", stem)),
            }
        }
    }
    count
}

/// Check if a markdown file has valid YAML frontmatter
fn check_frontmatter(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    let fname = path.file_name()?.to_string_lossy().to_string();

    if !content.starts_with("---\n") && !content.starts_with("---\r\n") {
        return Some(format!("{fname}: missing YAML frontmatter"));
    }

    let rest = &content[4..];
    if let Some(end) = rest.find("\n---") {
        let fm = &rest[..end];
        if !fm.lines().any(|l| l.trim_start().starts_with("description:")) {
            return Some(format!("{fname}: frontmatter missing 'description'"));
        }
    } else {
        return Some(format!("{fname}: unclosed YAML frontmatter"));
    }

    None
}

/// Sync user-level configs
pub fn sync_user(home: &Path, source: &Path) -> Vec<SyncResult> {
    let root_md_src = source.join("AGENTS.md");
    let mut results = Vec::new();

    for platform in PLATFORMS {
        let user_dir_str = match platform.user_dir {
            Some(d) => d,
            None => continue,
        };

        let mut result = SyncResult {
            platform: format!("~/{}", user_dir_str.trim_start_matches("~/")),
            files_synced: 0,
            errors: vec![],
            warnings: vec![],
        };

        let user_dir = home.join(user_dir_str.trim_start_matches("~/"));

        // Root md
        if root_md_src.exists() {
            if let Some(user_md) = platform.user_root_md {
                let dest = user_dir.join(user_md);
                match ensure_copy(&root_md_src, &dest) {
                    Ok(_) => result.files_synced += 1,
                    Err(e) => result.errors.push(format!("{user_md}: {e}")),
                }
            }
        }

        // Rules
        if let Some(rules_subdir) = platform.rules_dir {
            let rules_src = source.join("rules");
            if rules_src.is_dir() {
                let rules_dest = user_dir.join(rules_subdir);
                result.files_synced += sync_rules(&rules_src, &rules_dest, platform.rules_ext, &mut result.errors, false);
            }
        }

        // Skills
        if let Some(skills_subdir) = platform.skills_dir {
            let skills_src = source.join("skills");
            if skills_src.is_dir() {
                let skills_dest = user_dir.join(skills_subdir);
                if platform.skills_as_dir {
                    result.files_synced += sync_skills_dir(&skills_src, &skills_dest, &mut result.errors, false, &mut result.warnings);
                } else {
                    result.files_synced += copy_md_dir(&skills_src, &skills_dest, &mut result.errors, false, &mut result.warnings);
                }
            }
        }

        // Agents
        if let Some(agents_subdir) = platform.agents_dir {
            let agents_src = source.join("agents");
            if agents_src.is_dir() {
                let agents_dest = user_dir.join(agents_subdir);
                result.files_synced += copy_md_dir(&agents_src, &agents_dest, &mut result.errors, false, &mut result.warnings);
            }
        }

        // Platform-specific extras
        let extras_src = source.join("platforms").join(platform.name);
        if extras_src.is_dir() {
            result.files_synced += sync_extras(&extras_src, &user_dir, platform, &mut result.errors, false);
        }

        if result.files_synced > 0 {
            results.push(result);
        }
    }
    results
}

/// Import existing platform configs into .agents/ source
pub fn import_from(project_dir: &Path, platform_name: &str) -> Result<usize, String> {
    let platform = crate::platforms::find_platform(platform_name)
        .ok_or_else(|| format!("Unknown platform: {platform_name}"))?;

    let source = project_dir.join(SOURCE_DIR);
    fs::create_dir_all(source.join("rules")).map_err(|e| e.to_string())?;
    fs::create_dir_all(source.join("skills")).map_err(|e| e.to_string())?;
    fs::create_dir_all(source.join("agents")).map_err(|e| e.to_string())?;

    let platform_dir = project_dir.join(platform.project_dir);
    let mut count = 0;

    // Import root md → AGENTS.md
    // Check project-level first, then fall back to user-level path
    let root_md = if platform.root_md_in_subdir {
        platform_dir.join(platform.root_md)
    } else {
        let project_level = project_dir.join(platform.root_md);
        if project_level.exists() {
            project_level
        } else if let Some(user_md) = platform.user_root_md {
            // Fall back to user-level: e.g. ~/.claude/CLAUDE.md
            platform_dir.join(user_md)
        } else {
            project_level
        }
    };
    if root_md.exists() {
        let dest = source.join("AGENTS.md");
        let should_copy = if !dest.exists() {
            true
        } else {
            let existing = fs::read_to_string(&dest).unwrap_or_default();
            existing.trim() == INIT_TEMPLATE.trim() || existing.trim().is_empty()
        };
        if should_copy {
            fs::copy(&root_md, &dest).map_err(|e| e.to_string())?;
            count += 1;
        }
    }

    // Import rules (convert .mdc/.instructions.md → .md)
    if let Some(rules_subdir) = platform.rules_dir {
        let rules_dir = platform_dir.join(rules_subdir);
        if rules_dir.is_dir() {
            count += import_rules(&rules_dir, &source.join("rules"), platform.rules_ext)
                .map_err(|e| e.to_string())?;
        }
    }

    // Import skills/commands
    if let Some(skills_subdir) = platform.skills_dir {
        let skills_dir = platform_dir.join(skills_subdir);
        if skills_dir.is_dir() {
            if platform.skills_as_dir {
                count += import_skills_dir(&skills_dir, &source.join("skills"))
                    .map_err(|e| e.to_string())?;
            } else {
                count += import_md_files(&skills_dir, &source.join("skills"))
                    .map_err(|e| e.to_string())?;
            }
        }
    }

    // Import agents
    if let Some(agents_subdir) = platform.agents_dir {
        let agents_dir = platform_dir.join(agents_subdir);
        if agents_dir.is_dir() {
            count += import_md_files(&agents_dir, &source.join("agents"))
                .map_err(|e| e.to_string())?;
        }
    }

    // Import platform-specific extra files and dirs
    if !platform.extra_files.is_empty() || !platform.extra_dirs.is_empty() {
        let extras_dest = source.join("platforms").join(platform.name);
        fs::create_dir_all(&extras_dest).map_err(|e| e.to_string())?;

        for file in platform.extra_files {
            let src_file = platform_dir.join(file);
            if src_file.exists() {
                let dest_file = extras_dest.join(file);
                fs::copy(&src_file, &dest_file).map_err(|e| e.to_string())?;
                count += 1;
            }
        }

        for dir in platform.extra_dirs {
            let src_dir = platform_dir.join(dir);
            if src_dir.is_dir() {
                count += copy_dir_all(&src_dir, &extras_dest.join(dir))
                    .map_err(|e| e.to_string())?;
            }
        }
    }

    Ok(count)
}

/// Import rules and normalize extension to .md
fn import_rules(src: &Path, dest: &Path, src_ext: &str) -> std::io::Result<usize> {
    fs::create_dir_all(dest)?;
    let mut count = 0;
    for entry in fs::read_dir(src)?.flatten() {
        let path = entry.path();
        let name = path.file_name().unwrap().to_string_lossy().to_string();

        // Accept matching extension
        let matches = match src_ext {
            "md" => name.ends_with(".md"),
            "mdc" => name.ends_with(".mdc"),
            "instructions.md" => name.ends_with(".instructions.md"),
            _ => name.ends_with(&format!(".{src_ext}")),
        };
        if !matches { continue; }

        // Normalize to .md
        let stem = if src_ext == "instructions.md" {
            name.strip_suffix(".instructions.md").unwrap_or(&name)
        } else {
            path.file_stem().unwrap().to_str().unwrap_or(&name)
        };
        let dest_file = dest.join(format!("{stem}.md"));
        if !dest_file.exists() {
            fs::copy(&path, &dest_file)?;
            count += 1;
        }
    }
    Ok(count)
}

/// Import directory-based skills: <name>/SKILL.md → <name>.md
fn import_skills_dir(src: &Path, dest: &Path) -> std::io::Result<usize> {
    fs::create_dir_all(dest)?;
    let mut count = 0;
    for entry in fs::read_dir(src)?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let skill_md = path.join("SKILL.md");
            if skill_md.exists() {
                let name = path.file_name().unwrap().to_string_lossy();
                let dest_file = dest.join(format!("{name}.md"));
                if !dest_file.exists() {
                    fs::copy(&skill_md, &dest_file)?;
                    count += 1;
                }
            }
        }
    }
    Ok(count)
}

fn import_md_files(src: &Path, dest: &Path) -> std::io::Result<usize> {
    fs::create_dir_all(dest)?;
    let mut count = 0;
    for entry in fs::read_dir(src)?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            // Recurse into subdirectories (e.g. _negotiation/, _shared/)
            let sub_dest = dest.join(path.file_name().unwrap());
            count += import_md_files(&path, &sub_dest)?;
        } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
            let dest_file = dest.join(path.file_name().unwrap());
            if !dest_file.exists() {
                fs::copy(&path, &dest_file)?;
                count += 1;
            }
        }
    }
    Ok(count)
}

pub fn init_source(project_dir: &Path) -> std::io::Result<PathBuf> {
    let source = project_dir.join(SOURCE_DIR);
    fs::create_dir_all(source.join("rules"))?;
    fs::create_dir_all(source.join("skills"))?;
    fs::create_dir_all(source.join("agents"))?;

    let agents_md = source.join("AGENTS.md");
    if !agents_md.exists() {
        fs::write(&agents_md, INIT_TEMPLATE)?;
    }
    Ok(source)
}

/// Sync platform-specific extra files and dirs from .agents/platforms/<name>/
fn sync_extras(extras_src: &Path, target: &Path, platform: &Platform, errors: &mut Vec<String>, dry_run: bool) -> usize {
    let mut count = 0;

    for file in platform.extra_files {
        let src = extras_src.join(file);
        if src.exists() {
            let dest = target.join(file);
            if dry_run {
                count += 1;
            } else {
                match ensure_copy(&src, &dest) {
                    Ok(_) => count += 1,
                    Err(e) => errors.push(format!("{file}: {e}")),
                }
            }
        }
    }

    for dir in platform.extra_dirs {
        let src = extras_src.join(dir);
        if src.is_dir() {
            if dry_run {
                count += 1;
            } else {
                match copy_dir_all(&src, &target.join(dir)) {
                    Ok(n) => count += n,
                    Err(e) => errors.push(format!("{dir}/: {e}")),
                }
            }
        }
    }

    count
}

/// Directories to skip when copying extras (build artifacts, caches, etc.)
const SKIP_DIRS: &[&str] = &[
    "node_modules", "target", ".git", "cache", "__pycache__",
    ".cache", "dist", "build", ".next",
];

/// Recursively copy all files in a directory (any type, not just .md)
fn copy_dir_all(src: &Path, dest: &Path) -> std::io::Result<usize> {
    fs::create_dir_all(dest)?;
    let mut count = 0;
    for entry in fs::read_dir(src)?.flatten() {
        let path = entry.path();
        let name = path.file_name().unwrap().to_string_lossy();
        if path.is_dir() {
            if SKIP_DIRS.contains(&name.as_ref()) {
                continue;
            }
            count += copy_dir_all(&path, &dest.join(name.as_ref()))?;
        } else {
            fs::copy(&path, &dest.join(name.as_ref()))?;
            count += 1;
        }
    }
    Ok(count)
}

fn ensure_copy(src: &Path, dest: &Path) -> std::io::Result<()> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dest)?;
    Ok(())
}
