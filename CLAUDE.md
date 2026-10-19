# Project rules

## Never trade security for convenience without asking

This deployment holds the owner's personal credentials. When a fix or change
would weaken any security control, **stop and clear it with the user first**.
Explain what gets weaker, what an attacker would gain, and the alternatives.
This applies even when the weaker option is the quickest way to make
something work.

Controls this covers include SELinux labels and MCS separation, file
permissions, firewall and nftables rules, IAM grants, secret handling, TLS,
WAF and fail2ban settings, container isolation, and authentication.

The default is to make the more secure solution work for this project. Only
put a weaker option in front of the user when the secure one is genuinely
unworkable, and say why.

Example: rootless Podman's `:Z` failed on the data disk's root-only
`lost+found`. The quick fix, a shared `s0` label on `/data`, would have let
any container (including the internet-facing Caddy) reach the vault's files.
The right fix keeps them private: fixed, distinct MCS levels per container,
with `/data` labelled at Vaultwarden's level.
