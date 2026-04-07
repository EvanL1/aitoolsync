// Platform definitions — verified config paths for each AI coding tool
//
// Sources (verified 2026-03):
//   Claude Code: https://code.claude.com/docs/en/skills
//   Codex CLI:   https://github.com/openai/codex (source inspection)
//   Gemini CLI:  https://github.com/google-gemini/gemini-cli (docs/)
//   Cursor:      https://cursor.com/docs/context/rules
//   Copilot:     https://docs.github.com/copilot/customizing-copilot/adding-custom-instructions-for-github-copilot
//   Windsurf:    https://docs.windsurf.com/windsurf/cascade/memories.md
//   Cline:       https://docs.cline.bot/customization/overview

pub struct Platform {
    pub name: &'static str,

    // Root instruction file
    pub root_md: &'static str,            // filename: CLAUDE.md, AGENTS.md, GEMINI.md, etc.
    pub root_md_in_subdir: bool,          // true = inside project_dir, false = project root

    // Project-level directories
    pub project_dir: &'static str,        // .claude, .cursor, .github, etc.
    pub rules_dir: Option<&'static str>,  // subdirectory for rules (None = not supported)
    pub rules_ext: &'static str,          // file extension for rules: "md", "mdc", "instructions.md"
    pub skills_dir: Option<&'static str>, // subdirectory for skills/commands
    pub skills_as_dir: bool,              // true = <name>/SKILL.md directory format
    pub agents_dir: Option<&'static str>, // subdirectory for agents

    // Platform-specific extra configs (stored in .agents/platforms/<name>/)
    pub extra_files: &'static [&'static str],  // individual files: settings.json, .mcp.json
    pub extra_dirs: &'static [&'static str],   // directories: hooks/, plugins/, output-styles/

    // User-level (global) directory
    pub user_dir: Option<&'static str>,   // ~/.claude, ~/.codex, ~/.gemini, etc.
    pub user_root_md: Option<&'static str>, // root md filename in user dir (may differ)
}

pub const PLATFORMS: &[Platform] = &[
    // ── Claude Code ──
    // CLAUDE.md at project root, .claude/{rules,skills,agents}/*.md
    // Skills: .claude/skills/<name>/SKILL.md (directory per skill, replaces legacy commands/)
    // User: ~/.claude/CLAUDE.md, ~/.claude/{rules,skills,agents}/
    // Extra: settings.json, .mcp.json, hooks/, plugins/, output-styles/
    Platform {
        name: "claude",
        root_md: "CLAUDE.md",
        root_md_in_subdir: false,

        project_dir: ".claude",
        rules_dir: Some("rules"),
        rules_ext: "md",
        skills_dir: Some("skills"),       // was "commands" (legacy), now "skills"
        skills_as_dir: true,              // skills/<name>/SKILL.md
        agents_dir: Some("agents"),
        extra_files: &["settings.json", ".mcp.json"],
        extra_dirs: &["hooks", "plugins", "output-styles"],
        user_dir: Some("~/.claude"),
        user_root_md: Some("CLAUDE.md"),
    },

    // ── Codex CLI (OpenAI) ──
    // AGENTS.md at project root (walks up to git root)
    // Skills: .codex/skills/<name>/SKILL.md (directory per skill)
    // User: ~/.codex/ (config.toml + AGENTS.md via hierarchical scan)
    Platform {
        name: "codex",
        root_md: "AGENTS.md",
        root_md_in_subdir: false,

        project_dir: ".codex",
        rules_dir: Some("rules"),
        rules_ext: "md",
        skills_dir: Some("skills"),
        skills_as_dir: true,              // skills/<name>/SKILL.md
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: Some("~/.codex"),
        user_root_md: Some("AGENTS.md"),
    },

    // ── Gemini CLI (Google) ──
    // GEMINI.md at project root
    // Skills: .gemini/skills/<name>/SKILL.md (directory per skill)
    // User: ~/.gemini/GEMINI.md, ~/.gemini/skills/
    Platform {
        name: "gemini",
        root_md: "GEMINI.md",
        root_md_in_subdir: false,

        project_dir: ".gemini",
        rules_dir: None,
        rules_ext: "md",
        skills_dir: Some("skills"),
        skills_as_dir: true,              // skills/<name>/SKILL.md
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: Some("~/.gemini"),
        user_root_md: Some("GEMINI.md"),
    },

    // ── Cursor ──
    // .cursorrules at project root (legacy), .cursor/rules/*.mdc (current)
    // Also supports AGENTS.md and .md rules files
    // User: ~/.cursor/rules/*.mdc
    Platform {
        name: "cursor",
        root_md: ".cursorrules",
        root_md_in_subdir: false,

        project_dir: ".cursor",
        rules_dir: Some("rules"),
        rules_ext: "mdc",
        skills_dir: None,
        skills_as_dir: false,
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: Some("~/.cursor"),
        user_root_md: None,
    },

    // ── GitHub Copilot ──
    // .github/copilot-instructions.md, .github/instructions/*.instructions.md
    // Prompts: .github/prompts/*.prompt.md (not synced — different format)
    Platform {
        name: "copilot",
        root_md: "copilot-instructions.md",
        root_md_in_subdir: true,

        project_dir: ".github",
        rules_dir: Some("instructions"),
        rules_ext: "instructions.md",
        skills_dir: None,
        skills_as_dir: false,
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: None,
        user_root_md: None,
    },

    // ── Windsurf ──
    // .windsurfrules at project root (also supports AGENTS.md)
    // .windsurf/rules/*.md
    // User: ~/.codeium/windsurf/memories/global_rules.md
    Platform {
        name: "windsurf",
        root_md: ".windsurfrules",
        root_md_in_subdir: false,

        project_dir: ".windsurf",
        rules_dir: Some("rules"),
        rules_ext: "md",
        skills_dir: None,
        skills_as_dir: false,
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: Some("~/.codeium/windsurf"),
        user_root_md: None,
    },

    // ── Cline ──
    // .clinerules/ directory for rules
    // Skills: .cline/skills/ (separate base dir — not yet synced)
    // User: ~/Documents/Cline/Rules/ (rules), ~/.cline/skills/ (skills)
    Platform {
        name: "cline",
        root_md: ".clinerules",
        root_md_in_subdir: false,
        project_dir: ".clinerules",
        rules_dir: None,
        rules_ext: "md",
        skills_dir: None,                // TODO: .cline/skills/ (different base dir)
        skills_as_dir: false,
        agents_dir: None,
        extra_files: &[],
        extra_dirs: &[],
        user_dir: Some("~/.cline"),
        user_root_md: None,
    },
];

/// AGENTS.md is the universal standard — always synced to project root
pub const UNIVERSAL_ROOT_MD: &str = "AGENTS.md";

pub fn find_platform(name: &str) -> Option<&'static Platform> {
    PLATFORMS.iter().find(|p| p.name == name)
}

pub fn platform_names() -> Vec<&'static str> {
    PLATFORMS.iter().map(|p| p.name).collect()
}
