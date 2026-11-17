# Synthetic test data

All records are deterministic and synthetic. Seed only the files needed for a
scenario; do not upload the generated large extract unless the scenario calls
for it.

| Files | Destination | Scenario |
| --- | --- | --- |
| `j1/invoices_20261124_001.csv`, `j1/invoices_20261124_002.csv`, and `j1/large_partner_extract.csv` | Partner A FTP `/outbound/j1` | J1 happy path and re-run/idempotency (T02–T03); the large extract exercises streaming. |
| `j1/~lock_invoices.csv` | Partner A FTP `/outbound/j1` | J1 filter check (T02); the `~lock_*` file must be ignored. |
| `j2/brochure_export_fr.pdf`, `j2/participants_salon_2026.csv` | Partner A FTP `/outbound/j2` | J2 happy path (T14). |
| `j3/payroll_extract_202611.csv`, `j3/hr_movements_202611.csv` | NAS `\\nas01\share\j3\in` | J3 happy path and idempotency (T08–T09). |
| `j3/FAIL_locked_file.csv` | NAS `\\nas01\share\j3\in` | J3 per-file failure (T10); include only for that scenario. |
| `j4/budget_q4.csv` | Partner A FTP `/outbound/j4`; expected NAS destination `j4\finance` | J4 routing (T06). |
| `j4/contract_partner_x.pdf` | Partner A FTP `/outbound/j4`; expected NAS destination `j4\documents` | J4 routing (T06). |
| `j4/order_000123.xml` | Partner A FTP `/outbound/j4`; expected NAS destination `j4\integration` | J4 routing (T06). |
| `j4/unknown_payload.dat` | Partner A FTP `/outbound/j4`; expected NAS destination `j4\quarantine` | J4 unknown-format quarantine (T06). |
| `j5/folderwatch_test.txt` | NAS `\\nas01\share\folderwatch\in` | Optional J5 folder-watch scenario (T18). |

Generate the ignored, approximately 20 MB J1 extract from either shell with
`./test-data/generate-large-files.sh` or
`pwsh -File ./test-data/generate-large-files.ps1`. Both write the same
deterministic CSV to `j1/large_partner_extract.csv`.

Run the offline fixture and generator checks with
`pwsh -Command "Invoke-Pester -Path ./test-data/tests/test-data.Tests.ps1"`.
