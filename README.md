# Nutanix Zero-Touch Deployment Manager

Nutanix Zero-Touch Deployment Manager (ZTDM) is an end-to-end automation solution for deploying Nutanix clusters from bare metal to a fully operational state, without manual intervention. It consists of a web-based management portal and a PowerShell automation pipeline that together orchestrate the complete cluster deployment lifecycle.

---

## Overview

Deploying a new Nutanix cluster traditionally requires engineers to perform a lengthy sequence of manual tasks across multiple interfaces — iLO, Foundation, Prism Central, DNS, and more. NZTD eliminates that by providing a single, controlled entry point through a web UI, with the automation pipeline handling all underlying operations sequentially and reliably.

The solution is designed for enterprise environments where clusters are deployed at remote or branch sites from a centralised jump server, with all configuration, credentials, and audit history managed securely in one place.

---

## Architecture

```
Operator (Browser)
    │
    │  HTTPS
    ▼
Zero Touch Deployment Manager       ← Windows jump server
(Node.js web app)
    │
    │  SSH — triggers pipeline with config
    ▼
ZTD Automation Pipeline             ← PowerShell on jump server
    │
    ├──► iLO / BMC (Redfish API)    ← Remote site bare-metal nodes
    ├──► Foundation Central         ← HUB site — node discovery & OS imaging
    ├──► Prism Central              ← HUB site — cluster registration & configuration
    ├──► DNS (Windows DNS / WinRM)  ← Corporate DNS — A records
    └──► CyberArk                   ← Credential vault — post-deployment secret storage
```

Real-time pipeline output is streamed back to the browser via WebSocket, and an email notification is sent upon completion or failure.

---

## Components

### Zero Touch Deployment Manager

A secure, HTTPS web portal that serves as the operator interface for the solution. Engineers log in, provide cluster configuration details through a structured form, and trigger deployments. The portal handles authentication, authorisation, and audit logging centrally.

**Key capabilities:**
- Role-based access control with local user accounts or Active Directory (LDAP) integration
- Structured deployment configuration form with validation
- Real-time deployment progress monitoring via WebSocket
- Deployment history and full audit log dashboard
- Admin panel for user management, SMTP configuration, and AD settings
- Self-signed SSL certificate generation included — no external CA required

→ [Setup guide, configuration reference, and API documentation](deploy-cluster-app/public/help-app.html)

---

### ZTD Automation Pipeline

A PowerShell pipeline (`Start-Pipeline.ps1`) that executes all deployment operations in a defined sequence — from booting nodes via iLO virtual media through OS imaging, cluster formation, and post-deployment configuration. It can be triggered from the web portal or run directly from PowerShell on the jump server.

**Key capabilities:**
- Pre-flight validation of all parameters and network connectivity before any changes are made
- Automatic recovery support — resume from any point after a partial failure
- Dry-run mode for validating configuration without making changes
- Individual step override — skip or restart specific stages as needed
- Structured JSON configuration file — one file defines the entire deployment
- Pipeline logs retained per run for troubleshooting

→ [Pipeline reference, parameters, configuration schema, and troubleshooting](deploy-cluster-app/public/help-pipeline.html)

---

## Prerequisites

| Requirement | Details |
|---|---|
| Jump server | Windows Server with PowerShell 7, Node.js 18+, and Posh-SSH module |
| Network access | Jump server must reach iLO IPs, Foundation Central, and Prism Central |
| Foundation Central | Running at HUB site with API key provisioned via DHCP vendor options |
| Prism Central | Existing instance at HUB site — clusters are registered here post-imaging |
| Witness VM | Required for two-node cluster deployments |
| Image files | Phoenix ISO, AOS package, and AHV ISO accessible via URL (e.g. Azure Blob) |
| DNS service account | Account with permission to create A records in Windows DNS |
| CyberArk | Required if using the credential import step (optional) |

---

## Getting Started

```powershell
# Run as Administrator on the jump server
cd deploy-cluster-app
.\start.ps1
```

`start.ps1` installs all dependencies, generates an SSL certificate, creates the default configuration, and registers the application as a Windows service. Once complete, open `https://<jump-server>:3443` in a browser to access the portal.

For a full walkthrough including manual setup steps, environment variables, and pipeline configuration, refer to the component documentation linked above.
