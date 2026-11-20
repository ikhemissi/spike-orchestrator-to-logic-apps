# 03 — An Azure Arc-enabled server as the hybrid worker

**Date:** 2026-11-20 · **Answers:** Q4 (production path) · **Versions:** Azure Connected Machine agent 1.70, Hybrid Worker extension for Windows 1.3.76, Windows Server 2022

## Goal

On-premises, the hybrid workers would be Azure Arc-enabled servers: Arc gives a non-Azure server a managed identity, and the Hybrid Worker extension uses it to talk to Azure Automation. The spike's workers are Azure VMs. This experiment tries to run the J3 worker on an Arc-enabled server instead.

## Setup

A Windows Server 2022 VM `arc01` in the simulated datacenter's subnet, prepared as the worker (PowerShell 7, the conversion tool, the `svc-azauto` account), then made to look like a non-Azure server as described in [Evaluate Azure Arc-enabled servers on an Azure virtual machine](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine): all VM extensions removed, the Azure guest agent disabled, outbound access to the Azure metadata endpoint (`169.254.169.254`) blocked, `MSFT_ARC_TEST=true`.

## Steps and result

1. **Arc onboarding: worked.** The Connected Machine agent installed from `https://aka.ms/AzureConnectedMachineAgent`; `azcmagent connect` (with an access token of the operator's Azure CLI session) went from `AwaitingConnection` to `Connected` in about a minute. The machine got a system-assigned managed identity, served locally on `http://localhost:40342`, and Arc Run Command ran scripts on it.
2. **Worker registration: accepted.** The machine registered in the worker group with its Arc resource ID (worker type `HybridV2`).
3. **Hybrid Worker extension, installed through Arc: failed** with "Unable to connect to the remote server". Its log shows why: the extension reads the machine's BIOS asset tag, recognises the tag every Azure VM carries, and calls the Azure VM metadata endpoint `169.254.169.254`, which the evaluation setup blocks, instead of Arc's local endpoint.

So an Azure VM disguised as an on-premises server is enough to evaluate Arc onboarding, but not the Hybrid Worker extension: that needs a machine whose hardware is not Azure's (an on-premises server, a VM on a laptop or in another hypervisor, or a nested VM inside an Azure VM).

A Hyper-V VM on a laptop was the next option; it was not available, and the test stopped there. The test resources were deleted.

## What it means

- Arc onboarding itself is simple: one agent, outbound HTTPS, one `connect` command, and the server has a managed identity usable by extensions.
- The worker on Arc remains to be shown end to end. Microsoft documents the extension-based Hybrid Runbook Worker on Arc-enabled servers; the [retest plan](../RETEST-PLAN.md) lists the test on a non-Azure machine.
- Connecting a server to Arc and running extensions on it has no Arc charge; Azure Automation job minutes are billed as for any worker ([Azure Arc pricing](https://azure.microsoft.com/pricing/details/azure-arc/core-control-plane/), [Automation pricing](https://azure.microsoft.com/pricing/details/automation/), 2026-11-20).
