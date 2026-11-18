#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_script="${script_dir}/../setup-partner.sh"
temporary_dir="$(mktemp -d)"

if (( EUID != 0 )) &&
  { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; }; then
  echo "SKIP: partner VM integration test requires root or passwordless sudo." >&2
  rm -rf "${temporary_dir}"
  exit 0
fi

run_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo -n "$@"
  fi
}

if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=ubuntu$' /etc/os-release; then
  echo "ERROR: partner VM integration test requires Ubuntu." >&2
  rm -rf "${temporary_dir}"
  exit 1
fi

if getent passwd partner-a >/dev/null || getent passwd partner-b >/dev/null; then
  echo "ERROR: partner-a or partner-b already exists; use a clean Ubuntu runner." >&2
  rm -rf "${temporary_dir}"
  exit 1
fi

for command_name in curl ssh-keygen sftp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: required test command is missing: ${command_name}" >&2
    rm -rf "${temporary_dir}"
    exit 1
  fi
done

backup_dir="${temporary_dir}/backup"
mkdir -p "${backup_dir}"
authorized_keys_dir_was_present=false
ftp_parent_was_present=false
sftp_parent_was_present=false
sshd_runtime_dir_was_present=false
if run_root test -d /etc/ssh/authorized_keys; then
  authorized_keys_dir_was_present=true
fi
if run_root test -d /srv/ftp; then
  ftp_parent_was_present=true
fi
if run_root test -d /srv/sftp; then
  sftp_parent_was_present=true
fi
if run_root test -d /run/sshd; then
  sshd_runtime_dir_was_present=true
fi
files_to_restore=(
  /etc/vsftpd.conf
  /etc/ssh/sshd_config.d/05-partner-b-port.conf
  /etc/ssh/sshd_config.d/60-partner-b.conf
  /etc/ssl/certs/vsftpd.pem
  /etc/ssl/private/vsftpd.pem
  /etc/shells
)
existing_files=()
for file in "${files_to_restore[@]}"; do
  if run_root test -e "${file}"; then
    existing_files+=("${file}")
    run_root mkdir -p "${backup_dir}$(dirname "${file}")"
    run_root cp -a "${file}" "${backup_dir}${file}"
  fi
done

ssh_was_active=false
vsftpd_was_active=false
ssh_was_enabled=false
vsftpd_was_enabled=false
if run_root systemctl is-active --quiet ssh; then
  ssh_was_active=true
fi
if run_root systemctl is-active --quiet vsftpd; then
  vsftpd_was_active=true
fi
if run_root systemctl is-enabled --quiet ssh; then
  ssh_was_enabled=true
fi
if run_root systemctl is-enabled --quiet vsftpd; then
  vsftpd_was_enabled=true
fi

cleanup() {
  run_root systemctl stop vsftpd >/dev/null 2>&1 || true
  run_root systemctl stop ssh >/dev/null 2>&1 || true
  for username in partner-a partner-b; do
    while read -r process_id; do
      if [[ "${process_id}" =~ ^[0-9]+$ ]]; then
        run_root kill -KILL "${process_id}" >/dev/null 2>&1 || true
      fi
    done < <(run_root ps -u "${username}" -o pid=)
  done
  run_root userdel partner-a >/dev/null 2>&1 || true
  run_root userdel partner-b >/dev/null 2>&1 || true
  run_root rm -rf /srv/ftp/partner-a /srv/sftp/partner-b /etc/ssh/authorized_keys/partner-b
  if [[ "${authorized_keys_dir_was_present}" == "false" ]]; then
    run_root rmdir /etc/ssh/authorized_keys >/dev/null 2>&1 || true
  fi
  if [[ "${ftp_parent_was_present}" == "false" ]]; then
    run_root rmdir /srv/ftp >/dev/null 2>&1 || true
  fi
  if [[ "${sftp_parent_was_present}" == "false" ]]; then
    run_root rmdir /srv/sftp >/dev/null 2>&1 || true
  fi
  if [[ "${sshd_runtime_dir_was_present}" == "false" ]]; then
    run_root rmdir /run/sshd >/dev/null 2>&1 || true
  fi

  for file in "${files_to_restore[@]}"; do
    if [[ " ${existing_files[*]} " == *" ${file} "* ]]; then
      run_root cp -a "${backup_dir}${file}" "${file}"
    else
      run_root rm -f "${file}"
    fi
  done

  if [[ "${ssh_was_enabled}" == "true" ]]; then
    run_root systemctl enable ssh >/dev/null 2>&1 || true
  else
    run_root systemctl disable ssh >/dev/null 2>&1 || true
  fi
  if [[ "${vsftpd_was_enabled}" == "true" ]]; then
    run_root systemctl enable vsftpd >/dev/null 2>&1 || true
  else
    run_root systemctl disable vsftpd >/dev/null 2>&1 || true
  fi
  if [[ "${ssh_was_active}" == "true" ]]; then
    run_root systemctl restart ssh >/dev/null 2>&1 || true
  fi
  if [[ "${vsftpd_was_active}" == "true" ]]; then
    run_root systemctl restart vsftpd >/dev/null 2>&1 || true
  fi
  run_root rm -rf "${temporary_dir}"
}
trap cleanup EXIT

setup_environment_file="${temporary_dir}/setup.env"
export PASV_ADDRESS=127.0.0.1
PARTNER_A_PASSWORD="test-ftp-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export PARTNER_A_PASSWORD
ENABLE_FTPS="${ENABLE_FTPS:-false}"
export ENABLE_FTPS
export SSH_PORT=22222
ssh-keygen -q -t ed25519 -N '' -f "${temporary_dir}/partner-b"
export PARTNER_B_PUBLIC_KEY
PARTNER_B_PUBLIC_KEY="$(cat "${temporary_dir}/partner-b.pub")"
{
  printf 'PASV_ADDRESS=%q\n' "${PASV_ADDRESS}"
  printf 'PARTNER_A_PASSWORD=%q\n' "${PARTNER_A_PASSWORD}"
  printf 'PARTNER_B_PUBLIC_KEY=%q\n' "${PARTNER_B_PUBLIC_KEY}"
  printf 'ENABLE_FTPS=%q\n' "${ENABLE_FTPS}"
  printf 'SSH_PORT=%q\n' "${SSH_PORT}"
} >"${setup_environment_file}"
chmod 0600 "${setup_environment_file}"

run_setup() {
  if (( EUID == 0 )); then
    "${setup_script}"
  else
    sudo -n bash -c 'set -a; . "$1"; set +a; exec "$2"' _ \
      "${setup_environment_file}" "${setup_script}"
  fi
}

for run_number in 1 2; do
  echo "Provisioning run ${run_number}/2"
  run_setup
done

# Each run restarts vsftpd and sshd: wait for their greeting, not only for an open port, before testing them.
wait_for_greeting() {
  local port="$1" expected_prefix="$2" greeting
  for _ in $(seq 1 60); do
    greeting="$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; head -c 4 <&3" 2>/dev/null || true)"
    if [[ "${greeting}" == "${expected_prefix}"* ]]; then
      return 0
    fi
    sleep 1
  done
  echo "No ${expected_prefix} greeting on port ${port} after 60 s." >&2
  exit 1
}
wait_for_greeting "${FTP_PORT:-21}" "220"
wait_for_greeting "${SSH_PORT}" "SSH-"

ftp_source="${temporary_dir}/ftp-source.txt"
ftp_download="${temporary_dir}/ftp-download.txt"
printf 'partner-a FTP integration test\n' >"${ftp_source}"
ftp_url="ftp://127.0.0.1/outbound/j1/"
curl_test_options=(--connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused)
ftp_options=()
if [[ "${ENABLE_FTPS}" == "true" ]]; then
  # The test deliberately accepts the generated self-signed certificate on loopback.
  ftp_options=(--ssl-reqd --insecure)
fi

curl --fail --silent --show-error "${curl_test_options[@]}" --upload-file "${ftp_source}" \
  --user "partner-a:${PARTNER_A_PASSWORD}" "${ftp_options[@]}" "${ftp_url}before-rename.txt"
ftp_listing="$(curl --fail --silent --show-error "${curl_test_options[@]}" --list-only \
  --user "partner-a:${PARTNER_A_PASSWORD}" "${ftp_options[@]}" "${ftp_url}")"
grep -Fxq before-rename.txt <<<"${ftp_listing}"
curl --fail --silent --show-error "${curl_test_options[@]}" --output "${ftp_download}" \
  --user "partner-a:${PARTNER_A_PASSWORD}" "${ftp_options[@]}" "${ftp_url}before-rename.txt"
cmp "${ftp_source}" "${ftp_download}"
curl --fail --silent --show-error "${curl_test_options[@]}" --quote 'RNFR /outbound/j1/before-rename.txt' \
  --quote 'RNTO /outbound/j1/after-rename.txt' \
  --user "partner-a:${PARTNER_A_PASSWORD}" "${ftp_options[@]}" "${ftp_url}"
ftp_listing="$(curl --fail --silent --show-error "${curl_test_options[@]}" --list-only \
  --user "partner-a:${PARTNER_A_PASSWORD}" "${ftp_options[@]}" "${ftp_url}")"
grep -Fxq after-rename.txt <<<"${ftp_listing}"
if grep -Fxq before-rename.txt <<<"${ftp_listing}"; then
  echo "FTP rename left the original file in place." >&2
  exit 1
fi
echo "PASS: partner-a FTP upload, listing, download, and rename."

sftp_source="${temporary_dir}/sftp-source.txt"
printf 'partner-b SFTP integration test\n' >"${sftp_source}"
sftp_url="sftp://127.0.0.1:${SSH_PORT}/inbound/"
# The test SSH host key is ephemeral and every SFTP connection targets loopback.
sftp_host_options=(--insecure)
curl --fail --silent --show-error "${curl_test_options[@]}" --upload-file "${sftp_source}" \
  --user 'partner-b:' \
  --key "${temporary_dir}/partner-b" --pubkey "${temporary_dir}/partner-b.pub" \
  "${sftp_host_options[@]}" \
  "${sftp_url}before-rename.txt"
curl --fail --silent --show-error "${curl_test_options[@]}" \
  --quote 'rename /inbound/before-rename.txt /inbound/after-rename.txt' \
  --user 'partner-b:' \
  --key "${temporary_dir}/partner-b" --pubkey "${temporary_dir}/partner-b.pub" \
  "${sftp_host_options[@]}" "${sftp_url}"
sftp_listing="$(curl --fail --silent --show-error "${curl_test_options[@]}" --list-only \
  --user 'partner-b:' \
  --key "${temporary_dir}/partner-b" --pubkey "${temporary_dir}/partner-b.pub" \
  "${sftp_host_options[@]}" "${sftp_url}")"
grep -Fxq after-rename.txt <<<"${sftp_listing}"
if grep -Fxq before-rename.txt <<<"${sftp_listing}"; then
  echo "SFTP rename left the original file in place." >&2
  exit 1
fi
echo "PASS: partner-b SFTP upload and rename with its SSH key."

if env -u SSH_AUTH_SOCK curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
  "${sftp_host_options[@]}" --user 'partner-b:incorrect-test-password' \
  "${sftp_url}after-rename.txt" \
  -o /dev/null 2>"${temporary_dir}/password-login.log"; then
  echo "SFTP accepted password authentication for partner-b." >&2
  exit 1
fi
echo "PASS: partner-b password authentication is refused."

chroot_result="$(
  printf 'cd ..\ncd ..\npwd\n' |
    sftp -b - -P "${SSH_PORT}" -i "${temporary_dir}/partner-b" \
      -oBatchMode=yes -oStrictHostKeyChecking=no "partner-b@127.0.0.1" 2>&1
)"
if ! grep -Fxq 'Remote working directory: /' <<<"${chroot_result}"; then
  printf 'SFTP chroot check failed:\n%s\n' "${chroot_result}" >&2
  exit 1
fi
echo "PASS: partner-b cannot navigate above its SFTP chroot."
echo "All partner VM integration checks passed."
