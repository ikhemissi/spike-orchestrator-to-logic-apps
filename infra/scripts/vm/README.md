# Partner VM

`setup-partner.sh` configures the Ubuntu partner VM with a chrooted FTP account
for partner A and an SFTP-only, key-authenticated chroot account for partner B.
Run it as root with `PASV_ADDRESS`, `PARTNER_A_PASSWORD`, and
`PARTNER_B_PUBLIC_KEY` set in the environment. `ENABLE_FTPS=true` enables
FTPS with a generated self-signed certificate; it defaults to `false`.
`SSH_PORT` optionally overrides the SSH listener port and defaults to `22`.

Run `tests/test-setup-partner.sh` on a clean Ubuntu runner with passwordless
sudo to exercise plain FTP and SFTP and run the provisioning script twice. Set
`ENABLE_FTPS=true` to run the same FTP checks over FTPS with the generated
self-signed certificate. The test prints a clear skip message when root access
is unavailable.
