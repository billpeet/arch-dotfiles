#!/usr/bin/env bash
# Symlink dotfiles into $HOME.
#
# Each top-level directory is a "package" whose contents mirror $HOME
# (GNU Stow layout). Files are linked individually, so directories like
# ~/.config stay real directories and app state never lands in the repo.
#
# Usage:
#   ./install.sh [-n] [package...]   link packages (default: all)
#   ./install.sh status [package...] show link state of every managed file
#
#   -n   dry run: print what would happen, change nothing
#
# Existing files that differ from the repo are moved to
# ~/.dotfiles-backup/<timestamp>/ before being replaced.
#
# A directory containing a `.link-whole-dir` marker is linked as a single
# directory symlink instead. Needed for KDE packages (global themes etc.):
# KPackage rejects files that are symlinks pointing outside the package.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
MODE=link

if [[ ${1:-} == status ]]; then MODE=status; shift; fi
if [[ ${1:-} == -n ]]; then DRY_RUN=1; shift; fi

packages() {
    if (($#)); then
        printf '%s\n' "$@"
    else
        find "$DOTFILES" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
    fi
}

run() {
    if ((DRY_RUN)); then echo "  would: $*"; else "$@"; fi
}

# Replace $2 with a symlink to $1 atomically (no window where the file is missing).
atomic_link() {
    local src=$1 dest=$2 tmp
    tmp="$(dirname "$dest")/.dotfiles-tmp.$$.$(basename "$dest")"
    ln -s "$src" "$tmp"
    mv -T "$tmp" "$dest"
}

link_file() {
    local src=$1 dest=$2 rel=$3
    if [[ -L $dest && $(readlink "$dest") == "$src" ]]; then
        echo "ok       $rel"
        return
    fi
    [[ -d $(dirname "$dest") ]] || run mkdir -p "$(dirname "$dest")"
    if [[ -e $dest || -L $dest ]]; then
        if [[ ! -L $dest && ! -d $src ]] && cmp -s "$src" "$dest"; then
            echo "adopt    $rel (identical, replacing with link)"
        else
            echo "backup   $rel -> $BACKUP_DIR/$rel"
            run mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
            run cp -a "$dest" "$BACKUP_DIR/$rel"
        fi
        # A symlink can't atomically replace a real directory; it's backed up above.
        if [[ -d $dest && ! -L $dest ]]; then run rm -rf "$dest"; fi
    else
        echo "link     $rel"
    fi
    run atomic_link "$src" "$dest"
}

status_file() {
    local src=$1 dest=$2 rel=$3
    if [[ -L $dest && $(readlink "$dest") == "$src" ]]; then
        echo "linked   $rel"
    elif [[ -L $dest ]]; then
        echo "OTHER    $rel -> $(readlink "$dest")"
    elif [[ -e $dest ]]; then
        # An app replaced our symlink with a real file (e.g. atomic save).
        if [[ -d $src ]]; then
            echo "UNLINKED $rel (real directory; re-run install.sh)"
        elif cmp -s "$src" "$dest"; then
            echo "UNLINKED $rel (same content; re-run install.sh)"
        else
            echo "UNLINKED $rel (CONTENT DIFFERS; diff before re-linking)"
        fi
    else
        echo "missing  $rel"
    fi
}

while read -r pkg; do
    [[ -d $DOTFILES/$pkg ]] || { echo "no such package: $pkg" >&2; exit 1; }
    echo "[$pkg]"
    while IFS= read -r -d '' src; do
        rel=${src#"$DOTFILES/$pkg/"}
        "${MODE}_file" "$src" "$HOME/$rel" "$rel"
    done < <(find "$DOTFILES/$pkg" -mindepth 1 \
                 \( -type d -exec test -e '{}/.link-whole-dir' \; -prune -print0 \) \
                 -o \( -type f -o -type l \) -print0 | sort -z)
done < <(packages "$@")
