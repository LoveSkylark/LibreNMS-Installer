# LibreNMS-Helm TLS/Cert-Manager Deployment Layer

This document describes what must be implemented in **LibreNMS-Helm** to complete the TLS certificate provisioning architecture.

## Overview

The LibreNMS-Installer bootstraps only the **cluster infrastructure** (cert-manager CRDs, controller, webhooks).  
LibreNMS-Helm is responsible for creating the **application-layer resources**:

- `Issuer` or `ClusterIssuer` (defines how to obtain certificates)
- `Certificate` (requests a certificate for your domain)
- `Ingress` (with cert-manager or ACME-DNS annotations)

---

## Values Passed from lnms-config.yaml

The LibreNMS-Helm chart receives the following ingress/TLS values:

```yaml
ingress:
  https: true/false                          # Enable HTTPS
  className: "traefik"                       # Ingress controller class
  redirectToHttps:
    enabled: true/false
  tls:
    existingSecretName: ""                   # Use pre-created secret (skip cert provisioning)
    secretName: "https-cert"                 # Secret name for cert-manager to populate
  letsEncrypt:
    enabled: true/false                      # Enable Let's Encrypt automation
    createIssuer: true/false                 # Helm should create Issuer/ClusterIssuer
    issuerKind: "ClusterIssuer"              # or "Issuer" (namespace-scoped)
    issuerName: "letsencrypt-prod"           # Name to reference in Certificate
    email: "admin@example.com"               # ACME contact email
    environment: "production"                # "production" or "staging"
    privateKeySecretName: "letsencrypt-account-key"
    server:
      production: "https://acme-v02.api.letsencrypt.org/directory"
      staging: "https://acme-staging-v02.api.letsencrypt.org/directory"
```

---

## Required Helm Templates

### 1. ClusterIssuer/Issuer Template

**File:** `librenms/templates/cert-manager-issuer.yaml`

```yaml
{{- if and .Values.ingress.https .Values.ingress.letsEncrypt.enabled .Values.ingress.letsEncrypt.createIssuer (not .Values.ingress.tls.existingSecretName) }}
apiVersion: cert-manager.io/v1
kind: {{ .Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer" }}
metadata:
  name: {{ .Values.ingress.letsEncrypt.issuerName | default "letsencrypt-prod" }}
  {{- if eq (.Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer") "Issuer" }}
  namespace: {{ .Release.Namespace }}
  {{- end }}
spec:
  acme:
    email: {{ .Values.ingress.letsEncrypt.email | quote }}
    server: |
      {{- if eq (.Values.ingress.letsEncrypt.environment | default "production" | lower) "staging" }}
      {{ .Values.ingress.letsEncrypt.server.staging }}
      {{- else }}
      {{ .Values.ingress.letsEncrypt.server.production }}
      {{- end }}
    privateKeySecretRef:
      name: {{ .Values.ingress.letsEncrypt.privateKeySecretName | default "letsencrypt-account-key" }}
    solvers:
    - http01:
        ingress:
          class: {{ .Values.ingress.className | quote }}
{{- end }}
```

**Notes:**
- Only created if `ingress.https=true` AND `letsEncrypt.enabled=true` AND `letsEncrypt.createIssuer=true` AND no `existingSecretName`.
- If `issuerKind` is `Issuer`, it must be deployed in the release namespace.
- If `issuerKind` is `ClusterIssuer`, it is cluster-scoped and can be referenced from any namespace.

---

### 2. Certificate Template

**File:** `librenms/templates/cert-manager-certificate.yaml`

```yaml
{{- if and .Values.ingress.https (or (not .Values.ingress.tls.existingSecretName) .Values.ingress.letsEncrypt.enabled) }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .Values.ingress.tls.secretName | default "https-cert" }}
  namespace: {{ .Release.Namespace }}
spec:
  secretName: {{ .Values.ingress.tls.secretName | default "https-cert" }}
  issuerRef:
    {{- if .Values.ingress.letsEncrypt.createIssuer }}
    kind: {{ .Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer" }}
    name: {{ .Values.ingress.letsEncrypt.issuerName | default "letsencrypt-prod" }}
    {{- else }}
    # Reference an existing issuer (must already exist in cluster)
    kind: {{ .Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer" }}
    name: {{ .Values.ingress.letsEncrypt.issuerName | default "letsencrypt-prod" }}
    {{- end }}
  commonName: {{ .Values.application.host.FQDN | quote }}
  dnsNames:
    - {{ .Values.application.host.FQDN | quote }}
    {{- if .Values.smokeping.enable }}
    - {{ .Values.smokeping.host.FQDN | quote }}
    {{- end }}
    {{- if .Values.oxidized.enable }}
    - {{ .Values.oxidized.host.FQDN | quote }}
    {{- end }}
{{- end }}
```

**Notes:**
- Only created if `ingress.https=true` AND (no `existingSecretName` OR `letsEncrypt.enabled=true`).
- Automatically populates the secret named by `tls.secretName`.
- Lists all FQDNs that need certificates (main app, smokeping, oxidized, etc.).

---

### 3. Ingress Annotation Adjustments

**File:** `librenms/templates/ingress.yaml` (modify annotations section)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: "{{ .Release.Name }}-application"
  namespace: {{ .Release.Namespace }}
  labels:
{{ include "common.labels" . | indent 4 }}
  annotations:
    {{- if .Values.ingress.https }}
    {{- if .Values.ingress.redirectToHttps.enabled }}
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.middlewares: {{ printf "%s-%s@kubernetescrd" .Release.Namespace (printf "%s-https-redirect" .Release.Name) | quote }}
    {{- else }}
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    {{- end }}
    traefik.ingress.kubernetes.io/router.tls: "true"
    {{- if and .Values.ingress.https .Values.ingress.letsEncrypt.enabled (not .Values.ingress.tls.existingSecretName) }}
    # cert-manager will auto-create the certificate
    cert-manager.io/cluster-issuer: {{ .Values.ingress.letsEncrypt.issuerName | default "letsencrypt-prod" | quote }}
    {{- end }}
    {{- else }}
    traefik.ingress.kubernetes.io/router.entrypoints: web
    {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className | quote }}
  {{- if and .Values.ingress.https (not .Values.ingress.tls.existingSecretName) }}
  tls:
  - hosts:
    - {{ .Values.application.host.FQDN }}
    {{- if .Values.smokeping.enable }}
    - {{ .Values.smokeping.host.FQDN }}
    {{- end }}
    {{- if .Values.oxidized.enable }}
    - {{ .Values.oxidized.host.FQDN }}
    {{- end }}
    secretName: {{ .Values.ingress.tls.secretName | default "https-cert" }}
  {{- end }}
  rules:
    # ... existing rules ...
```

**Key annotations:**
- `cert-manager.io/cluster-issuer` or `cert-manager.io/issuer`: Tells cert-manager to manage this ingress's TLS cert.
- Only added if Let's Encrypt is enabled and no pre-existing secret is provided.

---

## For ACME-DNS / goacmedns Deployment

If you are using **ACME-DNS** (e.g., hosted at `auth.vist.is`), the issuer must be configured with DNS-01 solver instead of HTTP-01.

### Modified ClusterIssuer for ACME-DNS

**File:** `librenms/templates/cert-manager-issuer-acmedns.yaml`

```yaml
{{- if and .Values.ingress.https .Values.ingress.letsEncrypt.enabled .Values.ingress.letsEncrypt.createIssuer (not .Values.ingress.tls.existingSecretName) .Values.ingress.letsEncrypt.dnsProvider }}
apiVersion: cert-manager.io/v1
kind: {{ .Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer" }}
metadata:
  name: {{ .Values.ingress.letsEncrypt.issuerName | default "letsencrypt-prod" }}
  {{- if eq (.Values.ingress.letsEncrypt.issuerKind | default "ClusterIssuer") "Issuer" }}
  namespace: {{ .Release.Namespace }}
  {{- end }}
spec:
  acme:
    email: {{ .Values.ingress.letsEncrypt.email | quote }}
    server: |
      {{- if eq (.Values.ingress.letsEncrypt.environment | default "production" | lower) "staging" }}
      {{ .Values.ingress.letsEncrypt.server.staging }}
      {{- else }}
      {{ .Values.ingress.letsEncrypt.server.production }}
      {{- end }}
    privateKeySecretRef:
      name: {{ .Values.ingress.letsEncrypt.privateKeySecretName | default "letsencrypt-account-key" }}
    solvers:
    - dns01:
        acmeDNS:
          host: {{ .Values.ingress.letsEncrypt.acmeDns.host | quote }}
          accountSecretRef:
            name: {{ .Values.ingress.letsEncrypt.acmeDns.accountSecretName | quote }}
            key: acme-dns-account.json
{{- end }}
```

### Extended Values for ACME-DNS

Add to your `lnms-config.yaml`:

```yaml
ingress:
  letsEncrypt:
    # ... existing fields ...
    dnsProvider: "acme-dns"  # or null for HTTP-01
    acmeDns:
      host: "auth.vist.is"
      accountSecretName: "acme-dns-credentials"
```

### Secret Setup for ACME-DNS

Create the ACME-DNS credentials secret before deploying:

```bash
# Pre-generate account via goacmedns and save account.json
# Then create the secret:
kubectl create secret generic acme-dns-credentials \
  --from-file=acme-dns-account.json=/path/to/.account.json \
  -n librenms
```

The account.json should contain your ACME-DNS registration:

```json
{
    "example.vist.is": {
        "fulldomain": "7c6eae4d-8805-4f2b-83dc-31dfe877d7cf.auth.vist.is",
        "subdomain": "7c6eae4d-8805-4f2b-83dc-31dfe877d7cf",
        "username": "xxxxxxxxxxxxx",
        "password": "yyyyyyyyyyyyy",
        "server_url": "https://auth.vist.is"
    }
}
```

---

## Deployment Workflow

### 1. Initial Install

```bash
# User edits lnms-config.yaml with TLS settings
./LibreNMS-Install

# This:
# - Installs cert-manager in cert-manager namespace
# - Installs helm chart

# Helm chart creates:
# - ClusterIssuer/Issuer (if createIssuer=true)
# - Certificate (references issuer, triggers certificate request)
# - Ingress (with cert-manager annotations)
```

### 2. Cert-Manager Workflow

Once resources are deployed:

```
Certificate created
  ↓ (cert-manager detects)
Issuer consulted for solver strategy
  ↓ (HTTP-01 or DNS-01)
ACME challenge initiated with Let's Encrypt
  ↓ (DNS/HTTP validation)
Certificate signed and stored in secret
  ↓ (secret populated)
Ingress uses secret for TLS
  ↓ (Traefik reads secret)
HTTPS service ready
```

### 3. Manual Cert Injection (fallback)

If cert-manager provisioning fails, users can still inject a pre-made cert:

```bash
nms cert /path/to/cert.pem /path/to/key.pem
```

This creates/updates the `https-cert` secret directly, bypassing cert-manager.

---

## Testing & Validation

### Check Certificate Status

```bash
kubectl get certificate -n librenms
kubectl describe certificate https-cert -n librenms
```

### Check Issuer Status

```bash
kubectl get clusterissuer letsencrypt-prod
kubectl describe clusterissuer letsencrypt-prod
```

### View Certificate Details

```bash
kubectl get secret https-cert -n librenms -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

### Check Ingress Status

```bash
kubectl get ingress -n librenms
kubectl describe ingress librenms-application -n librenms
```

---

## Summary

| Component | Managed By | Scope |
|-----------|-----------|-------|
| cert-manager CRDs, controller, webhooks | LibreNMS-Installer | Cluster |
| ClusterIssuer / Issuer | LibreNMS-Helm | Cluster / Namespace |
| Certificate | LibreNMS-Helm | Namespace |
| Ingress with TLS annotation | LibreNMS-Helm | Namespace |
| TLS Secret (auto-populated) | cert-manager | Namespace |
| Manual TLS Secret (fallback) | `nms cert` command | Namespace |

---

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [cert-manager ACME DNS Solver](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Traefik with cert-manager](https://doc.traefik.io/traefik/https/acme/)
