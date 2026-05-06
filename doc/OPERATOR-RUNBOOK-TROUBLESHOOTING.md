# LibreNMS Internal Operator Runbook

Operator-focused commands for deployment, validation, and troubleshooting.

## 1. Core Command Set

```bash
nms preflight
nms start
nms edit
nms update
nms status
nms monitor
nms stop
nms help
```

## 2. Common Flags and Environment

```bash
nms start --non-interactive
nms edit --non-interactive
nms start --no-auto-add-host

export NMS_NO_EDITOR=1
export NMS_AUTO_ADD_HOST=0
export NMS_NAMESPACE=librenms
export NMS_HOST_IP=<forced-ip>
```

## 3. Kubernetes and Helm Checks

```bash
kubectl get ns
kubectl get all -n librenms
kubectl get pods -n librenms -o wide
kubectl describe pod <pod> -n librenms
kubectl logs -n librenms <pod> --tail=200
kubectl logs -n librenms <pod> -c <container> --tail=200

helm list -A | grep librenms
helm status librenms -n librenms
helm get values librenms -n librenms
```

## 4. TLS and Certificate Operations

### 4.1 Static Certificate

```bash
nms cert static /path/to/cert.pem /path/to/key.pem
kubectl get secret https-cert -n librenms
```

### 4.2 ACME-DNS Registration

```bash
nms cert check
nms cert register nms.example.com
nms cert register nms.example.com auth.example.com
nms cert register nms.example.com auth.example.com /data/certs/custom.json
```

Credential files:

- `/data/certs/acme-dns-account.<domain>.json` (per domain)
- `/data/certs/acme-dns-account.json` (merged import file)

### 4.3 cert-manager Health

```bash
kubectl get pods -n cert-manager
kubectl get issuer,clusterissuer
kubectl get certificate -n librenms
kubectl describe certificate https-cert -n librenms
kubectl get events -n librenms --sort-by=.metadata.creationTimestamp | tail -n 50
```

## 5. SAML/Social Auth Operations

Validate values in `/data/lnms-config.yaml`:

- `saml.enable`
- `saml.provider` (github/microsoft/okta/saml2)
- `saml.client_id`, `saml.client_secret`, `saml.callback`
- Provider-specific fields (`tenant`, `base_url`, `saml2.metadata`)
- `saml.claim_field`, `saml.claims`, `saml.default_role`
- `application.lnms.installPlugins`

Apply changes:

```bash
nms update
```

Inspect socialite config inside app container:

```bash
lnms config:get auth.socialite
```

## 6. LibreNMS App-Level Checks

```bash
lnms device:list | head -n 20
lnms report:devices | head -n 30
lnms config:get snmp.community
lnms config:get webui.graph_type
lnms config:get enable_syslog
```

Create emergency admin user:

```bash
lnms user:add -r admin <username>
```

## 7. Oxidized Quick Checks

```bash
kubectl get pods -n librenms | grep -i oxidized
kubectl logs -n librenms statefulset/oxidized --tail=200
```

Verify:

- `oxidized.enable=true`
- `oxidized.credentials.token` populated
- `oxidized.group.core.user/password` populated

Restart oxidized workload if needed:

```bash
kubectl delete pod -n librenms -l app.kubernetes.io/name=oxidized
```

## 8. xMatters Quick Checks

Verify values:

- `xmatters.enable=true`
- `xmatters.agent.enable=true`
- `xmatters.agent.URL/APIkey/APIsecret` set

Then apply and check logs:

```bash
nms update
kubectl get pods -n librenms | grep -i xmatters
kubectl logs -n librenms <xmatters-pod> --tail=200
```

## 9. Incident Triage Order

1. `nms preflight`
1. `kubectl get pods -n librenms`
1. `helm status librenms -n librenms`
1. Check recent events and failing pod logs
1. Validate `lnms-config.yaml` changes and run `nms update`
1. Restart only affected workload/pod

## 10. Safe Recovery Patterns

- Prefer `nms update` over uninstall/reinstall
- Restart single failing pod before broader actions
- Keep namespace/release consistent (`NMS_NAMESPACE`)
- Back up `/data/lnms-config.yaml` before major auth/TLS changes
