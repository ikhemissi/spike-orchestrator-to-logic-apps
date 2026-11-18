# Test-data and fault scripts

These scripts seed synthetic inputs, reset the test destinations, and inject or restore the SPEC §8 faults. Run them from an authenticated Azure CLI session after provisioning:

```sh
bash scripts/seed-test-data.sh --scenario j1
bash scripts/inject-fault.sh partner-ip-block
bash scripts/reset-environment.sh
pwsh -File scripts/seed-test-data.ps1 --scenario j1
pwsh -File scripts/inject-fault.ps1 partner-ip-block
pwsh -File scripts/reset-environment.ps1
```

`seed-test-data` accepts `j1`, `j2`, `j3`, `j3-failure`, `j4`, or `j5` and uploads the matching files from `test-data/<job>/`. The `j3-failure` case includes `FAIL_locked_file.csv` for T10; regular `j3` excludes it for T08/T09. If the ignored J1 large extract is missing, the script runs the matching `test-data/generate-large-files` script first. FTP uses passive `curl -T`; NAS inputs are sent as base64 to `NAS_SHARE_UNC` using a VM run command. NAS files over 256 KiB and encoded command scripts over 28 KiB are rejected to stay within process argument limits. The FTP password is read from Key Vault, supplied to curl through its standard input, and is not included in output or process arguments.

The scripts use the SPEC azd values from the process environment and call `azd env get-values` only when a required value is missing. They do not read Terraform state or use values outside that contract. `reset-environment` restores faults before FTP cleanup, recursively empties the partner's `/outbound/j1`, `/outbound/j2`, `/outbound/j4`, and `/outbound/archive` folders, recreates the NAS scenario directories (including `j3\archive`) empty, and deletes all blobs in `sharepoint-sim` and `run-reports`. Restoring a prior Key Vault password uses a protected temporary transport file; the restore version remains tagged in Key Vault. Use only the synthetic test environment: reset and fault commands modify deployed resources.

FTP URLs use `PARTNER_FTP_PORT` from the process environment or azd values (default `2121`); the PowerShell test environment also knows `PARTNER_SFTP_PORT` (default `2222`).

Fault state needed for restoration is kept in Azure: the partner NSG rule description, the Key Vault secret version tags, Azure resource tags, the Automation worker-group tags, or a marker on the partner VM. The NAS fault discovers the Logic App VNet integration subnet and NAS VM private IP, then scopes the deny rule to that subnet, the NAS host, and TCP 445. `restore-all` can be run repeatedly. CLI/API details that cannot be exercised offline are marked `VERIFY` in the scripts; in particular, confirm the worker-group REST API behavior and the FTP server's recursive delete commands before use.

Run the mocked offline tests and repository checks with:

```sh
bash scripts/tests/test-seed-test-data.sh
bash scripts/tests/test-inject-fault.sh
pwsh -NoProfile -Command 'Invoke-Pester -Path scripts/tests/*.Tests.ps1 -Output Detailed'
bash scripts/check.sh
```
