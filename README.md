# Why SSH works from the LAN but not through the port forward

[![ci](https://github.com/Walaskien/dual-homed-routing/actions/workflows/ci.yml/badge.svg)](https://github.com/Walaskien/dual-homed-routing/actions/workflows/ci.yml)

A host with two network interfaces replies through whichever default route has the lowest
metric — **not** through the interface the request arrived on. When those differ, the reply
leaves through a gateway that knows nothing about the connection, and the TCP handshake
never completes.

The result is a failure with a distinctive shape: the service is reachable from inside its
own subnet and silently unreachable from anywhere else. Nothing is listening on the wrong
address, and no firewall is dropping anything.

This repository explains the failure mode, shows how to confirm it in one command, and gives
a working `netplan` configuration that fixes it.

## The symptom

A dual-homed server — one interface on the network its workloads use, one on the network the
administrators reach it from:

```
ens33   192.168.5.224/24    service network,     gateway 192.168.5.2
ens36   192.168.1.224/24    management network,  gateway 192.168.1.1
```

A router forwards `203.0.113.10:47852` to `192.168.1.224:22`. From a workstation on
`192.168.1.0/24` the node answers instantly. Through the forward, the connection hangs —
not refused, not reset, just silence until the client times out.

Everything the symptom points at is innocent:

```console
$ ss -tlnp | grep :22
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*    # bound to all addresses, no ListenAddress

$ ufw status
Status: inactive                       # nothing filtering

$ iptables -t nat -L PREROUTING -n
Chain PREROUTING (policy ACCEPT)       # no NAT rules interfering
```

A packet capture is the first real clue: the SYN arrives, `sshd` answers, and the SYN-ACK is
never seen by the client. The reply is being sent — just not where anyone can use it.

## The part that surprises people

`ip route` describes where *outbound* traffic goes. It says nothing directly about where a
**reply** goes, and a reply is what is broken here.

The routing table on that node had three default routes:

```
default via 192.168.5.2 dev ens33 metric 101
default via 192.168.6.1 dev ens36 metric 1024     # from a DHCP lease nobody asked for
default via 192.168.1.1 dev ens36 metric 20100
```

Only the lowest metric is ever consulted, so every reply that is not link-local leaves via
`192.168.5.2` on `ens33` — including replies from the management address on `ens36`. The
external client's SYN lands on `ens36`, and the SYN-ACK goes out the other interface to a
gateway with no state for that flow.

**This is also why local access keeps working and hides the problem.** A reply to a client
in `192.168.1.0/24` is a link-local delivery on the directly connected subnet; it never
consults the default route at all. So the interface that is misconfigured behaves perfectly
for everyone on its own network, and fails for everyone else.

`rp_filter` is the usual suspect and deserves to be ruled out early:

```console
$ sysctl net.ipv4.conf.all.rp_filter
net.ipv4.conf.all.rp_filter = 2        # loose mode: accepts asymmetric returns
```

In strict mode (`1`) the kernel would drop the *inbound* packets instead, producing the same
silence for a completely different reason. Worth checking, quick to eliminate — and in this
case not the cause.

## Confirming it in one command

`ip route get` accepts a source address. That is how you ask the kernel the question that
actually matters: given a reply from *this* address, where would it go?

```console
# ip route get 8.8.8.8 from 192.168.1.224
8.8.8.8 from 192.168.1.224 via 192.168.5.2 dev ens33
```

The address belongs to `ens36`; the reply leaves via `ens33`. That mismatch is the bug, in
one line, with no packet capture required.

A correctly configured host names the same interface on both sides:

```console
# ip route get 8.8.8.8 from 192.168.1.224
8.8.8.8 from 192.168.1.224 via 192.168.1.1 dev ens36 table 101
```

[`check-return-path.sh`](check-return-path.sh) automates this across every address on the
host and flags the ones whose replies would leave through a foreign interface:

```console
$ sudo ./check-return-path.sh
IFACE        ADDRESS            REPLY LEAVES VIA             STATUS
ens33        192.168.5.224      ens33 via 192.168.5.2        ok
ens36        192.168.1.224      ens33 via 192.168.5.2        ASYMMETRIC

default routes:
  default via 192.168.5.2 dev ens33 proto static metric 101
  default via 192.168.1.1 dev ens36 proto static metric 20100
source routing rules:
  none — every reply follows the lowest-metric default route
rp_filter: 2 (loose) — asymmetric returns are accepted

1 address(es) would reply through a foreign interface.
```

It exits non-zero when it finds one, so it also works as a post-reboot check. After the fix
below, the same host reports both interfaces `ok` and exits `0`.

## The fix: one routing table per interface

A host with two upstreams has to route by **source**, not only by destination. Each interface
gets a private routing table plus a rule directing traffic from that interface's address into
it. `netplan` expresses this directly — the full file is in
[`examples/netplan-dual-homed.yaml`](examples/netplan-dual-homed.yaml):

```yaml
    ens36:
      dhcp4: false
      addresses: ["192.168.1.224/24"]
      routes:
        - {to: "default", via: "192.168.1.1", metric: 200}
        - {to: "default", via: "192.168.1.1", table: 101}
        - {to: "192.168.1.0/24", scope: "link", table: 101}
      routing-policy:
        - {from: "192.168.1.224", table: 101}
```

Each interface declares its default route **twice, on purpose**:

- once in the main table with a metric — this decides where traffic the node *initiates*
  goes, and the lower metric wins;
- once in a private table — this decides how *replies from that address* get out, regardless
  of what the main table prefers.

The `scope: link` entry is easy to omit and breaks the table subtly: a private table starts
empty, so without it the table knows how to reach the gateway but not the local subnet.

The equivalent with plain `iproute2`, useful for testing before committing to a config file:

```console
ip route add default via 192.168.1.1 dev ens36 table 101
ip route add 192.168.1.0/24 dev ens36 scope link src 192.168.1.224 table 101
ip rule add from 192.168.1.224 table 101 priority 100
```

On RHEL-family systems managed by NetworkManager the same thing is done with
`nmcli connection modify <conn> +ipv4.routes "0.0.0.0/0 192.168.1.1 table=101"` and
`+ipv4.routing-rules "priority 100 from 192.168.1.224 table 101"`. The mechanism is
identical; only the syntax moves.

## Doing this on a machine you can only reach remotely

Reconfiguring networking over the network it serves is how people lose access to servers.
Two properties of this particular change make it safe:

**Rules can be added live without dropping sessions.** A rule affecting traffic from
`192.168.1.224` does not disturb an SSH session established to `192.168.5.224`. Connect over
the interface you are *not* fixing, apply the rules for the other one, and verify with
`ip route get` before writing anything to disk.

**`netplan generate` validates without applying.** It renders the `systemd-networkd` units
and reports syntax errors while leaving the running configuration untouched:

```console
netplan generate && ls /run/systemd/network/
```

That turns a scheduled reboot into the test, instead of gambling on `netplan apply` over the
link being reconfigured. If the config is wrong, the machine comes back on the old one.

## The companion failure: addresses that do not survive reboot

The same node lost its static addresses on every boot and came up with an extra one from a
DHCP server on an unrelated network. Three configuration sources were competing:

| Source | What it did |
|---|---|
| `/etc/netplan/00-installer-config.yaml` | static addresses, rendered by `systemd-networkd` |
| `/etc/netplan/90-NM-*.yaml` | the same interfaces again, rendered by NetworkManager |
| `/run/systemd/network/zzzz-dracut-default.network` | `Match: Kind=!*` with `DHCP=yes` |

Both NetworkManager and `systemd-networkd` were enabled, so every boot was a race for the
same interfaces and whichever finished last won. The third file is the one that catches
people out: it ships in the initramfs, matches **every** non-virtual interface, and enables
DHCP on anything the other configs do not explicitly claim.

```console
# one netplan file, one renderer
rm /etc/netplan/90-NM-*.yaml
systemctl disable --now NetworkManager && systemctl mask NetworkManager
systemctl enable systemd-networkd

# neutralise the initramfs DHCP default
ln -sf /dev/null /etc/systemd/network/zzzz-dracut-default.network
```

Two details worth keeping:

- **`mask`, not just `disable`.** A package upgrade will happily re-enable a service that was
  only disabled.
- **`dhcp4: false` alone is not enough.** It governs the interfaces netplan manages; the
  dracut default is what claims the ones it does not. Overriding it works because
  `/etc/systemd/network` takes precedence over `/run/systemd/network` for a file of the same
  name — the standard way to suppress a unit file you do not own, without touching the
  initramfs.

## Why it is worth writing down

Both halves of this failure share a property: the evidence points somewhere other than the
cause. Asymmetric routing looks like a firewall or a port-forwarding mistake, and gets
diagnosed by staring at `sshd`. Disappearing addresses look like a broken static
configuration, when the static configuration is fine and something else is overwriting it.

Neither is exotic. Any host with a management interface and a service interface can land in
the first one, and any Ubuntu host installed with both network managers active can land in
the second.

## Verified

| Check | Result |
|---|---|
| `bash -n` and `shellcheck` on `check-return-path.sh` | no errors (one style note, SC2001, on a `sed` call) |
| Script in an Ubuntu 22.04 container with one interface | `ok`, exit code 0 |
| Script with an address the host does not have | `NO ROUTE`, exit code 1 |
| GitHub Actions (`ci`) | repeats the checks above on an Ubuntu runner |

Not verified: the netplan example on a real dual-homed host (`netplan generate` was not run), and the port-forward scenario end to end. The script cannot show a real asymmetric case on a single-interface machine.

## Limitations

- The script reports where replies would leave according to the routing tables (`ip route get ... from ...`). It does not send packets.
- IPv4 only. Interfaces such as tunnels, bridges to containers and overlays are skipped on purpose.
- Netplan and `systemd-networkd` only; other network managers need the same idea written in their own syntax.

## Related

- [single-node-k8s-platform](https://github.com/Walaskien/single-node-k8s-platform): a single-node cluster whose node has two interfaces (see `docs/dual-homed-node.md`).
- [mikrotik-site-to-site](https://github.com/Walaskien/mikrotik-site-to-site): pins tunnel endpoints to their own WAN to avoid the same asymmetry on routers.

## License

MIT — see [LICENSE](LICENSE).
