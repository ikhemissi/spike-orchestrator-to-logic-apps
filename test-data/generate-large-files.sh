#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_file="$script_directory/j1/large_partner_extract.csv"
temporary_file="$output_file.tmp"
mkdir -p "$(dirname "$output_file")"
trap 'rm -f "$temporary_file"' EXIT

{
  printf 'invoiceId,partnerId,amount,currency,date\n'
  for ((row_number = 1; row_number <= 400000; row_number++)); do
    printf 'INV%010d,PARTNER%04d,1234.56,EUR,2026-11-24\n' \
      "$row_number" "$((row_number % 20 + 1))"
  done
} > "$temporary_file"

mv "$temporary_file" "$output_file"
trap - EXIT
