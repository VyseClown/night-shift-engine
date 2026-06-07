# Terminal Setup

This document describes the terminal and Zsh customization added on
June 5, 2026, with additional helpers for React Native development.

## File Changed

The configuration was added directly to `~/.zshrc`. No prompt framework or
third-party Zsh plugin manager was installed.

## Executable Search Path

The shell `PATH` now includes:

```text
~/.local/bin
/opt/homebrew/bin
/opt/homebrew/sbin
/usr/local/bin
/usr/bin
/bin
/usr/sbin
/sbin
```

This makes local programs, Homebrew packages, and macOS system commands
available even when the terminal starts with a minimal inherited environment.

## Command History

Zsh history was increased to 50,000 entries and configured to:

- Share history between terminal sessions.
- Append commands instead of replacing the history file.
- Ignore consecutive duplicate commands.
- Remove unnecessary spaces from saved commands.

## Prompt

The two-line prompt displays:

- Current user.
- Current directory.
- Git branch or abbreviated commit when inside a repository.
- An asterisk when the Git worktree contains changes.
- Exit code when the previous command failed.
- Duration for commands that took at least two seconds.
- Current time.

This information makes it easier to confirm the active project and branch,
notice failed commands, and identify slow development operations.

The terminal tab title shows the current directory. New interactive terminals
continue to start in `~/work`, matching the pre-existing shell behavior.

## Zsh Completion

Native Zsh completion is enabled. Codex CLI completion is also loaded with:

```sh
codex completion zsh
```

This allows commands and supported options to be completed with the Tab key.

## React Native Helpers

The following aliases were added:

| Alias | Command |
| --- | --- |
| `ni` | `npm install` |
| `nr` | `npm run` |
| `nrt` | `npm test` |
| `expo` | `npx expo` |
| `rn` | `npx react-native` |
| `pods` | `cd ios && pod install && cd -` |

The `rninfo` shell function reports:

- macOS version and CPU architecture.
- Node, npm, and npx availability.
- Watchman availability.
- CocoaPods availability.
- Java and Android Debug Bridge availability.
- Xcode command-line status.
- React Native or Expo fields from the current `package.json`.

Run it with:

```sh
rninfo
```

## React Native Tools Not Installed

The environment report found that these requirements are not yet ready:

- Node.js, npm, and npx are not installed.
- Watchman is not installed.
- CocoaPods is not installed.
- A Java runtime and Android Debug Bridge are not installed.
- Full Xcode is not selected; only Apple Command Line Tools are active.

The aliases and diagnostics were configured in advance. These development
tools were not installed as part of the terminal customization.

## Installation

The terminal setup was installed by:

1. Inspecting the existing `~/.zshrc`.
2. Adding the path, history, prompt, title, completion, aliases, and `rninfo`
   configuration directly to `~/.zshrc`.
3. Preserving the existing behavior that starts terminals in `~/work`.
4. Validating Zsh syntax with:

   ```sh
   zsh -n ~/.zshrc
   ```

5. Starting a fresh interactive shell and running `rninfo`.

## Activation

Open a new terminal or reload the current shell:

```sh
source ~/.zshrc
```

Verify the terminal and React Native diagnostics with:

```sh
rninfo
```
