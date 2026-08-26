#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-kubernetes-live.XXXXXX)"
port_forward_pid=""
namespace=vcf-services
cluster_name="vcf-services-live-$$"
kubeconfig="$work_dir/kubeconfig"
cluster_cleanup_owned=false

cleanup() {
	if [ -n "$port_forward_pid" ]; then
		kill "$port_forward_pid" >/dev/null 2>&1 || true
		wait "$port_forward_pid" >/dev/null 2>&1 || true
	fi
	if [ "$cluster_cleanup_owned" = true ]; then
		kind delete cluster --name "$cluster_name" >/dev/null 2>&1 || true
		cluster_cleanup_owned=false
	fi
	rm -rf "$work_dir"
}
diagnose() {
	status=$?
	if [ "$status" -ne 0 ]; then
		kubectl get pods,pvc,services --namespace "$namespace" -o wide >&2 || true
		kubectl describe pod --namespace "$namespace" \
			-l app.kubernetes.io/name=vcf-services >&2 || true
		kubectl logs --namespace "$namespace" \
			-l app.kubernetes.io/name=vcf-services --all-containers --tail=100 >&2 || true
	fi
	cleanup
	exit "$status"
}
trap diagnose EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || fail "flock is required for one-at-a-time live testing"
exec 9>> /tmp/vcf-services-kubernetes-live.lock
flock --nonblock 9 \
	|| fail "another Kubernetes live test is already running; refusing concurrent cluster creation"

for image in vcf-services-ui:ci vcf-services-sync-base:ci vcf-services-sftp:ci; do
	docker image inspect "$image" >/dev/null 2>&1 \
		|| fail "required local image is missing: $image"
done

command -v kind >/dev/null 2>&1 || fail "kind is required for the disposable live cluster"
cluster_cleanup_owned=true
kind create cluster --name "$cluster_name" --kubeconfig "$kubeconfig" --wait 3m
export KUBECONFIG="$kubeconfig"
expected_context="kind-$cluster_name"
discovered_context="$(kubectl config current-context 2>/dev/null || true)"
[ "$discovered_context" = "$expected_context" ] \
	|| fail "refusing cluster access: discovered context '$discovered_context', expected '$expected_context'"
control_plane="${cluster_name}-control-plane"
[ "$(docker inspect --format '{{ index .Config.Labels "io.x-k8s.kind.cluster" }}' "$control_plane" 2>/dev/null || true)" = "$cluster_name" ] \
	|| fail "refusing cluster access: context '$discovered_context' has no owned kind control plane"
api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
api_port="$(docker inspect --format '{{ (index (index .NetworkSettings.Ports "6443/tcp") 0).HostPort }}' "$control_plane")"
[ "$api_server" = "https://127.0.0.1:$api_port" ] \
	|| fail "refusing cluster access: context '$discovered_context' targets '$api_server', not the owned kind cluster"
kind load docker-image --name "$cluster_name" \
	vcf-services-ui:ci vcf-services-sync-base:ci vcf-services-sftp:ci

rendered="$work_dir/rendered.yaml"
kubectl kustomize "$project_dir/kubernetes" \
	| sed -E \
		-e 's#ghcr.io/sentania-labs/vcf-lab-services/ui:v[0-9]+\.[0-9]+\.[0-9]+#vcf-services-ui:ci#g' \
		-e 's#ghcr.io/sentania-labs/vcf-lab-services/sync-base:v[0-9]+\.[0-9]+\.[0-9]+#vcf-services-sync-base:ci#g' \
		-e 's#ghcr.io/sentania-labs/vcf-lab-services/sftp:v[0-9]+\.[0-9]+\.[0-9]+#vcf-services-sftp:ci#g' \
	> "$rendered"
[ "$(grep -c 'image: vcf-services-ui:ci' "$rendered")" -eq 3 ] \
	|| fail "live manifest did not select all three local UI image consumers"
grep -q 'image: vcf-services-sync-base:ci' "$rendered" \
	|| fail "live manifest did not select the local sync image"
grep -q 'image: vcf-services-sftp:ci' "$rendered" \
	|| fail "live manifest did not select the local SFTP image"

kubectl apply --server-side --field-manager=vcf-services-live-test \
	-f "$rendered" >/dev/null
kubectl wait --namespace "$namespace" --for=jsonpath='{.status.phase}'=Bound \
	pvc --all --timeout=3m
kubectl wait --namespace "$namespace" --for=condition=Available \
	deployment/vcf-services --timeout=7m

pod_name="$(kubectl get pod --namespace "$namespace" \
	-l app.kubernetes.io/name=vcf-services \
	-o jsonpath='{.items[0].metadata.name}')"
[ -n "$pod_name" ] || fail "deployment did not create a Pod"
[ "$(kubectl get pod --namespace "$namespace" "$pod_name" \
	-o jsonpath='{.status.containerStatuses[?(@.ready==true)].name}' | wc -w)" -eq 5 ] \
	|| fail "all five runtime containers did not become Ready"

kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- \
	test ! -e /var/run/secrets/kubernetes.io/serviceaccount \
	|| fail "a ServiceAccount token was mounted"
kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- \
	test ! -e /etc/vcf-services/secrets/kubernetes.io \
	|| fail "the platform polluted the appliance secrets claim"
[ "$(kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- \
	printenv REDIS_HOST)" = 127.0.0.1 ] || fail "admin-ui Redis host is not loopback"
[ "$(kubectl exec --namespace "$namespace" "$pod_name" -c depot-web -- \
	printenv ADMIN_UI_UPSTREAM)" = 127.0.0.1:8080 ] \
	|| fail "Caddy admin upstream is not loopback"
kubectl exec --namespace "$namespace" "$pod_name" -c depot-sync -- sh -c \
	'REDISCLI_AUTH="$(cat /etc/vcf-services/secrets/redis-password)" \
	redis-cli -h 127.0.0.1 ping' | grep -qx PONG \
	|| fail "sync container could not reach Redis over Pod loopback"

kubectl --namespace "$namespace" port-forward service/vcf-services 18443:443 \
	>"$work_dir/port-forward.log" 2>&1 &
port_forward_pid=$!
deadline=$((SECONDS + 30))
until curl --fail --silent --show-error --insecure \
	https://127.0.0.1:18443/healthz >/dev/null 2>&1; do
	kill -0 "$port_forward_pid" 2>/dev/null \
		|| { cat "$work_dir/port-forward.log" >&2; fail "port-forward stopped"; }
	[ "$SECONDS" -lt "$deadline" ] || fail "HTTPS did not become reachable"
	sleep 1
done
admin_page="$work_dir/admin.html"
curl --fail --silent --show-error --insecure \
	--output "$admin_page" https://127.0.0.1:18443/admin/
grep -q 'VCF Services' "$admin_page" \
	|| fail "the shipped Caddy config did not proxy the admin console"

cookie_jar="$work_dir/cookies"
curl --fail --silent --show-error --insecure -c "$cookie_jar" \
	-H 'Content-Type: application/json' \
	-d '{"username":"vcf","password":"kubernetes mode repair proof"}' \
	https://127.0.0.1:18443/admin/api/claim >/dev/null

kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- sh -c \
	'find /etc/vcf-services/secrets -type f -exec chmod 0660 {} +'
kubectl exec --namespace "$namespace" "$pod_name" -c sftp-backup -- sh -c \
	'chmod 0660 /etc/ssh/keys/ssh_host_*_key'

kill "$port_forward_pid" >/dev/null 2>&1 || true
wait "$port_forward_pid" >/dev/null 2>&1 || true
port_forward_pid=""
kubectl delete pod --namespace "$namespace" "$pod_name" --wait=true >/dev/null
kubectl wait --namespace "$namespace" --for=condition=Ready pod \
	-l app.kubernetes.io/name=vcf-services --timeout=7m
pod_name="$(kubectl get pod --namespace "$namespace" \
	-l app.kubernetes.io/name=vcf-services \
	-o jsonpath='{.items[0].metadata.name}')"

secret_modes="$(kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- sh -c \
	'find /etc/vcf-services/secrets -type f -printf "%m %P\n" | sort')"
if grep -Ev '^600 ' <<< "$secret_modes" >/dev/null; then
	printf '%s\n' "$secret_modes" >&2
	fail "bootstrap did not restore every private secret to mode 0600"
fi
key_modes="$(kubectl exec --namespace "$namespace" "$pod_name" -c sftp-backup -- sh -c \
	'stat -c "%a" /etc/ssh/keys/ssh_host_ed25519_key \
	/etc/ssh/keys/ssh_host_rsa_key /etc/ssh/keys/ssh_host_ecdsa_key')"
[ "$key_modes" = $'600\n600\n600' ] \
	|| fail "SFTP did not restore private host keys to mode 0600"
kubectl exec --namespace "$namespace" "$pod_name" -c admin-ui -- \
	test ! -e /etc/vcf-services/secrets/kubernetes.io \
	|| fail "the restarted Pod polluted the secrets claim"

echo "Kubernetes Pod readiness, secret isolation, fsGroup recovery, and loopback networking passed"
trap - EXIT
cleanup
