# shellcheck shell=bash
# Sourced by the packaging scripts. Prints the Python of a private venv holding the hash-locked
# dmgbuild from packaging/macos/requirements-dmg.txt, creating it under .build/ on first use.
dmgbuild_python() {
  local root="$1" python="${SHIPWATCH_PYTHON:-python3}"
  local requirements="$root/packaging/macos/requirements-dmg.txt"
  command -v "$python" > /dev/null || { echo "Python 3.10+ is required for the installer layout (set SHIPWATCH_PYTHON)." >&2; return 1; }
  "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || { echo "$python is older than 3.10; dmgbuild needs 3.10+ (set SHIPWATCH_PYTHON)." >&2; return 1; }
  local version hash venv
  version="$("$python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  hash="$(shasum -a 256 "$requirements" | cut -c1-12)"
  venv="$root/.build/dmgbuild-py$version-$hash"
  if [ ! -f "$venv/.complete" ]; then
    echo "Installing locked dmgbuild into $venv..." >&2
    rm -rf "$venv"
    if ! { "$python" -m venv "$venv" >&2 \
      && "$venv/bin/python" -m pip install --quiet --isolated --disable-pip-version-check --no-input \
        --no-deps --only-binary=:all: --require-hashes -r "$requirements" >&2; }; then
      echo "Could not install dmgbuild from $requirements." >&2
      rm -rf "$venv"
      return 1
    fi
    touch "$venv/.complete"
  fi
  echo "$venv/bin/python"
}
