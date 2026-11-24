# router-check.ps1 - home network / router slowdown diagnostics for Windows.
#
# Usage (in PowerShell, from this folder):
#   powershell -ExecutionPolicy Bypass -File .\router-check.ps1
# Output: printed to the screen and saved to router-report-<date>.txt
#
# Read-only: it changes no settings. It only pings, looks up DNS names, and
# downloads/uploads test data to speed.cloudflare.com (about 150 MB in total).
# MAC addresses are shortened to the manufacturer part, and Wi-Fi network
# names are not recorded.

$ProgressPreference = 'SilentlyContinue'
$Out = "router-report-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
Start-Transcript -Path $Out | Out-Null

function Section($t) { Write-Output "`n==================== $t ====================" }

function Ping-Stats($target, $count) {
  $p = New-Object System.Net.NetworkInformation.Ping
  $times = @(); $lost = 0
  for ($i = 0; $i -lt $count; $i++) {
    try { $r = $p.Send($target, 2000) } catch { $r = $null }
    if ($r -and $r.Status -eq 'Success') { $times += $r.RoundtripTime } else { $lost++ }
    Start-Sleep -Milliseconds 200
  }
  if ($times.Count) {
    $m = $times | Measure-Object -Average -Minimum -Maximum
    [pscustomobject]@{ Avg = [math]::Round($m.Average,1); Min = $m.Minimum; Max = $m.Maximum
                       Loss = [math]::Round(100*$lost/$count,1) }
  } else { [pscustomobject]@{ Avg = $null; Min = $null; Max = $null; Loss = 100 } }
}
function Show-Ping($target, $count) {
  $s = Ping-Stats $target $count
  Write-Output ("  {0,-15} avg {1} ms  min {2}  max {3}  loss {4}%" -f $target,$s.Avg,$s.Min,$s.Max,$s.Loss)
}

Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(30)

function Test-Download($bytes) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $data = $http.GetByteArrayAsync("https://speed.cloudflare.com/__down?bytes=$bytes").Result
        $sw.Stop(); [math]::Round($data.Length*8/$sw.Elapsed.TotalSeconds/1e6,1) } catch { "FAILED" }
}
function Test-Upload($bytes) {
  $body = New-Object System.Net.Http.ByteArrayContent (,(New-Object byte[] $bytes))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $null = $http.PostAsync("https://speed.cloudflare.com/__up", $body).Result
        $sw.Stop(); [math]::Round($bytes*8/$sw.Elapsed.TotalSeconds/1e6,1) } catch { "FAILED" }
}

Section "SYSTEM"
Write-Output "Date: $(Get-Date)"
Write-Output "OS:   $([Environment]::OSVersion.VersionString)"

Section "CONNECTION"
$route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue |
         Sort-Object RouteMetric | Select-Object -First 1
$GW = $route.NextHop
$adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
$isWifi = $adapter.PhysicalMediaType -match '802\.11' -or $adapter.InterfaceDescription -match 'Wi-?Fi|Wireless'
Write-Output "Router (gateway): $GW"
Write-Output "Adapter:          $($adapter.Name) - $($adapter.InterfaceDescription)"
Write-Output "Link speed:       $($adapter.LinkSpeed)  ($(if($isWifi){'Wi-Fi'}else{'Wired/other'}))"
if (-not $GW) { Write-Output "No default gateway - are you connected?"; Stop-Transcript | Out-Null; exit 1 }

Section "ROUTER IDENTITY (admin page)"
try {
  $r = Invoke-WebRequest -Uri "http://$GW" -UseBasicParsing -TimeoutSec 4
  Write-Output "Server header: $($r.Headers['Server'])"
  if ($r.Content -match '<title>([^<]*)') { Write-Output "Page title: $($Matches[1])" }
} catch {
  $resp = $_.Exception.Response
  if ($resp) { Write-Output "Server header: $($resp.Headers['Server']) (status $([int]$resp.StatusCode))" }
  else { Write-Output "(admin page not reachable over http)" }
}

if ($isWifi) {
  Section "WI-FI LINK"
  $wl = netsh wlan show interfaces
  $wl | Select-String -Pattern 'Radio type|Band|Channel|Receive rate|Transmit rate|Signal|Authentication' |
    ForEach-Object { $_.Line.Trim() }
  Write-Output "--- Nearby networks per channel (crowding) ---"
  netsh wlan show networks mode=bssid | Select-String -Pattern '^\s*Channel\s*:\s*(\d+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | Sort-Object { [int]$_.Name } |
    ForEach-Object { "channel {0,-4} {1} networks" -f $_.Name, $_.Count }
  Write-Output "(If Wi-Fi details are blank, Windows may need Location turned on for netsh.)"
}

Section "INTERFACE ERRORS / DROPS"
Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue |
  Select-Object ReceivedDiscardedPackets, ReceivedPacketErrors, OutboundDiscardedPackets, OutboundPacketErrors |
  Format-List | Out-String | Write-Output

Section "LATENCY & PACKET LOSS (idle, 30 pings each)"
foreach ($h in @($GW, '1.1.1.1', '8.8.8.8')) { Show-Ping $h 30 }

Section "ROUTE TO INTERNET (first hops)"
tracert -d -h 5 -w 1000 1.1.1.1

Section "DNS LOOKUP SPEED"
$names = 'google.com','wikipedia.org','netflix.com','amazon.com'
foreach ($s in @($GW, '1.1.1.1', '8.8.8.8')) {
  Write-Output "--- DNS server $s ---"
  foreach ($n in $names) {
    $ok = $true
    $t = Measure-Command { try { Resolve-DnsName $n -Server $s -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null } catch { $ok = $false } }
    Write-Output ("  {0,-15} {1}" -f $n, $(if ($ok) { "$([math]::Round($t.TotalMilliseconds)) ms" } else { 'FAILED/timeout' }))
  }
}

Section "SPEED TEST (Cloudflare)"
Write-Output "Download: $(Test-Download 100000000) Mbps"
Write-Output "Upload:   $(Test-Upload 25000000) Mbps"

Section "BUFFERBLOAT (latency while the line is busy)"
$idle = (Ping-Stats '1.1.1.1' 15).Avg
$job = Start-Job { $ProgressPreference='SilentlyContinue'
  try { Invoke-WebRequest "https://speed.cloudflare.com/__down?bytes=250000000" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {} }
Start-Sleep 2; $dl = (Ping-Stats '1.1.1.1' 15).Avg; $job | Wait-Job -Timeout 20 | Out-Null; $job | Remove-Job -Force
$job = Start-Job { $ProgressPreference='SilentlyContinue'
  try { Invoke-WebRequest "https://speed.cloudflare.com/__up" -Method Post -Body (New-Object byte[] 50000000) -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {} }
Start-Sleep 2; $ul = (Ping-Stats '1.1.1.1' 15).Avg; $job | Wait-Job -Timeout 20 | Out-Null; $job | Remove-Job -Force
Write-Output "Idle ping:            $idle ms"
Write-Output "Ping while download:  $dl ms"
Write-Output "Ping while upload:    $ul ms"
if ($idle -ne $null -and ($dl -ne $null -or $ul -ne $null)) {
  $added = [math]::Max([double]$dl, [double]$ul) - $idle
  $grade = if ($added -lt 30) {'A (good)'} elseif ($added -lt 60) {'B'} elseif ($added -lt 200) {'C (noticeable lag under load)'} else {'F (severe - enable QoS/SQM)'}
  Write-Output ("Added latency under load: {0:N0} ms -> grade {1}" -f $added, $grade)
}

Section "DEVICES ON THE NETWORK"
$prefix = ($GW -split '\.')[0..2] -join '.'
Write-Output "Scanning $prefix.1-254 ..."
$tasks = 1..254 | ForEach-Object { (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$prefix.$_", 1000) }
try { [Threading.Tasks.Task]::WaitAll($tasks) } catch {}
$neigh = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -like "$prefix.*" -and $_.State -in 'Reachable','Stale','Delay','Probe','Permanent' -and
                 $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and
                 $_.IPAddress -notlike '*.255' }
foreach ($n in $neigh) {
  $mac = $n.LinkLayerAddress
  $vendor = ($mac -split '-')[0..2] -join ':'
  $note = if ('26AE' -match [string]$mac[1]) { '(private/random MAC)' } else { '' }
  Write-Output ("  {0,-16} vendor-prefix {1} {2}" -f $n.IPAddress, $vendor, $note)
}
Write-Output "Total devices answering: $(@($neigh).Count)"

Section "DONE"
Write-Output "Report saved to: $Out"
Stop-Transcript | Out-Null
