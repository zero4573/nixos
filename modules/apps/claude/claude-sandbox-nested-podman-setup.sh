set -e
mkdir -p /etc/containers /var/lib/containers/storage /run/containers/storage
echo "root:1:65535" > /etc/subuid
echo "root:1:65535" > /etc/subgid

cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

cat > /etc/containers/registries.conf <<EOF
unqualified-search-registries = ["docker.io"]
EOF

if [ -n "${REGISTRY_MIRROR_PREFIX:-}" ]; then
  mirror_location="registry-cache:5000"
  if [ "$REGISTRY_MIRROR_PREFIX" != "${REGISTRY_MIRROR_PREFIX#*/}" ]; then
    mirror_location="registry-cache:5000/${REGISTRY_MIRROR_PREFIX#*/}"
  fi

  cat >> /etc/containers/registries.conf <<EOF

[[registry]]
prefix = "$REGISTRY_MIRROR_PREFIX"
location = "$REGISTRY_MIRROR_PREFIX"
insecure = true

[[registry.mirror]]
location = "$mirror_location"
insecure = true

# redirect docker.io requests to proxy mirror
[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "$mirror_location"
insecure = true
EOF
fi

cat > /etc/containers/policy.json <<'INNEREOF'
{ "default": [{ "type": "insecureAcceptAnything" }] }
INNEREOF

# conmon/crun are on PATH here via the outer container's PATH env var
# (which includes the nested-podman toolchain's bin dir), so their store
# paths are discovered at runtime rather than baked in via Nix.
conmon_path="$(command -v conmon)"
crun_path="$(command -v crun)"

cat > /etc/containers/containers.conf <<EOF
[engine]
conmon_path = ["$conmon_path"]
runtime = "crun"
[engine.runtimes]
crun = ["$crun_path"]
[network]
network_backend = "netavark"
EOF

if [ -n "${REGISTRY_MIRROR_PREFIX:-}" ]; then
  cat >> /etc/containers/containers.conf <<EOF
[containers]
netns = "host"
EOF
fi

export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"

exec "$@"
