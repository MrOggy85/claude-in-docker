# Known Attack Vectors

These are known attack vectors that are not handled by this solution.

## Update of Allowed Domains

If you run Claude in this folder, Claude can update `allowed-domains.txt` by itself. This is a very narrow threat which only applies if this folder is mounted in the container.

Note that the change does not take effect at runtime. `allowed-domains.txt` is read only at image build time (baked into `/etc/allowed-domains.txt`), and the firewall resolves it to IPs once at container start. So Claude editing the mounted file cannot widen the live firewall — it only stages a new domain that takes effect on the next `./run.sh` rebuild.
