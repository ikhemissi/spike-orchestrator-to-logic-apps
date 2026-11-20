# Demo runbook

A 20-minute walkthrough for an operator who has provisioned and deployed the spike. The environments are simulations: the partner VM represents external partners, and Azure VM workers connected by VNet peering represent an on-premises datacenter.

## Before the demo

1. Authenticate with Azure CLI and select the azd environment used for the demo:

   ```sh
   az login
   azd auth login
   azd env select <environment-name>
   az account show
   ```

2. Confirm that the Logic App has `wf-j1-partner-ftp-to-sftp`, `wf-diag-egress-ip`, `wf-j4-ftp-sort-to-nas`, and `wf-j3-convert-onprem`, and that the Automation account has the `Invoke-ConvertAndMove` runbook. Deploy the current package first (`scripts/deploy-logicapp.sh`).
3. Resume the environment to start the VMs and enable the job workflows:

   ```sh
   bash scripts/resume-environment.sh
   ```

4. Check `JOB_RECURRENCE_MINUTES`. Its normal value is 15; if a scheduled run could overlap the demo, raise it (for example, to 1440 minutes) first:

   ```sh
   resource_group="$(azd env get-value AZURE_RESOURCE_GROUP)"
   logic_app="$(azd env get-value LOGIC_APP_NAME)"
   az logicapp config appsettings list --resource-group "$resource_group" --name "$logic_app" \
     --query "[?name=='JOB_RECURRENCE_MINUTES'].value | [0]" --output tsv
   ```

   If a scheduled run could overlap the demo, raise the interval, for example to 1440 minutes:

   ```sh
   resource_group="$(azd env get-value AZURE_RESOURCE_GROUP)"
   logic_app="$(azd env get-value LOGIC_APP_NAME)"
   az logicapp config appsettings set --resource-group "$resource_group" --name "$logic_app" \
     --settings "JOB_RECURRENCE_MINUTES=1440" --output none
   ```

5. Reset the test resources and seed J1. The reset restores injected faults, empties the test destinations, and deletes test report blobs.

   ```sh
   bash scripts/reset-environment.sh
   bash scripts/seed-test-data.sh --scenario j1
   ```

6. To fit the worker-offline demonstration into the session, configure the deployed Logic App parameter `j3PollTimeout` as `PT5M` before the demo. Its checked-in default is `PT30M`; allow more time if using the default. The worker-offline step fails with `HYBRID_JOB_TIMEOUT` after five minutes when `j3PollTimeout=PT5M`. The `alert-hybrid-job-stuck` rule also checks for jobs queued over 10 minutes, so its alert can appear during the later workbook segment rather than immediately after the worker stops.

The simulated partner listens on FTP TCP port 2121 and SFTP TCP port 2222 (decision D9). All commands below run from the repository root in an authenticated shell. The seed and fault scripts load missing settings from the selected azd environment. Portal paths refer to the deployed resource group.

## Steps

| Time | Demo and exact action | What the audience should see |
|---|---|---|
| 0–2 min | Open [docs/ARCHITECTURE.md](ARCHITECTURE.md) and show the topology and P0–P3 workflow patterns. In Azure portal, open the deployed resource group and point out the Logic App, simulated partner, NAS, worker, and Automation account. | J1 is P0; J4 combines P0/P1; J3 uses P3. P2 (a data gateway) is a documented fallback and is not built. Peering and Azure-hosted VMs simulate the datacenter connection and workers. |
| 2–6 min | In Azure portal, open the Logic App Standard resource → **Workflows** → `wf-j1-partner-ftp-to-sftp` → **Overview** → **Run Trigger** → `Recurrence` → **Run**. Open the resulting run under **Runs history**. To show egress, open `wf-diag-egress-ip` → **Overview**, copy its HTTP trigger callback URL without sharing it, then run `curl --fail --silent --show-error --request POST "$DIAG_TRIGGER_URL"` in a shell where `DIAG_TRIGGER_URL` contains that URL. Compare the returned IP with `azd env get-value NAT_PUBLIC_IP`. To inspect the partner destination, run: `az vm run-command invoke --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" --name "$(azd env get-value PARTNER_VM_NAME)" --command-id RunShellScript --scripts "find /srv/sftp/partner-b/inbound -maxdepth 1 -type f -printf '%f %s bytes\n'" --output json`. | The J1 run succeeds. Run history shows the action sequence and tracked properties, including the correlation ID and delivered-file count. Partner B's `/inbound` directory contains the delivered files. The egress response matches the NAT public IP; do not display or share the trigger callback URL. |
| 6–9 min | Inject the partner allow-list fault: `bash scripts/inject-fault.sh partner-ip-block`. In the portal, run `wf-j1-partner-ftp-to-sftp` again using **Run Trigger** → `Recurrence` → **Run**. After observing the failure, restore access and resubmit: `bash scripts/inject-fault.sh restore-all`, `bash scripts/reset-environment.sh`, then `bash scripts/seed-test-data.sh --scenario j1`; run the workflow once more from the portal. | The blocked run fails when the Logic App can no longer reach the partner through the NAT IP; the workflow-failure alert fires on its next evaluation; the e-mail usually arrives 5–15 minutes later, so show an alert e-mail from an earlier rehearsal if needed. After restoration and reseeding, the run succeeds and the files are delivered. |
| 9–12 min | Reset and seed J4: `bash scripts/reset-environment.sh` then `bash scripts/seed-test-data.sh --scenario j4`. In the Logic App portal page, run `wf-j4-ftp-sort-to-nas` using **Workflows** → workflow → **Overview** → **Run Trigger** → `Recurrence` → **Run**. In the Azure portal, open the NAS VM → **Operations** → **Run command** → **RunPowerShellScript**, and run: `$share = '\\nas01.corp.local\share'; Get-ChildItem (Join-Path $share 'j4') -Recurse -File | Select-Object -ExpandProperty FullName`. | `budget_q4.csv` is in `j4\finance`, `contract_partner_x.pdf` in `j4\documents`, `order_000123.xml` in `j4\integration`, and `unknown_payload.dat` in `j4\quarantine`. This path uses the File System connector; it does not run on a Hybrid Worker. |
| 12–17 min | Reset and seed J3: `bash scripts/reset-environment.sh` then `bash scripts/seed-test-data.sh --scenario j3`. Run `wf-j3-convert-onprem` from **Workflows** → workflow → **Overview** → **Run Trigger** → `Recurrence` → **Run**. In the Automation account, open **Process Automation** → **Jobs**, select the new `Invoke-ConvertAndMove` job, and show **Output**. In the NAS VM's **Run command** → **RunPowerShellScript**, run: `$share = '\\nas01.corp.local\share'; Get-ChildItem (Join-Path $share 'j3\out') -File | Select-Object -ExpandProperty Name`. Then inject the offline-worker fault with `bash scripts/inject-fault.sh worker-stop` and run J3 again from the portal. After showing the queued job and failed workflow (up to five minutes with `j3PollTimeout=PT5M`), restore the worker with `bash scripts/inject-fault.sh restore-all`. | The successful Automation job output is JSON and identifies `hw01\svc-azauto` as the run-as account; converted JSON files appear in `j3\out` and source CSV files are archived. With the worker stopped, the Automation job remains queued and the workflow ends with `HYBRID_JOB_TIMEOUT`. The worker-offline alert may take longer than this segment to appear; check it in the final workbook step. |
| 17–20 min | In Azure portal, open the Log Analytics workspace → **Workbooks** → **Orchestrator to Logic Apps monitoring**. **Business view:** totals, success rate and files per job; failed runs explained in plain words (partner unreachable, login refused, NAS unreachable, worker offline). Click a failed run: its steps appear at the bottom, from Application Insights, with the failing step. Enter the J3 run's correlation ID (from its run report): the trace shows the workflow steps and the Automation job on its worker. Then open **Key Vault → Secrets** to show that partner and service-account credentials live only there. | The tiles and tables show the day's runs; a failed run's steps identify the failing action; the trace links the Logic Apps run and the Automation job; no secret appears in any workflow or script. |

## After the demo

Always restore injected state, even if a demonstration step fails:

```sh
bash scripts/inject-fault.sh restore-all
bash scripts/pause-environment.sh
```

`scripts/pause-environment.sh` disables the job workflows and deallocates the VMs. To clear the test files and report blobs as well, run `bash scripts/reset-environment.sh`. The daily auto-shutdown schedule is 20:00 Romance Standard Time. Remove the environment when the spike is finished with `azd down --purge`.
