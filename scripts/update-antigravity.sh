#!/usr/bin/env bash
set -Eeuo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -ne 0 ]] || die "Run as your normal user, not with sudo."

for tool in curl python3 tar sudo pgrep realpath; do
    command -v "$tool" >/dev/null || die "Missing dependency: $tool"
done

INSTALL_DIR=$(realpath -e -- "${1:-$HOME/Applications/antigravity}") \
    || die "Installation directory not found. Pass its path as an argument."

[[ -f "$INSTALL_DIR/antigravity" && ! -L "$INSTALL_DIR/antigravity" ]] \
    || die "This directory must directly contain the antigravity executable."

[[ "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "$HOME" ]] \
    || die "Refusing an unsafe installation path."

if dpkg-query -S "$INSTALL_DIR/antigravity" >/dev/null 2>&1; then
    die "This executable is package-managed. Refusing to overwrite APT files."
fi

if pgrep -ix antigravity >/dev/null; then
    die "Close Antigravity completely, then run this script again."
fi

case "$(uname -m)" in
    x86_64) PLATFORM="linux-x64"; TOP="Antigravity-x64" ;;
    aarch64|arm64) PLATFORM="linux-arm"; TOP="Antigravity-arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

PAGE="https://antigravity.google/download/"
WORK=$(mktemp -d)
STAGE=""
BACKUP=""
MOVED_OLD=0
COMMITTED=0

cleanup() {
    status=$?
    trap - EXIT
    set +e

    if [[ "$MOVED_OLD" == 1 && "$COMMITTED" == 0 ]]; then
        if [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
            sudo mv -T -- "$BACKUP" "$INSTALL_DIR" \
                || printf 'Restore the backup manually: %s\n' "$BACKUP" >&2
        else
            printf 'Previous installation retained at: %s\n' "$BACKUP" >&2
        fi
    fi

    [[ -z "$STAGE" ]] || sudo rm -rf -- "$STAGE"
    rm -rf -- "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CURL=(curl --fail --show-error --location
      --proto '=https' --proto-redir '=https' --retry 3)

echo "Checking Google's download page..."
"${CURL[@]}" --silent --compressed "$PAGE" -o "$WORK/download.html"

python3 - "$WORK/download.html" "$PLATFORM" > "$WORK/release.txt" <<'PY'
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = set()

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.urls.add(urljoin("https://antigravity.google/download/", href))

parser = Links()
parser.feed(Path(sys.argv[1]).read_text(errors="replace"))
pattern = re.compile(
    r"https://storage\.googleapis\.com/antigravity-public/antigravity-hub/"
    r"(\d+\.\d+\.\d+)-\d+/" + re.escape(sys.argv[2]) +
    r"/Antigravity\.tar\.gz"
)
matches = [(m.group(1), url) for url in parser.urls
           if (m := pattern.fullmatch(url))]

if len(matches) != 1:
    raise SystemExit(
        "Could not uniquely resolve the official download. "
        "Google may have changed its page; no installation files were changed."
    )

print(*matches[0], sep="\t")
PY

IFS=$'\t' read -r VERSION URL < "$WORK/release.txt"

if [[ -f "$INSTALL_DIR/.updater-download-url" ]] &&
   [[ "$(cat "$INSTALL_DIR/.updater-download-url")" == "$URL" ]]; then
    echo "Already updated to the currently published release: $VERSION"
    exit 0
fi

printf 'Latest published version: %s\nInstallation: %s\n' \
    "$VERSION" "$INSTALL_DIR"

"${CURL[@]}" "$URL" -o "$WORK/Antigravity.tar.gz"

echo "Checking archive layout..."
python3 - "$WORK/Antigravity.tar.gz" "$TOP" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = archive.getmembers()
    links = set()
    for member in members:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts
                or not path.parts or path.parts[0] != sys.argv[2]):
            raise SystemExit(f"Unsafe or unexpected archive path: {member.name}")
        if not (member.isfile() or member.isdir()
                or member.issym() or member.islnk()):
            raise SystemExit(f"Unsupported archive entry: {member.name}")
        if member.issym() or member.islnk():
            target = PurePosixPath(member.linkname)
            if target.is_absolute() or ".." in target.parts or not target.parts:
                raise SystemExit(f"Unsafe archive link: {member.name}")
            if member.islnk() and target.parts[0] != sys.argv[2]:
                raise SystemExit(f"Unexpected hard-link target: {member.linkname}")
            links.add(path)

    for member in members:
        if any(parent in links for parent in PurePosixPath(member.name).parents):
            raise SystemExit(f"Archive entry beneath a link: {member.name}")
PY

mkdir "$WORK/extracted"
tar --no-same-owner --no-same-permissions \
    -xzf "$WORK/Antigravity.tar.gz" -C "$WORK/extracted"

PAYLOAD="$WORK/extracted/$TOP"
[[ -f "$PAYLOAD/antigravity" && ! -L "$PAYLOAD/antigravity" ]] \
    || die "Downloaded archive is missing its executable."
[[ -f "$PAYLOAD/chrome-sandbox" && ! -L "$PAYLOAD/chrome-sandbox" ]] \
    || die "Downloaded archive is missing a valid sandbox helper."

chmod -R a-s "$PAYLOAD"
chmod +x "$PAYLOAD/antigravity"

echo "Preparing replacement and sandbox permissions..."
sudo -v
STAGE=$(sudo mktemp -d "$(dirname "$INSTALL_DIR")/.antigravity-update.XXXXXX")
sudo cp -a "$PAYLOAD/." "$STAGE/"
sudo chown -R "$(id -u):$(id -g)" "$STAGE"
chmod 755 "$STAGE"
printf '%s\n' "$URL" > "$STAGE/.updater-download-url"

sudo chown root:root "$STAGE/chrome-sandbox"
sudo chmod 4755 "$STAGE/chrome-sandbox"

BACKUP="${INSTALL_DIR}.backup-$(date +%Y%m%d-%H%M%S)-$$"
[[ ! -e "$BACKUP" ]] || die "Backup path already exists."

if pgrep -ix antigravity >/dev/null; then
    die "Antigravity was opened during the download. Close it and retry."
fi

echo "Replacing application..."
sudo mv -T -- "$INSTALL_DIR" "$BACKUP"
MOVED_OLD=1
sudo mv -T -- "$STAGE" "$INSTALL_DIR"
STAGE=""
COMMITTED=1

printf '\nUpdated to Antigravity %s\nBackup retained at: %s\n' \
    "$VERSION" "$BACKUP"
printf 'Launch using your existing shortcut, or:\n  "%s/antigravity"\n' \
    "$INSTALL_DIR"
