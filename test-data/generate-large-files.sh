#!/usr/bin/env bash
# Writes j1/large_partner_extract.csv (~20 MB of synthetic invoices), byte-identical to generate-large-files.ps1.
# Values derive from the row number instead of a random generator, so Bash and PowerShell produce the same bytes.
set -euo pipefail

row_count=400000
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_file="$script_directory/j1/large_partner_extract.csv"
temporary_file="$output_file.tmp"
mkdir -p "$(dirname "$output_file")"
trap 'rm -f "$temporary_file"' EXIT

{
  printf 'invoiceId,partnerId,amount,currency,date\n'
  for ((row_number = 1; row_number <= row_count; row_number++)); do
    partner_number=$((row_number % 20 + 1))
    amount_in_cents=$((row_number * 7919 % 500000 + 100))
    day_of_month=$((row_number % 28 + 1))
    printf 'INV%010d,PARTNER%04d,%d.%02d,EUR,2026-11-%02d\n' \
      "$row_number" "$partner_number" "$((amount_in_cents / 100))" "$((amount_in_cents % 100))" "$day_of_month"
  done
} > "$temporary_file"

mv "$temporary_file" "$output_file"
trap - EXIT
