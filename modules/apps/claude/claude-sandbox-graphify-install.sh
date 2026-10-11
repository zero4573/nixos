# Installs graphify into the shared `claude-sandbox-graphify` podman volume
# (mounted at /opt/graphify), once per lock file. Sourced (as
# /graphify-install.sh) by the claude-sandbox graphify sidecar. Expects the lock (claude-sandbox-graphify-requirements.txt: graphifyy,
# its extras and every dependency, pinned with sha256 hashes) mounted at
# /graphify-requirements.txt. pip refuses anything whose hash doesn't match.
# Leaves $venv set to the venv's path.

# One venv per lock, so bumping it never deletes a venv that running sidecars
# still use. Venvs of other locks untouched for 30 days are removed. flock
# guards concurrent first starts.
venv="/opt/graphify/venv-$(sha256sum /graphify-requirements.txt | cut -c1-12)"
exec 9>/opt/graphify/.lock
flock 9
if [ ! -x "$venv/bin/graphify" ]; then
  echo "graphify: installing $(sed -n 's/^# spec: //p' /graphify-requirements.txt)"
  rm -rf "$venv"
  python3 -m venv "$venv"
  if ! "$venv/bin/pip" install --quiet --no-cache-dir --disable-pip-version-check \
      --require-hashes --no-deps -r /graphify-requirements.txt; then
    rm -rf "$venv"
    flock -u 9
    echo "graphify: install failed" >&2
    exit 1
  fi
fi
touch "$venv"
find /opt/graphify -mindepth 1 -maxdepth 1 -type d -name 'venv*' ! -path "$venv" -mtime +30 \
  -exec rm -rf {} + 2>/dev/null || true
flock -u 9
exec 9>&-
