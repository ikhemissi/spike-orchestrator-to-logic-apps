#!/usr/bin/env bash
# Configures the partner FTP and SFTP accounts on an Ubuntu VM.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

: "${PASV_ADDRESS:?Set PASV_ADDRESS to the FTP server IPv4 address.}"
: "${PARTNER_A_PASSWORD:?Set PARTNER_A_PASSWORD to the FTP account password.}"
: "${PARTNER_B_PUBLIC_KEY:?Set PARTNER_B_PUBLIC_KEY to the SFTP account SSH public key.}"

ENABLE_FTPS="${ENABLE_FTPS:-false}"
SSH_PORT="${SSH_PORT:-22}"
FTP_PORT="${FTP_PORT:-21}"

if [[ ! "${PASV_ADDRESS}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "PASV_ADDRESS must be an IPv4 address." >&2
  exit 1
fi
if [[ "${PARTNER_A_PASSWORD}" == *$'\n'* || "${PARTNER_A_PASSWORD}" == *$'\r'* ]]; then
  echo "PARTNER_A_PASSWORD must be a single line." >&2
  exit 1
fi
if [[ "${PARTNER_B_PUBLIC_KEY}" == *$'\n'* ]]; then
  echo "PARTNER_B_PUBLIC_KEY must contain one public key line." >&2
  exit 1
fi
require_port() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "${name} must be between 1 and 65535." >&2
    exit 1
  fi
}
require_port SSH_PORT "${SSH_PORT}"
require_port FTP_PORT "${FTP_PORT}"
if [[ "${ENABLE_FTPS}" != "true" && "${ENABLE_FTPS}" != "false" ]]; then
  echo "ENABLE_FTPS must be true or false." >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssl vsftpd

temporary_key="$(mktemp)"
trap 'rm -f "$temporary_key"' EXIT
printf '%s\n' "${PARTNER_B_PUBLIC_KEY}" >"${temporary_key}"
if ! ssh-keygen -l -f "${temporary_key}" >/dev/null 2>&1; then
  echo "PARTNER_B_PUBLIC_KEY is not a valid SSH public key." >&2
  exit 1
fi

if ! id partner-a >/dev/null 2>&1; then
  useradd --no-create-home --home-dir /srv/ftp/partner-a --shell /usr/sbin/nologin partner-a
fi
usermod --home /srv/ftp/partner-a --shell /usr/sbin/nologin partner-a
printf 'partner-a:%s\n' "${PARTNER_A_PASSWORD}" | chpasswd
if ! grep -Fxq /usr/sbin/nologin /etc/shells; then
  printf '%s\n' /usr/sbin/nologin >>/etc/shells
fi

ftp_root=/srv/ftp/partner-a
install -d -o root -g root -m 0755 "${ftp_root}"
for folder in j1 j2 j4 archive; do
  install -d -o partner-a -g partner-a -m 0750 "${ftp_root}/outbound/${folder}"
done

if ! id partner-b >/dev/null 2>&1; then
  useradd --no-create-home --home-dir /inbound --shell /usr/sbin/nologin partner-b
fi
usermod --home /inbound --shell /usr/sbin/nologin partner-b
passwd --lock partner-b >/dev/null

sftp_root=/srv/sftp/partner-b
install -d -o root -g root -m 0755 "${sftp_root}"
install -d -o partner-b -g partner-b -m 0750 "${sftp_root}/inbound"
install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
install -o root -g root -m 0644 "${temporary_key}" /etc/ssh/authorized_keys/partner-b

cat >/etc/ssh/sshd_config.d/05-partner-b-port.conf <<EOF
Port ${SSH_PORT}
EOF
cat >/etc/ssh/sshd_config.d/60-partner-b.conf <<'EOF'
Match User partner-b
    AuthenticationMethods publickey
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    ChrootDirectory /srv/sftp/%u
    ForceCommand internal-sftp
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
Match all
EOF

install -d -o root -g root -m 0755 /run/sshd
sshd -t

vsftpd_config=/etc/vsftpd.conf
cat >"${vsftpd_config}" <<EOF
listen=YES
listen_ipv6=NO
listen_port=${FTP_PORT}
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=\$USER
local_root=/srv/ftp/\$USER
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pasv_address=${PASV_ADDRESS}
EOF

if [[ "${ENABLE_FTPS}" == "true" ]]; then
  if [[ ! -s /etc/ssl/private/vsftpd.pem || ! -s /etc/ssl/certs/vsftpd.pem ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /etc/ssl/private/vsftpd.pem -out /etc/ssl/certs/vsftpd.pem \
      -subj "/CN=${PASV_ADDRESS}" >/dev/null 2>&1
  fi
  chmod 0600 /etc/ssl/private/vsftpd.pem
  cat >>"${vsftpd_config}" <<'EOF'
ssl_enable=YES
allow_anon_ssl=NO
force_local_logins_ssl=YES
force_local_data_ssl=YES
rsa_cert_file=/etc/ssl/certs/vsftpd.pem
rsa_private_key_file=/etc/ssl/private/vsftpd.pem
ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=NO
EOF
fi

systemctl enable --now ssh
systemctl restart ssh
systemctl is-active --quiet ssh
systemctl enable --now vsftpd
systemctl restart vsftpd
systemctl is-active --quiet vsftpd
