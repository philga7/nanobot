#!/usr/bin/env bash
set -euo pipefail

# Enable SQLite WAL mode on known NanoBot-related databases.
# This script is idempotent: setting journal_mode=WAL on an existing DB is safe
# and the setting persists in the file itself.

enable_wal() {
  local db_path="$1"
  if [[ -f "$db_path" ]];   then
    echo "Enabling WAL for $db_path"
    sqlite3 "$db_path" "PRAGMA journal_mode=WAL;" >/dev/null
  else
    echo "Skipping $db_path (not found)"
  fi
}

echo "Enabling WAL mode for NanoBot-related SQLite databases (if present)..."

# Default single-user NanoBot layout
enable_wal "${HOME}/.nanobot/data/journal.db"
enable_wal "${HOME}/.nanobot/data/todos.db"
enable_wal "${HOME}/.nanobot/data/sources.db"

# WrenAir instance (Docker bind-mounted at ~/.wrenair)
enable_wal "${HOME}/.wrenair/todos.db"
enable_wal "${HOME}/.wrenair/library/sources.db"

# WrenVPS instance (Docker bind-mounted at ~/.wrenvps)
enable_wal "${HOME}/.wrenvps/todos.db"
enable_wal "${HOME}/.wrenvps/library/sources.db"

echo "Done."

