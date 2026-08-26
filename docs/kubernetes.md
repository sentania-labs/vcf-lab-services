# Kubernetes deployment

The supported Kubernetes path is the plain manifest set in `kubernetes/`. It
runs the appliance as one Pod so every persistent claim can use
`ReadWriteOnce`. The design is intentionally readable and has no Helm release
state.

## Deploy

The defaults require a dynamic default StorageClass and request 1 TiB for the
depot. Review the sizes in `kubernetes/storage.yaml`, and add a `storageClassName`
to each claim when the cluster has no suitable default. Then deploy:

```bash
kubectl apply -k kubernetes
kubectl wait --namespace vcf-services --for=condition=Available \
  deployment/vcf-services --timeout=10m
kubectl get --namespace vcf-services pods,services,ingress,pvc
```

Point the console hostname at the ingress address and replace
`vcf-services.local` in `kubernetes/ingress.yaml` with that name. The separate
`vcf-services-sftp` LoadBalancer Service publishes SFTP on port 22. On a cluster
without a LoadBalancer implementation, expose that Service through the site's
normal TCP ingress or load balancer.

For a command-line proof before DNS is ready:

```bash
kubectl --namespace vcf-services port-forward service/vcf-services 8443:443
curl --fail --insecure https://127.0.0.1:8443/healthz
curl --fail --insecure https://127.0.0.1:8443/admin/
```

The Deployment disables ServiceAccount token mounting. The application does
not use the Kubernetes API. This is defense in depth: application secrets also
live at `/etc/vcf-services/secrets`, outside Kubernetes' reserved
`/var/run/secrets/kubernetes.io/serviceaccount` tree.

## Secret paths

The `secrets-state` claim contains four consumer directories. A whole-tree
mount retains the stored prefix, while a `subPath` mount makes that directory
the consumer's root:

| Consumer | Stored tree or subPath | Mount inside consumer | Example visible path |
|---|---|---|---|
| `volume-permissions` init container | whole tree | `/etc/vcf-services/secrets` | mode and ownership repair only |
| `bootstrap` init container | whole tree | `/etc/vcf-services/secrets` | `/etc/vcf-services/secrets/ui/flask-secret` |
| `admin-ui` | whole tree | `/etc/vcf-services/secrets` | `/etc/vcf-services/secrets/ui/flask-secret` |
| `depot-sync` | `sync` | `/etc/vcf-services/secrets` | `/etc/vcf-services/secrets/activation-code.txt` |
| `sftp-backup` | `sftp` | `/etc/vcf-services/secrets` | `/etc/vcf-services/secrets/sftp-password` |
| `redis` | `redis` | `/etc/redis` | `/etc/redis/redis.conf` |

The console sees every prefix because it owns credential updates. Each other
consumer sees only its own subdirectory. Do not add the stored prefix again to
a path in a subPath-mounted container.

Compose upgrades retain the existing `vcf-services-secrets` named volume and
remount that same root at `/etc/vcf-services/secrets`. Existing owner, Redis,
activation, SFTP, and session secrets are reused in place, with no copy and no
regeneration. A custom deployment upgrading from `/run/secrets` should remount
its existing volume or claim at the new path. The on-volume directory layout
does not change.

The bootstrap init container also corrects known private secret files to mode
`0600` on every start. Kubernetes `fsGroup` can add group-write bits while
mounting a claim. SFTP performs the same correction for existing private host
keys before starting sshd.

The admin console, sync, Redis, and Caddy runtime containers are forced to a
non-root UID with read-only root filesystems. A short volume-permissions init
container runs as root before the non-root bootstrap so existing claim content
can be returned to the application UID. The SFTP supervisor retains its
existing root runtime because it applies the GUI-selected UID:GID and updates
the container account before sshd drops each session to that identity.

## Storage sharing and placement

The supplied single Pod lets all ten claims remain RWO. These are the current
consumer relationships:

| Claim | Writer | Other consumers | Sharing reason |
|---|---|---|---|
| `depot-store` | `depot-sync` | `depot-web`, `admin-ui` | Web serves sync output, console reports storage state |
| `backup-store` | `sftp-backup` | `admin-ui` | Console reports backup storage state |
| `vcfdt-state` | licensed tool in `admin-ui` and `depot-sync` | both | Software Depot ID must remain consistent across upload, registration, and sync |
| `vcfdt-tool` | `admin-ui` | `depot-sync` read-only | Console installs the licensed tool, sync executes it |
| `sync-state` | `depot-sync` | `admin-ui` read-only | Console displays current state and logs |
| `caddy-data` | `depot-web` | `admin-ui` read-only | Console makes the generated local CA available to operators |
| `config-state` | `bootstrap`, then `admin-ui` | `depot-sync`, `sftp-backup` read-only | GUI-owned settings and version status |
| `secrets-state` | `bootstrap`, then `admin-ui` | `depot-sync`, `sftp-backup`, `redis` through scoped subPaths | Shared credentials with per-consumer exposure |
| `caddy-config` | `depot-web` only | none | Caddy runtime state, single consumer |
| `sftp-host-keys` | `sftp-backup` only | none | Stable SFTP identity, single consumer |

The multi-consumer mounts are required by the current product behavior. Some
console read mounts, such as backup storage status and Caddy CA download, are
control-plane conveniences rather than data-plane sharing, but they are still
observable GUI features today. They are not decoupled by this deployment.
`caddy-config` and `sftp-host-keys` are genuinely single-consumer and do not
need RWX storage in a split deployment.

Measured on the reporting k3s cluster, 800 creates of 36 KiB files took 0.48
seconds on Longhorn RWO, 2.05 seconds on NFS RWX, and 7.92 seconds on Longhorn
RWX. Longhorn RWX was about 16 times slower than RWO for that workload. This is
why the supplied manifests prefer one Pod and RWO claims.

The cost is a larger failure domain. A Pod is Ready only when every container
is Ready. If any one container fails readiness, Kubernetes removes the Pod from
the Service endpoints and takes the whole appliance off the network, even when
the web and console containers are individually healthy.

## Reverse proxy upload limits

The licensed VCF Download Tool upload is roughly 490 MB. ingress-nginx defaults
to a 1 MB request body, so an unprepared ingress returns HTTP 413 and prevents
initial appliance configuration. Allow at least 30 minutes for request and
response transfer. The supplied ingress carries the working settings:

```yaml
nginx.ingress.kubernetes.io/proxy-body-size: "2g"
nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
```

Apply equivalent limits and timeouts when using another ingress controller or
reverse proxy.

## Operations and recovery

All product settings remain in the admin console. Kubernetes manifest edits
are limited to platform concerns such as storage classes, claim sizes,
hostnames, and external Service integration.

The Deployment uses `Recreate`, so an upgrade stops the old Pod before the new
Pod attaches its RWO claims. Preserve every PVC during updates. Deleting the
namespace deletes the namespaced claims and can erase the appliance. The
`vcfdt-tool` claim alone is disposable and can be restored by uploading the
licensed archive again.
