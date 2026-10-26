#!/usr/bin/env bash
# Installs REA (morluto/rea) with Ghidra 12.1.4 as its native analysis engine and
# registers REA's MCP server for Claude Code. Idempotent: finished steps are skipped.
#
# Sources: official git repositories at pinned commits, the official Node.js
# tarball (checksum-verified), and the dependency URLs Ghidra's own
# fetchDependencies.gradle pins, each verified against its SHA-256 there.
# Z3 is built from the official Z3Prover/z3 source tag Ghidra pins (4.13.0).
set -euo pipefail

PREFIX="${REA_PREFIX:-/opt}"
SRC="${REA_SRC:-/home/user}"
NODE_VERSION=24.22.1
REA_COMMIT=0d1a454e25db825567782e461da21530bad4b158
GHIDRA_TAG=Ghidra_12.1.4_build
GHIDRA_COMMIT=8b6bbb857accdfa20dc5b2f5dea471178c2e9fbc
GHIDRA_DATA_COMMIT=da6c2ae8f8507ebdb6c92ec2e260db8bb6e50643
Z3_TAG=z3-4.13.0
Z3_COMMIT=3049f578a8f98a0b0992eca193afe57a73b30ca3

NODE_DIR="$PREFIX/node24"
REA_DIR="$SRC/morluto/rea"
GHIDRA_SRC="$SRC/ghidra-src"
GHIDRA_DATA="$SRC/ghidra-data"
Z3_SRC="$SRC/z3-src"
GHIDRA_HOME="$PREFIX/ghidra_12.1.4_DEV"
export GIT_LFS_SKIP_SMUDGE=1

log() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }

clone_at() { # url tag expected_commit dir
  if [ ! -d "$4/.git" ]; then
    git clone --depth 1 --branch "$2" "$1" "$4"
  fi
  actual=$(git -C "$4" rev-parse HEAD)
  [ "$actual" = "$3" ] || { echo "$4 is at $actual, expected $3" >&2; exit 1; }
}

check_sha256() { # file expected
  echo "$2  $1" | sha256sum -c - >/dev/null || { echo "SHA-256 mismatch: $1" >&2; exit 1; }
}

mkdir -p "$PREFIX" "$SRC/morluto"
for tool in git curl unzip tar xz java javac; do need "$tool"; done

# ---- Node.js (REA requires >=22.23.4 or 24.22.1; engine-strict is on) ----
if [ ! -x "$NODE_DIR/bin/node" ]; then
  log "Node.js $NODE_VERSION"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/node.tar.xz" "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" | grep "linux-x64.tar.xz" | awk '{print $1}' > "$tmp/sum"
  check_sha256 "$tmp/node.tar.xz" "$(cat "$tmp/sum")"
  mkdir -p "$NODE_DIR"
  tar -xJf "$tmp/node.tar.xz" -C "$NODE_DIR" --strip-components=1
  rm -rf "$tmp"
fi
export PATH="$NODE_DIR/bin:$PATH"

# ---- REA ----
log "REA"
if [ ! -d "$REA_DIR/.git" ]; then
  git init -q "$REA_DIR"
  git -C "$REA_DIR" remote add origin https://github.com/morluto/rea.git
  git -C "$REA_DIR" fetch --depth 1 origin "$REA_COMMIT"
  git -C "$REA_DIR" checkout -q FETCH_HEAD
fi
[ "$(git -C "$REA_DIR" rev-parse HEAD)" = "$REA_COMMIT" ] || { echo "REA checkout is not $REA_COMMIT" >&2; exit 1; }
if [ ! -d "$REA_DIR/dist" ]; then
  (cd "$REA_DIR" && npm ci && npm run build)
fi

# ---- Z3 4.13.0 from official source (needed by Ghidra's SymbolicSummaryZ3) ----
Z3_OUT="$Z3_SRC/build"
if [ ! -f "$Z3_OUT/com.microsoft.z3.jar" ] || [ ! -f "$Z3_OUT/libz3java.so" ]; then
  log "Z3 $Z3_TAG (build from source)"
  for tool in cmake ninja g++ python3; do need "$tool"; done
  clone_at https://github.com/Z3Prover/z3.git "$Z3_TAG" "$Z3_COMMIT" "$Z3_SRC"
  mkdir -p "$Z3_OUT"
  (cd "$Z3_OUT" \
    && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DZ3_BUILD_JAVA_BINDINGS=ON \
         -DZ3_INCLUDE_GIT_HASH=OFF -DZ3_INCLUDE_GIT_DESCRIBE=OFF .. \
    && ninja)
fi

# ---- Ghidra ----
if [ ! -x "$GHIDRA_HOME/support/analyzeHeadless" ]; then
  log "Ghidra $GHIDRA_TAG"
  need gradle; need bison; need gcc; need make
  clone_at https://github.com/NationalSecurityAgency/ghidra.git "$GHIDRA_TAG" "$GHIDRA_COMMIT" "$GHIDRA_SRC"
  clone_at https://github.com/NationalSecurityAgency/ghidra-data.git Ghidra_12.1.4 "$GHIDRA_DATA_COMMIT" "$GHIDRA_DATA"
  DEPS="$GHIDRA_SRC/dependencies"
  mkdir -p "$DEPS/flatRepo" "$DEPS/Debugger-agent-dbgeng" "$DEPS/GhidraServer" "$DEPS/SymbolicSummaryZ3/os/linux_x86_64"

  # From the official ghidra-data repository (hashes are the ones in fetchDependencies.gradle)
  cp "$GHIDRA_DATA/lib/java-sarif-2.1-modified.jar" "$DEPS/flatRepo/"
  check_sha256 "$DEPS/flatRepo/java-sarif-2.1-modified.jar" 7f736566494756d271aa5e4b1af6c89dc50d074ab1c6374a47df822264226b01
  cp "$GHIDRA_DATA/Debugger/dbgmodel.tlb" "$DEPS/Debugger-agent-dbgeng/"
  check_sha256 "$DEPS/Debugger-agent-dbgeng/dbgmodel.tlb" 8cf5f3a2eb81160aa349056a5ca4c2c726b1b6e98bf3097cd4135147163343c7

  # URLs pinned by fetchDependencies.gradle
  curl -fsSL -o "$DEPS/flatRepo/AXMLPrinter2.jar" \
    https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/android4me/AXMLPrinter2.jar
  check_sha256 "$DEPS/flatRepo/AXMLPrinter2.jar" 00ed038eb6abaf6ddec8d202a3ed7a81b521458f4cd459948115cfd02ff59d6d
  curl -fsSL -o "$DEPS/GhidraServer/yajsw-stable-13.18.zip" \
    https://sourceforge.net/projects/yajsw/files/yajsw/yajsw-stable-13.18/yajsw-stable-13.18.zip
  check_sha256 "$DEPS/GhidraServer/yajsw-stable-13.18.zip" 50b34e9817c54b2970fa511ff4584f6556c179f69833aa8b9b1ff6485b61684f

  # Python wheels: every files.pythonhosted.org entry in fetchDependencies.gradle, hash-checked
  python3 -I - "$GHIDRA_SRC" <<'PY'
import hashlib, os, re, sys, urllib.request
root = sys.argv[1]
src = open(os.path.join(root, "gradle/support/fetchDependencies.gradle")).read()
entries = re.findall(
    r'name:\s*"([^"]+)",\s*url:\s*"(https://files\.pythonhosted\.org/[^"]+)",\s*sha256:\s*"([0-9a-f]{64})",\s*destination:\s*(\[[^\]]*\]|file\([^)]*\))',
    src)
if not entries:
    sys.exit("no PyPI entries found in fetchDependencies.gradle")
for name, url, sha, dest in entries:
    dirs = [d.replace("${DEPS_DIR}", os.path.join(root, "dependencies")) for d in re.findall(r'file\("([^"]+)"\)', dest)]
    data = urllib.request.urlopen(url, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != sha:
        sys.exit("hash mismatch: " + name)
    for d in dirs:
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, name), "wb").write(data)
print("verified", len(entries), "Python dependency files")
PY

  # Z3 built above from the official tag
  cp "$Z3_OUT/com.microsoft.z3.jar" "$DEPS/flatRepo/com.microsoft.z3.jar"
  cp -L "$Z3_OUT/libz3.so" "$Z3_OUT/libz3java.so" "$DEPS/SymbolicSummaryZ3/os/linux_x86_64/"

  (cd "$GHIDRA_SRC" && gradle --no-daemon -x ip -x createJavadocs -x createJsondocs buildGhidra)
  dist=$(ls "$GHIDRA_SRC"/build/dist/ghidra_12.1.4_DEV_*_linux_x86_64.zip | head -n1)
  unzip -q "$dist" -d "$PREFIX"
fi
[ -x "$GHIDRA_HOME/support/analyzeHeadless" ] || { echo "Ghidra install not found at $GHIDRA_HOME" >&2; exit 1; }

# ---- Register REA's MCP server and skill for Claude Code, with Ghidra ----
log "Register with Claude Code"
(cd "$REA_DIR" && node scripts/rea.mjs setup --client claude_code --skill --yes)
python3 -I - "$GHIDRA_HOME" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.claude.json")
cfg = json.load(open(path))
rea = (cfg.get("mcpServers") or {}).get("rea")
if not rea:
    sys.exit("rea registration not found in " + path)
rea.setdefault("env", {})["GHIDRA_INSTALL_DIR"] = sys.argv[1]
json.dump(cfg, open(path, "w"), indent=2)
print("GHIDRA_INSTALL_DIR set to", sys.argv[1])
PY

log "Check"
(cd "$REA_DIR" && GHIDRA_INSTALL_DIR="$GHIDRA_HOME" node scripts/rea.mjs doctor --client claude_code | grep -E "^healthy|^environment_healthy")
