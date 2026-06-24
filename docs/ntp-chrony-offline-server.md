# Offline Chrony NTP Server — Ubuntu 22.04

Setup guide for a **100% offline** NTP server using `chrony`. The server has **no internet**, so it cannot reach `pool.ntp.org`. Instead it serves **its own local hardware clock** as the authoritative time source to all LAN clients (sensors, gateways).

> **What "offline server" means here**
> - No upstream NTP sources — the server *is* the time reference.
> - All devices on the LAN sync to this one box, so the whole fleet is **mutually consistent** even though no one knows the "true" world time.
> - If absolute correctness matters later, you can attach a GPS/RTC module (see [Appendix B](#appendix-b--optional-real-accuracy-without-internet)).

---

## Topology

```
   ┌────────────────────────────┐
   │      OFFLINE SERVER        │   chrony = NTP SERVER
   │  serves its OWN local clock│   e.g. 192.168.1.1
   │     (no internet)          │   local stratum 10
   └─────────────┬──────────────┘
                 │ LAN (no internet)
        ┌────────┼────────┬────────┐
        ▼        ▼        ▼        ▼
     sensor   sensor   sensor   gateway   → all sync FROM the server
```

---

## Step 0 — Prerequisites & info to collect

Run these on the server and note the values; you'll need them below.

```bash
# Ubuntu version (should be 22.04)
lsb_release -a

# CPU architecture — you need matching .deb packages (almost always amd64 or arm64)
dpkg --print-architecture

# The server's IP and subnet (note the address + CIDR, e.g. 192.168.1.1/24)
ip -brief address
```

Decide and write down:

| Item | Example | Yours |
|------|---------|-------|
| Server IP | `192.168.1.1` | |
| LAN subnet (CIDR) | `192.168.1.0/24` | |
| Architecture | `amd64` | |

---

## Step 1 — Install chrony OFFLINE (the air-gap part)

Because the server has no internet, `apt install chrony` will fail (it can't reach the Ubuntu mirrors). You must bring the `.deb` package(s) in manually.

### Step 1a — Check if it's already installed

```bash
dpkg -l | grep chrony
```

If you see `ii  chrony ...`, skip to [Step 2](#step-2--configure-chrony-as-an-offline-server). Otherwise continue.

### Step 1b — Download the .deb on a machine WITH internet

On **another Ubuntu 22.04 machine that has internet** (same architecture as the server — e.g. both `amd64`), download chrony **and its dependencies** without installing:

```bash
mkdir -p ~/chrony-offline && cd ~/chrony-offline

# Downloads chrony + every dependency .deb into the current folder
sudo apt-get update
sudo apt-get install --download-only --reinstall -o Dir::Cache::archives="$(pwd)" chrony
# If the above leaves files in /var/cache/apt instead, copy them:
cp /var/cache/apt/archives/*.deb ~/chrony-offline/ 2>/dev/null || true
```

> **More reliable method** — if you have Docker or a clean 22.04 box, `apt-get install --download-only chrony` inside a fresh `ubuntu:22.04` container guarantees you capture *all* dependencies (libc, timedatectl helpers, etc.) that the server might be missing.

You should end up with files like:

```
chrony_4.2-2ubuntu0.2_amd64.deb
libnss3_...deb           # (possible dependency)
... (any other deps)
```

### Step 1c — Transfer to the offline server

Use USB drive, SCP over the LAN, or any sneakernet method:

```bash
# Example over LAN (if you can reach the server):
scp ~/chrony-offline/*.deb user@192.168.1.1:~/chrony-offline/
```

### Step 1d — Install from local .deb files on the server

```bash
cd ~/chrony-offline

# Install chrony + all dependencies in one shot; resolves local deps automatically
sudo apt-get install --no-download --fix-broken ./*.deb

# --- Fallback if apt complains ---
# sudo dpkg -i *.deb           # install everything
# sudo dpkg -i chrony_*.deb    # then just chrony if deps already satisfied
```

Verify it installed:

```bash
chronyd --version
dpkg -l | grep chrony      # expect: ii  chrony  4.x
```

---

## Step 2 — Configure chrony as an OFFLINE server

Back up the default config, then replace it.

```bash
sudo cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
sudo nano /etc/chrony/chrony.conf
```

Replace the contents with this **offline server** config (adjust the subnet to yours):

```conf
####################################################################
#  OFFLINE NTP SERVER — serves its own local clock, NO internet    #
####################################################################

# --- NO upstream sources ---
# Do NOT add any "pool" or "server" lines. There is no internet,
# so this machine is the root time reference for the LAN.

# --- Serve the local clock as the time source ---
# stratum 10 = "I am a standalone reference clock". Chrony will hand
# out THIS machine's system time to clients. Higher number = lower
# authority, so a real GPS source (if added later) would override it.
local stratum 10

# --- Allow LAN clients (sensors / gateway) to query this server ---
# THIS is what makes chrony serve time. Without it, clients get denied.
allow 192.168.1.0/24            # <-- change to YOUR subnet

# --- Drift / step settings ---
driftfile /var/lib/chrony/chrony.drift

# Step the clock (instead of slewing slowly) on the first 3 updates
# if it's off by more than 1 second. Good for boot-time correction.
makestep 1.0 3

# Sync the hardware RTC from system time, so the time survives reboots
rtcsync

# --- Logging (optional but handy for an unattended box) ---
logdir /var/log/chrony
log tracking measurements statistics
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

> **Why `local stratum 10`?**
> Normally a server's stratum is derived from its upstream source. With no upstream, chrony would refuse to advertise itself as synchronized and clients would reject it. The `local` directive tells chrony: "consider yourself synced and serve your own clock." Stratum 10 leaves room (1–9) for a more authoritative source you might add later.

---

## Step 3 — Set the server's clock correctly (one-time)

Since there's no internet to correct it, **set the local clock accurately by hand once.** All clients will inherit whatever this box says, so getting it right matters.

```bash
# Set the timezone (example: Vietnam)
sudo timedatectl set-timezone Asia/Ho_Chi_Minh

# Disable systemd's own network time sync (we use chrony, and there's no net anyway)
sudo timedatectl set-ntp false

# Set the date/time manually (format: 'YYYY-MM-DD HH:MM:SS')
sudo timedatectl set-time '2026-06-24 14:30:00'

# Write system time into the hardware RTC so it survives power loss
sudo hwclock --systohc

# Confirm
timedatectl
```

> If the machine has a working RTC battery, it will keep reasonable time across reboots. For long deployments without internet, see [Appendix B](#appendix-b--optional-real-accuracy-without-internet) about adding a GPS or high-precision RTC.

---

## Step 4 — Start and enable chrony

```bash
sudo systemctl restart chrony
sudo systemctl enable chrony
sudo systemctl status chrony      # should be: active (running)
```

---

## Step 5 — Open the firewall (NTP = UDP 123)

If `ufw` is active:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 123 proto udp
sudo ufw reload
sudo ufw status
```

If you don't use a firewall, skip this — but confirm nothing else blocks UDP 123.

---

## Step 6 — Verify the server is serving its own clock

```bash
# Should show 'Reference ID : 7F7F0101 (local)' and your stratum (10)
chronyc tracking
```

Expected (key lines):

```
Reference ID    : 7F7F0101 (local)
Stratum         : 10
Ref time (UTC)  : ...
System time     : 0.000000001 seconds fast of NTP time
Leap status     : Normal
```

```bash
# Sources — for a pure offline server this may be empty, that's OK.
chronyc sources -v

# Confirm chrony is listening on UDP 123
sudo ss -ulnp | grep 123
```

`Leap status : Normal` + `Stratum : 10` = the server is ready to serve. ✅

---

## Step 7 — Point a client at this server (quick test)

On any LAN client running chrony, set in its `/etc/chrony/chrony.conf`:

```conf
server 192.168.1.1 iburst prefer
```

then `sudo systemctl restart chrony` and check:

```bash
chronyc sources -v        # want '^*' next to 192.168.1.1 = synced to our server
chronyc tracking
```

On the **server**, confirm clients are pulling time:

```bash
chronyc clients           # lists every device currently querying this server
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `apt install ./*.deb` fails: unmet dependencies | Missing dependency `.deb`s | Re-download with `--download-only` on a *fresh* 22.04 box/container to capture all deps |
| Client shows `?` or no `*` next to server | `allow` line missing/wrong subnet | Check `allow <subnet>` in server conf matches the client's network |
| `chronyc tracking` shows `Reference ID : 00000000` | `local stratum` line missing | Add `local stratum 10`, restart chrony |
| Client rejects server time | Server not advertising as synced | Ensure `local stratum 10` is set and `chronyc tracking` shows Stratum 10 |
| Connection refused / timeout from client | Firewall blocking UDP 123 | Open port 123/udp (Step 5); check `ss -ulnp \| grep 123` on server |
| Time wrong on all clients | Server clock was set wrong | Re-set server clock (Step 3); clients follow it |

---

## Appendix A — Quick reference card

```bash
# ---- SERVER (offline, serves local clock) ----
# /etc/chrony/chrony.conf essentials:
#   local stratum 10
#   allow 192.168.1.0/24
#   (NO pool/server lines)

sudo systemctl restart chrony      # apply config
chronyc tracking                   # verify: Stratum 10, ID (local)
chronyc clients                    # see who's syncing from us
sudo ss -ulnp | grep 123           # confirm listening

# ---- CLIENT ----
# /etc/chrony/chrony.conf:
#   server 192.168.1.1 iburst prefer
chronyc sources -v                 # verify: ^* next to server IP
```

---

## Appendix B — Optional: real accuracy without internet

A pure local-clock server keeps everyone *consistent* but slowly drifts away from real-world time. If you later need true accuracy offline, add a reference clock to the server — chrony supports them natively:

- **GPS module (PPS)** — most accurate; `refclock PPS /dev/pps0` + `refclock SHM 0` with `gpsd`. Sub-millisecond.
- **DS3231 RTC** — cheap high-precision real-time clock module; far less drift than the motherboard RTC.

With a reference clock present, give it a **lower** stratum (e.g. `refclock ... stratum 1`) so it outranks the `local stratum 10` fallback, and keep `local` as the backup for when the GPS has no fix.

---

**Summary:** Install chrony from transferred `.deb` files → set `local stratum 10` + `allow <subnet>` (no pool lines) → set the clock by hand once → open UDP 123 → verify with `chronyc tracking`/`clients`. The server now serves its own time to the whole LAN, fully offline.
