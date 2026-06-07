# Developer Environment Setup

> Last updated: 2026-06-05 (added Nerd Font, Ghostty config, zsh plugins)  
> Platform: macOS (Apple Silicon) · Shell: zsh

---

## Codex-centered

These aliases were already present in `~/.zshrc` and wire up the **Codex CLI** (`codex`).

| Alias | Expands to | Purpose |
|---|---|---|
| `c` | `codex` | Launch Codex interactively |
| `cr` | `codex resume --last` | Resume the last Codex session |
| `cf` | `codex fork --last` | Fork the last session into a new branch |
| `cx` | `codex --no-alt-screen` | Run Codex without taking over the screen (good for logging) |
| `cdoctor` | `codex doctor` | Check Codex environment health |
| `cfeatures` | `codex features list` | List available Codex features |

Shell completion is also loaded automatically when `codex` is found in `$PATH`:

```zsh
if command -v codex >/dev/null 2>&1; then
  eval "$(codex completion zsh)"
fi
```

---

## Terminal-centered

### nvm — Node Version Manager

**Why:** React Native requires a specific Node version per project. `nvm` lets you install multiple versions and switch between them without conflicts.

**How installed:**
```bash
brew install nvm
```

**Activated in `~/.zshrc`:**
```zsh
export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
```

**Useful commands:**
```bash
nvm install --lts          # install latest LTS (currently v24.16.0)
nvm use 20                 # switch to Node 20
nvm ls                     # list installed versions
nvm alias default 24       # set default version for new shells
```

---

### Node.js v24.16.0 LTS

**Why:** Required for React Native, Metro bundler, and all JS tooling.

**How installed:**
```bash
nvm install --lts
```

This also set `lts/*` as the default alias, so new terminal windows will automatically use the LTS version.

---

### JetBrains Mono Nerd Font

**Why:** Starship uses Nerd Font glyphs for the git branch icon, Node.js icon, and others. Without a Nerd Font these render as blank boxes in the terminal. JetBrains Mono is a clean monospace font designed for code.

**How installed:**
```bash
brew install --cask font-jetbrains-mono-nerd-font
```

**Configured in Ghostty** via `~/.config/ghostty/config` (see Ghostty section below).

---

### Ghostty — terminal configuration

**Why:** Ghostty had no config file, so it was running with system defaults and the wrong font (no Nerd Font glyphs).

**Config file created:** `~/.config/ghostty/config`

```
font-family = JetBrainsMono Nerd Font
font-size = 14
shell-integration = zsh
theme = dark:Gruvbox Dark,light:Gruvbox Light
```

Adjust `font-size` to taste. A full restart of Ghostty (Cmd+Q, reopen) is required after any font change.

---

### Starship — cross-shell prompt

**Why:** The default zsh prompt had no awareness of Node version, package names, or detailed git state. Starship replaces it with a single-line prompt that auto-adapts to the project you are in.

**How installed:**
```bash
brew install starship
```

**Activated in `~/.zshrc`** (placed after the previous `PROMPT`/`RPROMPT` assignments so it overrides them):
```zsh
eval "$(starship init zsh)"
```

**Config file:** `~/.config/starship.toml`

What the prompt shows:

| Segment | When shown | Example |
|---|---|---|
| Directory | Always | `~/work/MyApp` |
| Git branch | Inside a git repo | ` main` |
| Git status | When repo has changes | `!2 +1 ?3` (modified / staged / untracked) |
| Git ahead/behind | When diverged from remote | `⇡2 ⇣1` |
| Node version | When `package.json` present | ` v24.16.0` |
| Package version | When `package.json` present | `📦 1.0.4` |
| Command duration | When last command took > 2s | `took 4s` |
| Time | Right side, always | `14:32` |
| Battery | Right side, always | `🔋 82%` (red below 15 %, yellow below 30 %) |
| Exit status | On error, prompt `❯` turns red | — |

---

### zsh plugins — autosuggestions & syntax highlighting

**Why:** The two highest-value zsh quality-of-life improvements, added without Oh My Zsh (which would add overhead and complexity on top of a setup that doesn't need it).

| Plugin | What it does |
|---|---|
| `zsh-autosuggestions` | Suggests the rest of your command in grey as you type, based on shell history. Press `→` to accept the full suggestion. |
| `zsh-syntax-highlighting` | Colors commands as you type — green when valid, red when not. Catches typos before you hit Enter. |

**How installed:**
```bash
brew install zsh-autosuggestions zsh-syntax-highlighting
```

**Activated in `~/.zshrc`** (must be sourced after `starship init`, at the very end):
```zsh
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
```

> **Note:** syntax highlighting must always be the last plugin sourced — it wraps zsh internals and breaks if something loads after it.

---

### React Native shell shortcuts

These aliases were already in `~/.zshrc`. They become active now that Node is installed.

| Alias / Function | Expands to | Purpose |
|---|---|---|
| `ni` | `npm install` | Install dependencies |
| `nr` | `npm run` | Run a package.json script |
| `nrt` | `npm test` | Run tests |
| `expo` | `npx expo` | Expo CLI without a global install |
| `rn` | `npx react-native` | RN CLI without a global install |
| `pods` | `cd ios && pod install && cd -` | Install CocoaPods dependencies |
| `rninfo` | _(function)_ | Print full RN environment (node, npm, watchman, java, Xcode, adb) + current project info |

---

## Other items installed

### `claude-usage` — Claude Code usage reporter

**Why:** Claude Code does not show cumulative session or weekly token spend in the UI. This script reads the local conversation logs and calculates real numbers.

**How installed:** Written to `~/.local/bin/claude-usage` (already in `$PATH`). No external dependencies — pure Python 3.

**Alias added to `~/.zshrc`:**
```zsh
alias cu='claude-usage'
```

**What it shows when you run `cu`:**

```
Claude Code Usage  (/Users/…/.claude/projects)

──────────────────────────────────────────────────────────────
  Scope             Tokens    Msgs    Est. Cost   Cost bar
──────────────────────────────────────────────────────────────
  This session       676.5k    25      $0.620     ██░░░░░░░░░░
  Today              676.5k    25      $0.620     ██░░░░░░░░░░
  This week          676.5k    25      $0.620     ██░░░░░░░░░░
  All time           676.5k    25      $0.620     ██░░░░░░░░░░

  Model breakdown  (all time)
  sonnet-4-6         676.5k    25      $0.620     ██░░░░░░░░░░

  Latest session token detail
  Input (non-cached)             33
  Cache read                 615.4k
  Cache write                 42.7k
  Output                      18.3k
  ────────────────────────────────
  Total                      676.5k
```

Cost estimates use current Claude Sonnet pricing (input $3/M, output $15/M, cache write $3.75/M, cache read $0.30/M). Adjust the `PRICING` dict at the top of the script if the model or rates change.

**Source:** `~/.local/bin/claude-usage`

---

### Claude Code status line

**Why:** Shows live session context inside the Claude Code interface — model in use, how full the context window is, approximate per-call cost, rate limit headroom, and current git branch — without needing to run a separate command.

**How installed:** Two files were created/modified:

1. `~/.claude/settings.json` — added the `statusLine` key:
```json
{
  "theme": "dark",
  "statusLine": {
    "type": "command",
    "command": "bash /Users/…/.claude/statusline-command.sh"
  }
}
```

2. `~/.claude/statusline-command.sh` — reads the JSON payload Claude Code pipes in and formats it.

**What the status line shows:**

```
Claude Sonnet 4.6 | ctx 34% [###.......] in:68420 out:1205 | $0.0031 | 5h:12% day:8% 7d:4% mo:21% | owner/repo main | ~/work/myapp
```

Each section is color-coded: usage bars and rate limit percentages shift from green → yellow → red as they approach their limit (thresholds: <50% green, 50–79% yellow, ≥80% red).

| Field | Color | Meaning |
|---|---|---|
| Model name | Cyan | Which Claude model is active |
| `ctx N%` + fill bar | Green/Yellow/Red | How full the context window is |
| `in:` / `out:` | Dim | Cumulative tokens for the session |
| `$N.NNNN` | Green | Approximate cost of the last API call |
| `5h:N%` | Green/Yellow/Red | Rate limit — rolling 5-hour window |
| `day:N%` | Green/Yellow/Red | Rate limit — daily window (when exposed) |
| `7d:N%` | Green/Yellow/Red | Rate limit — rolling 7-day window |
| `mo:N%` | Green/Yellow/Red | Rate limit — monthly window (when exposed) |
| Repo + branch | Magenta | `owner/repo` and current git branch (or `wt:branch` for worktrees) |
| Directory | Dim | Current working directory |
| `PR#N(state)` | — | Open PR number and review state (when in a git repo) |
| Session name | White | If the session was renamed with `/rename` |
| `effort:` / `thinking:on` | Dim / Yellow+Bold | When non-default effort or extended thinking is active |
| `agent:name` | Cyan | Active subagent name |

**Source:** `~/.claude/statusline-command.sh`
