# Architecture

These diagrams describe the target design in [SPEC §3](SPEC.md#3-target-topology-what-terraform-must-create) and [SPEC §5](SPEC.md#5-workflows--detailed-specification). They are not a deployment report. The partner network and datacenter are simulated for the spike.

## Topology

```mermaid
flowchart LR
  subgraph Spoke["Azure spoke: vnet-spoke"]
    LA["Logic Apps Standard<br/>VNet integration<br/>snet-logicapp-int"]
    NAT["NAT Gateway<br/>NAT_PUBLIC_IP"]
  end

  subgraph Datacenter["Simulated datacenter: vnet-onprem-sim"]
    NAS["nas01.corp.local<br/>SMB share"]
    Worker["hw01<br/>Hybrid Runbook Worker"]
  end

  subgraph Partner["Simulated partner network: vnet-partner"]
    FTP["Partner A<br/>FTP"]
    SFTP["Partner B<br/>SFTP"]
  end

  subgraph AzureServices["Azure services"]
    Automation["Azure Automation<br/>hwg-spike-files"]
    KV["Key Vault"]
    RuntimeStorage["Logic Apps runtime storage"]
    ReportStorage["Blob storage<br/>run-reports"]
    Monitoring["Application Insights<br/>Log Analytics<br/>alerts and action group"]
  end

  Spoke <-->|"VNet peering simulates VPN or ExpressRoute"| Datacenter
  LA -->|"Subnet egress association, not a workload call"| NAT
  LA -->|"FTP account partner-a via NAT_PUBLIC_IP"| FTP
  LA -->|"SSH private key via NAT_PUBLIC_IP"| SFTP
  LA -->|"File System connector as nas01\svc-la"| NAS
  Worker -->|"SMB as hw01\svc-azauto"| NAS
  LA -->|"Create job as id-logicapp managed identity"| Automation
  LA -->|"Get job status as id-logicapp managed identity"| Automation
  LA -->|"Get job output as id-logicapp managed identity"| Automation
  Worker -->|"Poll and claim job as Hybrid Worker agent over outbound HTTPS 443"| Automation
  Worker -->|"Report job state and output as Hybrid Worker agent over outbound HTTPS 443"| Automation
  LA -->|"Secret references as id-logicapp managed identity"| KV
  LA -->|"Workflow reports as id-logicapp managed identity"| ReportStorage
  LA -->|"Telemetry as id-logicapp managed identity"| Monitoring
  LA -->|"Host dependency, network details # VERIFY"| RuntimeStorage
  LA -->|"Azure Monitor diagnostic setting"| Monitoring
  Automation -->|"Azure Monitor diagnostic setting"| Monitoring
```

`vnet-partner` is not peered. Partner traffic leaves the Logic Apps integration subnet through the NAT Gateway, and the partner VM allows the NAT public IP (and the deployer IP for testing). The simulated datacenter is reached through VNet peering. Optional private endpoints for Key Vault and storage are not shown.

The Logic Apps host also depends on runtime storage. The specification does not state that host connection's port, protocol, or identity; those details are marked `# VERIFY`. This is separate from the workflow's managed-identity connection to the `run-reports` Blob container.

The Automation arrows represent the logical create-job, get-status, and get-output calls. Whether to use the built-in connector or the ARM REST fallback, and the REST API version if used, remain `# VERIFY` as noted in SPEC §5.1.

## Network flows

| From | To | Port | Protocol | Purpose |
|---|---|---:|---|---|
| Logic Apps integration subnet | Partner A FTP endpoint, through NAT Gateway | TCP 21 and 40000–40100 | FTP, passive mode | List, retrieve, and archive partner files using `partner-a` credentials. |
| Logic Apps integration subnet | Partner B SFTP endpoint, through NAT Gateway | TCP 22 | SFTP over SSH | Deliver files using the SSH private key. |
| Logic Apps integration subnet | `nas01.corp.local` | TCP 445 | SMB | Built-in File System connector accesses NAS folders as `nas01\svc-la`. |
| Hybrid Runbook Worker | `nas01.corp.local` | TCP 445 | SMB | Runbook reads, writes, and archives J3 files as `hw01\svc-azauto`; the local account is mirrored on the NAS VM. |
| Hybrid Runbook Worker | Azure Automation | Outbound TCP 443 | HTTPS | Worker agent polls for jobs and reports job state and output. |
| Logic Apps | Azure Automation | TCP 443 | HTTPS | Create a Hybrid Worker job, check its status, and retrieve its output as `id-logicapp` managed identity. |
| Logic Apps | Key Vault | TCP 443 | HTTPS | Resolve workflow secrets using `id-logicapp` managed identity. |
| Logic Apps | `run-reports` Blob container | TCP 443 | HTTPS | Write workflow reports using `id-logicapp` managed identity. |
| Logic Apps | Application Insights | TCP 443 | HTTPS | Send telemetry with Entra-authenticated managed identity. |
| Logic Apps and Azure Automation | Log Analytics | N/A | Azure Monitor diagnostic settings | Export workflow and Automation diagnostics. This is a platform diagnostic path, not a workload network connection. |
| Logic Apps host | Runtime storage account | `# VERIFY` | `# VERIFY` | Host runtime dependency. The specification does not define the network port, protocol, or identity. |

The partner VM's FTP passive range and SFTP port are allow-listed for the NAT public IP and deployer IP. Network ranges, peering, and port rules follow [SPEC §3.1](SPEC.md#31-networks), [§3.4](SPEC.md#34-azure-automation), and the connector calls in [§5](SPEC.md#5-workflows--detailed-specification).

## P3 sequence: encrypt files on the NAS

```mermaid
sequenceDiagram
  autonumber
  participant LA as Logic Apps
  participant AA as Azure Automation
  participant HW as Hybrid Worker hw01
  participant NAS as NAS share
  participant Reports as run-reports Blob
  participant Monitor as Azure Monitor

  LA->>AA: Create Invoke-EncryptAndMove job on hwg-spike-files using id-logicapp managed identity
  AA-->>LA: Return Automation job ID

  par Logic Apps status polling
    loop Every 15 seconds, until terminal status or 120 polls or PT30M
      LA->>AA: Get job status using id-logicapp managed identity
      AA-->>LA: Queued, Running, or terminal status
    end
  and Hybrid Worker execution
    alt Worker is online
      HW->>AA: Poll and claim job over outbound HTTPS 443
      AA-->>HW: Dispatch runbook job
      HW->>NAS: Read j3 input, write encrypted output, archive source over SMB 445 as svc-azauto
      NAS-->>HW: File operation results
      HW->>AA: Report job state and JSON output over outbound HTTPS 443
    else Worker is offline
      Note over HW,AA: No worker poll occurs, so the job remains Queued
    end
  end
  alt Job reaches a terminal status
    LA->>AA: Get job output using id-logicapp managed identity
    AA-->>LA: Runbook JSON output
    LA->>LA: Parse JSON and check job status, runbook status, and filesFailed
    alt Job and runbook succeeded with no failed files
      LA->>Reports: Write child run report using id-logicapp managed identity
    else Job or runbook failed
      LA->>Reports: Write failed child run report using id-logicapp managed identity
      LA->>Monitor: Failed workflow or runbook diagnostic triggers alert
    end
  else Worker remains offline and job stays Queued
    LA->>LA: Terminate Failed with HYBRID_JOB_TIMEOUT
    LA->>Reports: Write failed child run report using id-logicapp managed identity
    LA->>Monitor: Timeout diagnostic triggers alert
  end
```

The worker's outbound HTTPS connection is how it polls Automation; the worker does not need an inbound connection from the Automation service. Logic Apps polls job status every 15 seconds. If the job remains queued until the 120-poll or 30-minute limit, the workflow fails with `HYBRID_JOB_TIMEOUT` and the monitoring rules can alert. See [SPEC §5.5](SPEC.md#55-wf-j3-encrypt-onprem--j3-pattern-p3) and [§6](SPEC.md#6-monitoring-and-alerts).

## Workflow patterns

- **P0 — Cloud only:** Logic Apps and built-in connectors handle the work without an on-premises agent. J1 and J2 use this pattern.
- **P1 — Agentless hybrid:** Logic Apps accesses the NAS directly through VNet integration and the File System connector. No worker runs the workflow. J4 uses P0 and P1; the optional folder-watch workflow uses P1.
- **P2 — Data gateway:** A managed connector reaches on-premises data through a gateway. This is a fallback pattern and is not built in the spike.
- **P3 — Hybrid worker:** Logic Apps starts an Azure Automation runbook on a Hybrid Runbook Worker for work that needs local files or tools, such as J3 encryption.

## Simplifications from production

- **Network link:** VNet peering between the spoke and simulated datacenter stands in for VPN or ExpressRoute.
- **Worker hosting:** The Hybrid Runbook Worker runs on an Azure VM rather than an Azure Arc-enabled datacenter server.
- **File-share identity:** Local accounts, including a mirrored `svc-azauto` account for SMB access, stand in for domain accounts managed by Active Directory.
