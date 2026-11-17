@echo off
title Netpack Warranty Sync Server
set "NWS_BAT=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:NWS_BAT); $i=$s.IndexOf('#'+'#PS-CODE##'); Invoke-Expression $s.Substring($i)"
if errorlevel 1 pause
exit /b
##PS-CODE##
# ---------------------------------------------------------------------------
# Netpack Sync Server (embedded). Runs on the Master PC. No install needed:
# uses Windows PowerShell 5.1 which is part of Windows 10.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$utf8   = New-Object System.Text.UTF8Encoding($false)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$dir      = Split-Path -Parent $env:NWS_BAT
$htmlFile = Join-Path $dir 'Netpack_Warranty_System.html'
$cfgFile  = Join-Path $dir 'Netpack_Sync_Config.txt'
$dataFile = Join-Path $dir 'Netpack_Sync_Data.jsonl'

function Log([string]$m) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Fail([string]$m) {
  Write-Host ''
  Write-Host ('ERROR: ' + $m) -ForegroundColor Red
  Write-Host ''
  Read-Host 'Press ENTER to close'
  exit 1
}

Write-Host ''
Write-Host '  ================================================='
Write-Host '    NETPACK WARRANTY SYNC SERVER'
Write-Host '  ================================================='
Write-Host ''

# ---- settings (port + shared key) -----------------------------------------
$port = 8765
$key  = ''
if (Test-Path -LiteralPath $cfgFile) {
  foreach ($ln in [IO.File]::ReadAllLines($cfgFile)) {
    if ($ln -match '^\s*port\s*=\s*(\d+)\s*$') { $port = [int]$Matches[1] }
    elseif ($ln -match '^\s*key\s*=(.*)$') { $key = $Matches[1].Trim() }
  }
}
$change = $false
if ($key -eq '') {
  $change = $true
} else {
  Write-Host ('  Saved settings found: port ' + $port + ', shared key is set.')
  $a = Read-Host '  Press ENTER to keep them, or type C to change'
  if ($a -match '^[cC]') { $change = $true }
}
if ($change) {
  $p = Read-Host ('  Port number (press ENTER for ' + $port + ')')
  if ($p -match '^\d+$') {
    if ([int]$p -ge 1024 -and [int]$p -le 65535) { $port = [int]$p }
  }
  $key = ''
  while ($key.Length -lt 4) {
    $key = (Read-Host '  Create a Shared Sync Key (secret, at least 4 characters)').Trim()
  }
  [IO.File]::WriteAllLines($cfgFile, @(('port=' + $port), ('key=' + $key)), $utf8)
  Write-Host '  Settings saved.'
}

# ---- persistent data file --------------------------------------------------
$lines = New-Object 'System.Collections.Generic.List[string]'
$ids   = New-Object 'System.Collections.Generic.HashSet[string]'
$epoch = ''
try {
  if (Test-Path -LiteralPath $dataFile) {
    Copy-Item -LiteralPath $dataFile -Destination ($dataFile + '.bak') -Force
    $first = $true
    foreach ($ln in [IO.File]::ReadAllLines($dataFile, $utf8)) {
      if ($first) {
        $first = $false
        if ($ln.StartsWith('#EPOCH')) { $epoch = $ln.Substring(7).Trim(); continue }
      }
      if ($ln.Length -eq 0) { continue }
      $t = $ln.IndexOf("`t")
      if ($t -lt 1) { continue }
      [void]$lines.Add($ln)
      [void]$ids.Add($ln.Substring(0, $t))
    }
  }
  if ($epoch -eq '') {
    $epoch = [guid]::NewGuid().ToString('N')
    $all = New-Object 'System.Collections.Generic.List[string]'
    [void]$all.Add("#EPOCH`t" + $epoch)
    $all.AddRange($lines)
    [IO.File]::WriteAllLines($dataFile, $all, $utf8)
  }
} catch {
  Fail ('Cannot read or write the data file. Is the folder read-only? ' + $_.Exception.Message)
}

# ---- HTTP helpers ------------------------------------------------------------
function Send-Resp($stream, [int]$code, [string]$reason, [byte[]]$body, [string]$ctype, [string]$extra) {
  $len = 0
  if ($null -ne $body) { $len = $body.Length }
  $head = 'HTTP/1.1 ' + $code + ' ' + $reason + "`r`n" +
          'Content-Type: ' + $ctype + "`r`n" +
          'Content-Length: ' + $len + "`r`n" +
          "Connection: close`r`n" +
          "Access-Control-Allow-Origin: *`r`n" +
          "Access-Control-Allow-Headers: X-Sync-Key, Content-Type`r`n" +
          "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
          "Access-Control-Allow-Private-Network: true`r`n" +
          "Access-Control-Expose-Headers: X-Seq, X-Total, X-Time, X-Epoch`r`n" +
          "Cache-Control: no-store`r`n" + $extra + "`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($len -gt 0) { $stream.Write($body, 0, $len) }
  $stream.Flush()
}

function Read-Req($stream) {
  $buf = New-Object byte[] 65536
  $ms  = New-Object System.IO.MemoryStream
  $hdrEnd = -1
  $txt = ''
  while ($hdrEnd -lt 0) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { return $null }
    $ms.Write($buf, 0, $n)
    $txt = $latin1.GetString($ms.ToArray())
    $hdrEnd = $txt.IndexOf("`r`n`r`n")
    if (($hdrEnd -lt 0) -and ($ms.Length -gt 131072)) { return $null }
  }
  $hl = $txt.Substring(0, $hdrEnd) -split "`r`n"
  $rl = $hl[0] -split ' '
  if ($rl.Length -lt 2) { return $null }
  $req = @{ method = $rl[0]; path = $rl[1]; headers = @{}; body = $null }
  for ($i = 1; $i -lt $hl.Length; $i++) {
    $c = $hl[$i].IndexOf(':')
    if ($c -gt 0) { $req.headers[$hl[$i].Substring(0, $c).Trim().ToLower()] = $hl[$i].Substring($c + 1).Trim() }
  }
  $cl = 0
  if ($req.headers.ContainsKey('content-length')) { $cl = [int]$req.headers['content-length'] }
  if ($cl -gt 33554432) { return $null }
  if ($cl -gt 0) {
    $bodyStart = $hdrEnd + 4
    while (($ms.Length - $bodyStart) -lt $cl) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { return $null }
      $ms.Write($buf, 0, $n)
    }
    $all = $ms.ToArray()
    $b = New-Object byte[] $cl
    [Array]::Copy($all, $bodyStart, $b, 0, $cl)
    $req.body = $b
  }
  return $req
}

function Handle($stream, [string]$remote) {
  $req = Read-Req $stream
  if ($null -eq $req) { return }
  $m = $req.method
  $p = $req.path
  $q = ''
  $qi = $p.IndexOf('?')
  if ($qi -ge 0) { $q = $p.Substring($qi + 1); $p = $p.Substring(0, $qi) }
  $empty = $null

  if ($m -eq 'OPTIONS') { Send-Resp $stream 204 'No Content' $empty 'text/plain' ''; return }

  if ($m -eq 'GET' -and ($p -eq '/' -or $p -eq '/index.html' -or $p -ieq '/Netpack_Warranty_System.html')) {
    if (Test-Path -LiteralPath $htmlFile) {
      $b = [IO.File]::ReadAllBytes($htmlFile)
      Send-Resp $stream 200 'OK' $b 'text/html; charset=utf-8' ''
    } else {
      Send-Resp $stream 404 'Not Found' ($utf8.GetBytes('Netpack_Warranty_System.html was not found next to the server file.')) 'text/plain' ''
    }
    return
  }

  if ($p -eq '/api/sync' -or $p -eq '/api/ping') {
    $k = ''
    if ($req.headers.ContainsKey('x-sync-key')) {
      try { $k = [Uri]::UnescapeDataString($req.headers['x-sync-key']) } catch { $k = '' }
    }
    if ($k -cne $key) {
      Log ($remote + ' REJECTED: wrong Shared Sync Key')
      Send-Resp $stream 401 'Unauthorized' ($utf8.GetBytes('wrong key')) 'text/plain' ''
      return
    }
    $since = 0
    if ($q -match 'since=(\d+)') { $since = [int]$Matches[1] }

    $added = 0
    if ($m -eq 'POST' -and ($null -ne $req.body) -and ($req.body.Length -gt 0)) {
      $text  = $utf8.GetString($req.body)
      $new   = New-Object 'System.Collections.Generic.List[string]'
      $batch = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($raw in ($text -split "`n")) {
        $ln = $raw.TrimEnd("`r")
        if ($ln.Length -lt 3) { continue }
        $t = $ln.IndexOf("`t")
        if ($t -lt 1 -or $t -gt 80) { continue }
        $oid = $ln.Substring(0, $t)
        if ($ids.Contains($oid)) { continue }
        if ($batch.Add($oid)) { [void]$new.Add($ln) }
      }
      if ($new.Count -gt 0) {
        [IO.File]::AppendAllText($dataFile, (($new -join "`n") + "`n"), $utf8)
        foreach ($ln in $new) { [void]$ids.Add($ln.Substring(0, $ln.IndexOf("`t"))); [void]$lines.Add($ln) }
        $added = $new.Count
      }
    }

    $total = $lines.Count
    if ($since -gt $total) { $since = $total }
    $cnt = [Math]::Min(1500, $total - $since)
    $out = ''
    if ($cnt -gt 0) { $out = [string]::Join("`n", $lines.GetRange($since, $cnt).ToArray()) }
    $seq = $since + $cnt
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $ex  = 'X-Seq: ' + $seq + "`r`n" + 'X-Total: ' + $total + "`r`n" + 'X-Epoch: ' + $epoch + "`r`n" + 'X-Time: ' + $now + "`r`n"
    Send-Resp $stream 200 'OK' ($utf8.GetBytes($out)) 'text/plain; charset=utf-8' $ex
    if ($added -gt 0) { Log ($remote + ' sent ' + $added + ' change(s). Total stored: ' + $total) }
    return
  }

  Send-Resp $stream 404 'Not Found' $empty 'text/plain' ''
}

# ---- start listening ---------------------------------------------------------
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
try { $listener.Start() } catch {
  Fail ('Port ' + $port + ' cannot be used (another copy of this server may already be running). ' + $_.Exception.Message)
}

$isAdmin = $false
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }
$fwNote = ''
if ($isAdmin) {
  try {
    Start-Process -FilePath 'netsh' -ArgumentList 'advfirewall firewall delete rule name="Netpack Sync Server"' -Wait -WindowStyle Hidden
    Start-Process -FilePath 'netsh' -ArgumentList ('advfirewall firewall add rule name="Netpack Sync Server" dir=in action=allow protocol=TCP localport=' + $port + ' profile=any remoteip=LocalSubnet') -Wait -WindowStyle Hidden
    $fwNote = 'Windows Firewall: rule added for the local network.'
  } catch { $fwNote = 'Could not add the firewall rule automatically.' }
} else {
  $fwNote = 'If Windows asks to allow access, tick Private AND Public and click Allow. If the other PC still cannot connect, right-click this file once and choose Run as administrator.'
}

$ips = @()
try {
  $ips = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') -and -not $_.ToString().StartsWith('169.254.') } |
    ForEach-Object { $_.ToString() })
} catch { $ips = @() }

Write-Host ''
Write-Host '  SERVER IS RUNNING - keep this window open while people use the system.' -ForegroundColor Green
Write-Host ('  Port             : ' + $port)
if ($ips.Count -eq 0) {
  Write-Host '  This PC IP       : (none found - check the network cable / Wi-Fi)'
} else {
  foreach ($ip in $ips) {
    Write-Host ('  This PC IP       : ' + $ip)
    Write-Host ('  Open on 2nd PC   : http://' + $ip + ':' + $port + '/')
  }
}
Write-Host ('  Data file        : ' + $dataFile)
Write-Host ('  ' + $fwNote)
Write-Host ''
Write-Host '  In the Warranty System: Sync Settings > Master, enter this PC IP, the port and your key.'
Write-Host '  Close this window to stop the server (data is already saved on disk).'
Write-Host ''

if (Test-Path -LiteralPath $htmlFile) {
  try { Start-Process -FilePath $htmlFile } catch { Write-Host '  Could not open the browser automatically. Open Netpack_Warranty_System.html manually.' }
} else {
  Write-Host '  WARNING: Netpack_Warranty_System.html was not found in this folder.' -ForegroundColor Yellow
}

# ---- main loop ---------------------------------------------------------------
while ($true) {
  if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue }
  $c = $listener.AcceptTcpClient()
  try {
    $c.ReceiveTimeout = 2500
    $c.SendTimeout = 5000
    $s = $c.GetStream()
    $r = ([System.Net.IPEndPoint]$c.Client.RemoteEndPoint).Address.ToString()
    Handle $s $r
  } catch {
    Log ('request problem: ' + $_.Exception.Message)
    try { Send-Resp $s 500 'Server Error' $null 'text/plain' '' } catch { }
  } finally {
    $c.Close()
  }
}
