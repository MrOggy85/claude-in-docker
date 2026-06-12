# Known Attack Vectors

These are known attack vectors that are not handled by this solution.

## Update of Allowed Domains

If you run Claude in this folder, Claude can update `allowed-domains.txt` by itself. This is a very narrow threat which only applies if this folder is mounted in the container.

Note that the change does not take effect at runtime. `allowed-domains.txt` is read only at image build time (baked into `/etc/allowed-domains.txt`), and the firewall resolves it to IPs once at container start. So Claude editing the mounted file cannot widen the live firewall — it only stages a new domain that takes effect on the next `./run.sh` rebuild.

## Firewall Boundary Disclosure via Fast-Fail

The firewall REJECTs non-whitelisted outbound connections (TCP RST / ICMP unreachable) rather than silently dropping them, so a blocked connection fails immediately with `ECONNREFUSED` instead of hanging until timeout. This is a deliberate DX tradeoff: it also lets any in-container process map the firewall boundary by probing — attempting connections and observing refused-vs-accepted — quickly and without timeouts.

This does not let a process *reach* a blocked destination; it only reveals which destinations are allowed. The whitelist is not secret (it is committed in `allowed-domains.txt`), so the disclosure is low impact. It is noted here because the prior silent-drop behavior made such probing slow and impractical, and the fast-fail change removes that friction.
