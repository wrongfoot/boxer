<#
  find-flags.ps1 — locate HackTheBox flag files (user.txt / root.txt) on a
  Windows target. Delivered to and run ON the box after you get a shell.

  Authorized testing only (HTB lab boxes / systems you own).

  Usage on the target (PowerShell):
    powershell -ep bypass -f find-flags.ps1
    powershell -ep bypass -f find-flags.ps1 -Roots C:\Users,C:\inetpub
#>
param(
  [string[]]$Roots = @('C:\Users','C:\')
)

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
                try {
                    $c = Get-Content -LiteralPath $_.FullName -ErrorAction Stop
                    $c | ForEach-Object { Write-Host "    $_" }
                } catch {
                    Write-Host "    <found but not readable as current user - check permissions/privesc>"
                }
            }
        }
}

Write-Host ""
if ($found -eq 0) {
    Write-Host "[-] No flag files found in the searched paths."
} else {
    Write-Host "[*] Done - $found flag file(s) found."
}
