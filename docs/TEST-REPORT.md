# Test report

## Run 2026-11-18 13:21:34 +01:00

| Scenario | Result | Run ID | Run status | Action statuses | Tracked properties | File listings | Details |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T01-egress-ip | Failed |  |  | {} | {} | {} | az keyvault failed with exit code 2 |
| T02-j1-happy-path | Failed |  |  | {} | {} | {} | az keyvault failed with exit code 2 |
| T03-j1-idempotency | Failed | 08584066024398250046813872082CU00 | Failed | {"Init_StartedAt":"Succeeded","Rename_to_final":"Failed","Record_skipped":"Skipped","Delete_source":"Skipped","List_source_files":"Succeeded","Scope_Finally":"Skipped","Count_skipped":"Skipped","Report_failure":"Succeeded","Upload_partial":"Succeeded","Record_delivered":"Skipped","Report_success":"Skipped","Count_delivered":"Skipped","Init_FilesSkipped":"Succeeded","Get_target_metadata":"Succeeded","Get_source_content":"Succeeded","Terminate_failed":"Succeeded","Scope_Catch":"Cancelled","Filter_csv_files":"Succeeded","Filter_failed_actions":"Succeeded","Scope_Try":"Failed","Archive_source":"Skipped","Compose_summary":"Skipped","Init_FilesDelivered":"Succeeded","Already_delivered":"Failed","For_each_file":"Failed","Init_CorrelationId":"Succeeded","Init_Files":"Succeeded","Track_file":"Skipped"} | {} | {} | J1 duplicate run ended with 'Failed'. |
| T15-chaining | Failed |  |  | {} | {} | {} | az keyvault failed with exit code 2 |
