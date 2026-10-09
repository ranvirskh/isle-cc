#!/bin/zsh
# Double-click to start the Isle build in Terminal.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$HOME/isle-cc" || exit 1
if ! command -v claude >/dev/null 2>&1; then
  echo "Claude Code is not installed. Installing it now..."
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "claude still not found. Open a new Terminal window and run: claude --version"
  exec zsh
fi
echo "Starting the Isle build. Log in in the browser if asked."
claude --model opus "Read PROMPT.md and ADDENDUM.md in this folder. ADDENDUM.md amends PROMPT.md and is part of Phase 1. Carry out everything completely."
exec zsh
