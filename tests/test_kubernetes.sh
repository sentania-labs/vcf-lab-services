#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-kubernetes-test.XXXXXX)"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
rendered="$work_dir/rendered.yaml"
kubectl kustomize "$project_dir/kubernetes" > "$rendered"
[ -s "$rendered" ] || fail "Kubernetes manifests did not render"

grep -q 'automountServiceAccountToken: false' "$rendered" \
	|| fail "ServiceAccount token mounting is not disabled"
! grep -q '/run/secrets' "$rendered" \
	|| fail "Kubernetes manifests still use the platform-reserved secrets path"
[ "$(grep -c 'mountPath: /etc/vcf-services/secrets' "$rendered")" -eq 5 ] \
	|| fail "expected whole-tree and scoped secrets mounts are missing"
grep -q 'value: 127.0.0.1:8080' "$rendered" \
	|| fail "single-Pod Caddy upstream is not loopback"
[ "$(grep -c 'value: 127.0.0.1$' "$rendered")" -eq 2 ] \
	|| fail "single-Pod Redis consumers are not loopback"
[ "$(grep -c 'accessModes:' "$rendered")" -eq 10 ] \
	|| fail "the ten persistent claims did not render"
[ "$(grep -c 'ReadWriteOnce' "$rendered")" -eq 10 ] \
	|| fail "the single-Pod claims are not all RWO"
[ "$(grep -c 'runAsNonRoot: true' "$rendered")" -eq 5 ] \
	|| fail "non-root application and infrastructure containers are not enforced"
[ "$(grep -c 'readOnlyRootFilesystem: true' "$rendered")" -eq 6 ] \
	|| fail "read-only root filesystems are not enforced where supported"
grep -q 'name: volume-permissions' "$rendered" \
	|| fail "fsGroup volume ownership setup is missing"
for annotation in proxy-body-size proxy-read-timeout proxy-send-timeout proxy-request-buffering; do
	grep -q "nginx.ingress.kubernetes.io/$annotation" "$rendered" \
		|| fail "ingress upload annotation $annotation is missing"
done

for file in "$project_dir/caddy/Caddyfile" "$project_dir/kubernetes/Caddyfile"; do
	[ "$(grep -c 'ADMIN_UI_UPSTREAM' "$file")" -eq 3 ] \
		|| fail "Caddy upstream substitution drifted in $file"
done
cmp "$project_dir/caddy/Caddyfile" "$project_dir/kubernetes/Caddyfile" \
	|| fail "Compose and Kubernetes Caddy configuration drifted"
docker run --rm -e ADMIN_UI_UPSTREAM=127.0.0.1:8080 \
	-v "$project_dir/kubernetes/Caddyfile:/etc/caddy/Caddyfile:ro" \
	caddy:2.10.0-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null

docker run --rm --interactive \
	ghcr.io/yannh/kubeconform:v0.7.0@sha256:85dbef6b4b312b99133decc9c6fc9495e9fc5f92293d4ff3b7e1b30f5611823c \
	-strict -summary -kubernetes-version 1.31.0 < "$rendered"

echo "Kubernetes render, schema, and contract tests passed"
