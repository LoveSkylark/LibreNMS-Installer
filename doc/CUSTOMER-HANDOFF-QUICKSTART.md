# LibreNMS Customer Handoff Quickstart

Use this guide for day-1 handoff. It contains only the minimum steps needed to access and operate the service.

## 1. What You Are Getting

- LibreNMS web monitoring platform
- Polling/discovery stack
- Syslog and trap handling (if enabled)
- Optional modules: Oxidized, Smokeping, xMatters

## 2. Access Information To Receive

- LibreNMS URL: `https://<nms-fqdn>`
- Initial admin username
- Initial admin password (or SSO instructions)
- Support contact/escalation path

## 3. First Login

1. Open LibreNMS URL in browser
1. Sign in with provided credentials (or SSO)
1. Confirm dashboard loads and devices are visible

## 4. If SSO Is Enabled

Supported sign-in providers:

- Microsoft
- GitHub
- Okta
- SAML2 IdP

If SSO login fails, provide screenshot + timestamp to operations team.

## 5. Basic Day-1 Validation

1. Confirm devices are polling
1. Check alert rules are active
1. Confirm graphs render and update
1. Confirm syslog/traps appear (if included in your service)

## 6. Typical Customer Tasks

- Add/update devices in LibreNMS UI
- Acknowledge/close alerts
- Manage alert routing in agreed channels
- Use dashboards/reports for operations

## 7. Optional Oxidized Setup (If Included)

1. In LibreNMS UI, generate API token
1. Send token to operations team for backend config
1. Confirm config backups appear after sync

## 8. Optional xMatters Setup (If Included)

1. Provide xMatters tenant URL
1. Provide API key/secret to operations team
1. Validate a test alert delivery

## 9. Change Requests

Send these changes to operations team:

- TLS/certificate changes
- DNS/FQDN changes
- SSO provider or claim mapping changes
- Storage/database scaling changes

## 10. Fast Escalation Checklist

When opening a support case, include:

- Tenant/company name
- Affected URL/device(s)
- Time issue started
- Error text or screenshot
- Whether issue impacts all users or only specific users
