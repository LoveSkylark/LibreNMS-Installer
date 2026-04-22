# LibreNMS Installer

This repository bootstraps a single-node LibreNMS deployment on K3s, installs helper tooling, and provides shell shortcuts for day-to-day management.

## What gets installed

- K3s
- Helm
- K9s
- SNMP tooling (`snmp`, `snmpd`)
- Profile helpers under `/etc/profile.d/`

## Quick start

1. Run the installer as a user with sudo access:

```bash
chmod +x ./LibreNMS-Install
./LibreNMS-Install
```

Installer run options:

- `./LibreNMS-Install --dry-run` preview actions without changing the system
- `./LibreNMS-Install --skip-upgrade` skip `apt-get upgrade`

2. Open a new shell session (or source `/etc/profile.d/*.sh`).
3. Start LibreNMS:

```bash
nms start
```

4. Verify pod status:

```bash
nms status
```

## Important paths

- Main data directory: `${LNMS_DIR:-/data}`
- Runtime values file: `${LNMS_DIR:-/data}/lnms-config.yaml`
- Chart clone path: `${LNMS_DIR:-/data}/vault/LibreNMS-Helm`

## Common commands

- `nms start` Install LibreNMS release
- `nms stop` Uninstall LibreNMS release
- `nms edit` Edit values file and apply upgrade
- `nms update` Apply Helm upgrade from current values
- `nms preflight` Validate dependencies, chart path, values file, and cluster reachability
- `nms status` Describe LibreNMS app pod
- `nms monitor` Open K9s
- `nms map` Run Weathermap poller inside app pod
- `nms cert static <cert> <key>` Create/update TLS secret `https-cert` in namespace `librenms`
- `nms cert register <domain> [output_file]` Pre-register ACME-DNS account credentials before deployment (default output: `/data/certs/acme-dns-account.json`)
- `nms help` Print local command help

Automatic TLS prerequisites:

- During `./LibreNMS-Install`, the installer reads `ingress.*` from `lnms-config.yaml`.
- If `ingress.https=true`, `ingress.letsEncrypt.enabled=true`, and `ingress.tls.existingSecretName` is empty, it installs/updates `cert-manager` (cluster infrastructure only).
- `nms start`, `nms edit`, and `nms update` re-check the current `lnms-config.yaml` before Helm install/upgrade and bootstrap `cert-manager` first when the values require it.
- `Issuer`/`ClusterIssuer`/`Certificate` resources should be managed in LibreNMS-Helm manifests, not in `nms` helper commands.
- See [HELM-TLS-DEPLOYMENT.md](doc/HELM-TLS-DEPLOYMENT.md) for detailed Helm chart implementation instructions (templates, values, ACME-DNS setup).

## TLS Certificate Deployment Options

### Option 1: Manual Static Certificate

Use pre-generated certificates (self-signed, commercial CA, or wildcard):

1. Generate or obtain your certificate and key files
2. Deploy to cluster:
   ```bash
   nms cert static /path/to/cert.pem /path/to/key.pem
   ```
3. Set in `lnms-config.yaml`:
   ```yaml
   ingress:
     https: true
     tls:
       existingSecretName: "https-cert"
   ```
4. Deploy: `nms start`

**Advantages:** No external dependencies, works offline, simple for wildcard certs
**Disadvantages:** Manual renewal required before expiry

### Option 2: Let's Encrypt with ACME-DNS Automatic Renewal

Use Let's Encrypt for free certificates with automatic renewal via DNS-01 challenge (ACME-DNS):

#### Prerequisites

1. **Manual DNS CNAME registration required:** Your DNS team must register the ACME-DNS validation CNAME in your DNS zone. This is a one-time setup.

#### Deployment Steps

1. Pre-register your domain with ACME-DNS server:
   ```bash
   nms cert register nms.example.com
   ```
   Output shows the CNAME to send to your DNS team.

2. **Email CNAME to DNS team** (one-time):
   ```
   Domain: nms.example.com
   CNAME: <fulldomain-from-output>.your-acme-dns-server.example.com
   ```
   Wait for confirmation the CNAME is registered.

3. Configure `lnms-config.yaml`:
   ```yaml
   ingress:
     https: true
     letsEncrypt:
       enabled: true
       createIssuer: true
       email: "admin@example.com"
       acmeDns:
         host: "your-acme-dns-server.example.com"
         accountSecretName: "acme-dns-credentials"
   ```

4. Deploy:
   ```bash
   nms start
   ```
   The secret will be auto-imported and cert-manager will handle renewals.

**Advantages:** Free certificates, automatic renewal, no manual intervention after initial CNAME registration
**Disadvantages:** Requires DNS team coordination for CNAME registration, depends on ACME-DNS service availability

**Important Restriction:** ACME-DNS CNAME registration must be done manually by your DNS team. The `nms cert register` command only generates the credentials and outputs the CNAME to register—it does not update DNS records directly.

### Choosing Between Options

- **Use Manual Static** if: You have wildcard certificates, prefer simplicity, or have infrequent certificate needs
- **Use ACME-DNS** if: You want automatic renewal, zero downtime on cert expiry, and can coordinate one-time CNAME registration with DNS team

For detailed implementation including Helm templates and architecture, see [HELM-TLS-DEPLOYMENT.md](doc/HELM-TLS-DEPLOYMENT.md).

Automation options for `start` and `edit`:

- `--non-interactive` or `-n` Skip opening `vim`
- `--no-auto-add-host` Skip automatic `lnms device:add` for the local host

Environment variable overrides:

- `NMS_NO_EDITOR=1`
- `NMS_AUTO_ADD_HOST=0`
- `NMS_HOST_IP=<ip>` force the IP used for auto host add
- `NMS_NAMESPACE=<namespace>` override the target namespace (default: `librenms`)

Installer version pinning (optional):

- `K3S_CHANNEL=stable` install channel for K3s
- `K3S_VERSION=<version>` pin K3s version (example: `v1.32.4+k3s1`)
- `K9S_VERSION=<version>` pin K9s version (example: `v0.40.10`)
- `HELM_VERSION=<version>` pin Helm version (example: `v3.18.2`)

## Notes

- The installer is designed to be idempotent for clone/copy steps.
- Helm operations use namespace `librenms`.
- Helm shorthand commands (`hin`, `hup`, `hun`) also use `librenms` by default.
- Update placeholders in `config/lnms-config.yaml` before production use.