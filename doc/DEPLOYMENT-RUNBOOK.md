# LibreNMS Deployment Runbook (K3s + Helm)

This runbook replaces older Confluence notes and reflects the current installer behavior for `nms`, TLS certificate deployment, and SAML/Socialite authentication.

Companion documents:

- Customer handoff (one-page): [CUSTOMER-HANDOFF-QUICKSTART.md](CUSTOMER-HANDOFF-QUICKSTART.md)
- Internal operator troubleshooting: [OPERATOR-RUNBOOK-TROUBLESHOOTING.md](OPERATOR-RUNBOOK-TROUBLESHOOTING.md)

## 1. What This Deployment Includes

- LibreNMS web application
- LibreNMS poller/dispatcher
- SNMP trap receiver
- Syslog receiver
- MariaDB
- Redis
- RRDcached
- MSMTPD relay
- Oxidized (optional)
- Smokeping (optional)
- xMatters transporter (optional)

## 2. Default Platform Tweaks Applied

By default in chart values, this stack is tuned to:

- Use RRDcached for better graph scaling
- Support multiple pollers via dispatcher replicas
- Enable Weathermap plugin scheduling
- Enable Billing
- Enable Syslog ingestion
- Disable LibreNMS Services monitoring
- Use SVG graphs with dynamic zoom enabled
- Prefer sysName display for devices
- Apply parsing labels for customers/peering/transit/core

## 3. Host Prerequisites

- Ubuntu 24.04 server
- Suggested baseline for ~100 devices: 4 vCPU, 8 GB RAM, 120 GB disk
- If VM on VMware: install `open-vm-tools`
- Sudo access for installer user

Optional passwordless sudo:

```bash
sudo visudo
# add:
# <username> ALL=(ALL) NOPASSWD: ALL
```

## 4. Information To Gather Before Deployment

### 4.1 Server

- Server IP address
- Admin user credentials

### 4.2 DNS

Create DNS records pointing to this server:

- LibreNMS FQDN (example: `nms.company.com`)
- Oxidized FQDN if enabled (example: `ox.company.com`)
- Smokeping FQDN if enabled

### 4.3 TLS Strategy

Choose one:

- Static/manual certificate secret
- Let's Encrypt using cert-manager (HTTP-01 or ACME-DNS)

If using ACME-DNS, coordinate one-time CNAME creation with DNS team.

### 4.4 LibreNMS Discovery/SNMP

- Networks/IP ranges to scan
- SNMP v2c communities or SNMP v3 credentials

### 4.5 Integrations

- Oxidized backup credentials
- External auth details (GitHub, Microsoft, Okta, or SAML2 metadata)
- Alert destination requirements (Sensa, xMatters, other)

## 5. Install The Platform

Run installer:

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/LoveSkylark/LibreNMS-Installer/main/LibreNMS-Install | sudo bash
```

After completion, open a new shell and run:

```bash
sudo -i
nms start
```

## 6. First Startup Configuration

When `nms start` opens the values file, set at minimum:

- `storage.path`
- `application.host.FQDN`
- `application.host.volumeSize`
- `mariadb.credentials.rootPassword`
- `mariadb.credentials.user`
- `mariadb.credentials.password`

Save and exit editor (`Esc`, `:wq`).

Useful non-interactive option:

```bash
nms start --non-interactive
```

## 7. Current nms Command Behavior

Common commands:

- `nms preflight` checks dependencies, values file, chart path, and cluster reachability
- `nms start` installs stack from current values
- `nms edit` opens values and upgrades release
- `nms update` upgrades release without opening editor
- `nms stop` removes release
- `nms status` shows app pod state
- `nms monitor` opens k9s
- `nms map` runs Weathermap poller

Automation details:

- `nms start/edit/update` auto-check TLS values
- If TLS automation is required by values, cert-manager controller is bootstrapped automatically
- ACME-DNS credentials are imported automatically when present
- Local host SNMP auto-add runs by default after install (can be disabled)

Useful flags/env:

- `--non-interactive` / `-n`
- `--no-auto-add-host`
- `NMS_NO_EDITOR=1`
- `NMS_AUTO_ADD_HOST=0`
- `NMS_NAMESPACE=<namespace>`

## 8. TLS Certificate Deployment (Updated)

### Option A: Static/Manual Certificate Secret

1. Create/update secret directly with helper:

```bash
nms cert static /path/to/cert.pem /path/to/key.pem
```

1. Set values:

```yaml
ingress:
  https: true
  tls:
    existingSecretName: "https-cert"
```

### Option B: Let's Encrypt With ACME-DNS

1. Pre-register domain credentials:

```bash
nms cert register nms.example.com
```

Optional overrides:

```bash
nms cert register nms.example.com auth.example.com
nms cert register nms.example.com auth.example.com /data/certs/custom.json
```

1. Create required DNS CNAME from command output:

- `_acme-challenge.<domain>` -> `<acme-dns-fulldomain>`

1. Configure values:

```yaml
ingress:
  https: true
  letsEncrypt:
    enabled: true
    createIssuer: true
    email: "admin@example.com"
    acmeDns:
      host: "auth.example.com"
      accountSecretName: "acme-dns-credentials"
  tls:
    existingSecretName: ""
    secretName: "https-cert"
```

1. Apply:

```bash
nms update
```

Health check helper:

```bash
nms cert check
```

Important notes:

- Per-domain ACME-DNS credentials are saved as `/data/certs/acme-dns-account.<domain>.json`
- Merged credentials are saved as `/data/certs/acme-dns-account.json`
- Issuer/Certificate resources are managed in Helm templates, not as direct `nms` subcommands

## 9. SAML/Social Login Configuration (Updated)

SAML/social login is configured in `lnms-config.yaml` under `saml:`.

Supported providers:

- `github`
- `microsoft`
- `okta`
- `saml2`

Base example:

```yaml
saml:
  enable: true
  provider: "microsoft"
  redirect: true
  register: false
  default_role: "global-read"
  client_id: "<client-id>"
  client_secret: "<client-secret>"
  callback: "https://nms.example.com/auth/microsoft/callback"
  tenant: "common"
  claim_field: "roles"
  claims:
    librenms-admin:
      - "admin"
    librenms-read:
      - "global-read"
```

For SAML2 IdP metadata flow:

```yaml
saml:
  enable: true
  provider: "saml2"
  saml2:
    metadata: "https://idp.example.com/metadata"
```

Plugin requirement:

- Set `application.lnms.installPlugins` to the needed provider package(s), for example:
  - Microsoft: `socialiteproviders/microsoft`
  - GitHub: `socialiteproviders/github`
  - Okta: `socialiteproviders/okta`
  - SAML2: `socialiteproviders/saml2`

After changing SAML config, apply with:

```bash
nms update
```

## 10. Oxidized Setup (Post-Install)

1. In LibreNMS UI, generate API token
2. Update values:

- `oxidized.credentials.token`
- `oxidized.group.core.user`
- `oxidized.group.core.password`

1. Apply and restart oxidized pod if needed:

```bash
nms update
k9s
# delete oxidized pod so it recreates with new config
```

## 11. xMatters Setup

If `xmatters.enable=true` and `xmatters.agent.enable=true`, transporter is deployed with the stack.

Configure:

- `xmatters.agent.URL`
- `xmatters.agent.APIkey`
- `xmatters.agent.APIsecret`

Then run:

```bash
nms update
```

## 12. Post-Deployment Checklist

- `nms status` shows healthy pod(s)
- Web UI reachable on configured FQDN
- TLS certificate is valid (if HTTPS enabled)
- At least one admin user exists
- Polling and discovery jobs are running
- Syslog/SNMP trap ingestion verified if enabled
