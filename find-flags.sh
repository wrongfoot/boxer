#!/usr/bin/env bash
#
# find-flags.sh — locate HackTheBox flag files (user.txt / root.txt) on a Linux
# target. Delivered to and run ON the box after you get a shell.
#
# Authorized testing only (HTB lab boxes / systems you own).
#
# Usage on the target:
#   ./find-flags.sh            # search the whole filesystem
#   ./find-flags.sh /home /root /opt   # search only the given directories
#
set -u

FLAG_NAMES=(user.txt root.txt proof.txt)   # HTB uses user.txt/root.txt; proof.txt on some labs

# Search roots: use args if given, else the likely spots first, then everything.
if [[ $# -gt 0 ]]; then
  ROOTS=("$@")
else
  ROOTS=(/home /root /Users /var /opt /srv /tmp /)
fi

printf '[*] find-flags: searching for %s\n' "${FLAG_NAMES[*]}"

# Build the -name expression: \( -name user.txt -o -name root.txt ... \)
name_expr=()
for i in "${!FLAG_NAMES[@]}"; do
  [[ $i -eq 0 ]] && name_expr+=(-name "${FLAG_NAMES[$i]}") || name_expr+=(-o -name "${FLAG_NAMES[$i]}")
done

# De-duplicate results (searching / after /home would repeat hits).
seen=""
found=0
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  # -xdev keeps it on one filesystem (skips /proc, mounts) and stays fast.
  while IFS= read -r f; do
    case "$seen" in *"|$f|"*) continue ;; esac
    seen="${seen}|$f|"
    found=$((found+1))
    printf '\n[+] %s\n' "$f"
    if content="$(cat "$f" 2>/dev/null)"; then
      printf '    %s\n' "$content"
    else
      printf '    <found but not readable as current user — check permissions/privesc>\n'
    fi
  done < <(find "$root" -xdev -type f \( "${name_expr[@]}" \) 2>/dev/null)
done

echo
if [[ $found -eq 0 ]]; then
  echo "[-] No flag files found in the searched paths."
else
  echo "[*] Done — $found flag file(s) found."
fi
