$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$EnvPath = Join-Path $RepoRoot ".env"
$ServerOut = Join-Path $RepoRoot "server.out.log"
$ServerErr = Join-Path $RepoRoot "server.err.log"

function Load-EnvFile {
  if (!(Test-Path -LiteralPath $EnvPath)) {
    throw ".env not found at $EnvPath"
  }

  Get-Content -LiteralPath $EnvPath | Where-Object { $_ -match '^\s*[^#][^=]+=' } | ForEach-Object {
    $parts = $_.Split("=", 2)
    [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
  }
}

function Get-EnvValue([string]$Name, [string]$Fallback) {
  $value = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
  return $value
}

function Get-McpPort {
  [int](Get-EnvValue "GPT_FS_MCP_PORT" "8789")
}

function Get-McpBaseUrl {
  Get-EnvValue "PUBLIC_BASE_URL" "http://127.0.0.1:$(Get-McpPort)"
}

function Get-CloudflaredExe {
  Get-EnvValue "CLOUDFLARED_EXE" (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Documents\cloudflared\cloudflared.exe")
}

function Get-CloudflaredConfig {
  Get-EnvValue "CLOUDFLARED_CONFIG" (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".cloudflared\config.yml")
}

function Get-TunnelName {
  Get-EnvValue "CLOUDFLARE_TUNNEL_NAME" "chatgpt-local-agent-mcp"
}

function Get-TunnelPidFile {
  Join-Path $RepoRoot "data\cloudflared.pid"
}

function Get-McpListener {
  $port = Get-McpPort
  Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -eq "127.0.0.1" -or $_.LocalAddress -eq "::1" } |
    Select-Object -First 1
}

function Get-McpProcess {
  $listener = Get-McpListener
  if (!$listener) { return $null }
  Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
}

function Get-TunnelProcess {
  $pidFile = Get-TunnelPidFile
  if (Test-Path -LiteralPath $pidFile) {
    $savedPid = 0
    $savedText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ([int]::TryParse($savedText, [ref]$savedPid) -and $savedPid -gt 0) {
      $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid" -ErrorAction SilentlyContinue
      if ($candidate -and $candidate.Name -eq "cloudflared.exe") { return $candidate }
    }
  }
  $tunnelName = Get-TunnelName
  Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$tunnelName*" } |
    Select-Object -First 1
}

function Ensure-NodeDependencies {
  $nodeModules = Join-Path $RepoRoot "node_modules"
  $packageLock = Join-Path $RepoRoot "package-lock.json"
  if (Test-Path -LiteralPath $nodeModules) { return }
  if (!(Test-Path -LiteralPath $packageLock)) {
    throw "package-lock.json not found; cannot install dependencies."
  }
  Push-Location $RepoRoot
  try {
    npm ci
    if ($LASTEXITCODE -ne 0) {
      throw "npm ci failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

function Invoke-Health([string]$Url) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 8
    return "$($response.StatusCode) $($response.Content)"
  } catch {
    return "FAIL $($_.Exception.Message)"
  }
}

function Show-Status {
  Load-EnvFile
  $port = Get-McpPort
  $baseUrl = Get-McpBaseUrl
  $mcpUrl = "$baseUrl/mcp"
  $listener = Get-McpListener
  $mcpProcess = Get-McpProcess
  $tunnelProcess = Get-TunnelProcess

  Write-Host ""
  Write-Host "chatgpt-local-agent-mcp status"
  Write-Host "Repo:        $RepoRoot"
  Write-Host "Local port:  $port"
  Write-Host "Public URL:  $baseUrl"
  Write-Host "MCP URL:     $mcpUrl"
  Write-Host ""

  if ($listener) {
    Write-Host "Local MCP:   RUNNING pid=$($listener.OwningProcess) bind=$($listener.LocalAddress):$($listener.LocalPort)"
    if ($mcpProcess) { Write-Host "Command:     $($mcpProcess.CommandLine)" }
  } else {
    Write-Host "Local MCP:   STOPPED"
  }

  if ($tunnelProcess) {
    Write-Host "Tunnel:      RUNNING pid=$($tunnelProcess.ProcessId)"
  } else {
    Write-Host "Tunnel:      STOPPED"
  }

  Write-Host ""
  Write-Host "Local health:  $(Invoke-Health "http://127.0.0.1:$port/healthz")"
  Write-Host "Public health: $(Invoke-Health "$baseUrl/healthz")"
  Write-Host ""
}

function Show-EndpointInfo {
  Load-EnvFile
  $baseUrl = Get-McpBaseUrl
  Write-Host ""
  Write-Host "Endpoint info"
  Write-Host "Dashboard: http://127.0.0.1:$(Get-McpPort)/dashboard"
  Write-Host "Health:   $baseUrl/healthz"
  Write-Host "MCP:      $baseUrl/mcp"
  Write-Host "OAuth PR: $baseUrl/.well-known/oauth-protected-resource"
  Write-Host "OAuth AS: $baseUrl/.well-known/oauth-authorization-server"
  Write-Host ""

  try {
    $metadata = Invoke-RestMethod -Uri "$baseUrl/.well-known/oauth-protected-resource" -TimeoutSec 8
    Write-Host "Resource: $($metadata.resource)"
    Write-Host "Scopes:   $($metadata.scopes_supported -join ', ')"
  } catch {
    Write-Host "Metadata: FAIL $($_.Exception.Message)"
  }
  Write-Host ""
}

function Open-Dashboard {
  Load-EnvFile
  Start-Process "http://127.0.0.1:$(Get-McpPort)/dashboard"
}

function Test-McpAuthGuard {
  Load-EnvFile
  $baseUrl = Get-McpBaseUrl
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/mcp" -Method Post -Headers @{ Accept = "application/json, text/event-stream" } -ContentType "application/json" -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"guard-probe","version":"1"}}}' -TimeoutSec 8 | Out-Null
    Write-Host "Auth guard: UNEXPECTED SUCCESS"
  } catch {
    $response = $_.Exception.Response
    if ($response) {
      Write-Host "Auth guard: HTTP $([int]$response.StatusCode) $($response.StatusDescription)"
    } else {
      Write-Host "Auth guard: FAIL $($_.Exception.Message)"
    }
  }
}

function Start-McpServer {
  Load-EnvFile
  $existing = Get-McpListener
  if ($existing) {
    Write-Host "MCP already running on port $(Get-McpPort), pid=$($existing.OwningProcess)"
    return
  }

  $distIndex = Join-Path $RepoRoot "dist\index.js"
  if (!(Test-Path -LiteralPath $distIndex)) {
    Write-Host "dist/index.js not found. Running npm run build first..."
    Push-Location $RepoRoot
    try {
      Ensure-NodeDependencies
      npm run build
      if ($LASTEXITCODE -ne 0) {
        throw "npm run build failed with exit code $LASTEXITCODE"
      }
    } finally { Pop-Location }
  }

  Remove-Item -LiteralPath $ServerOut, $ServerErr -Force -ErrorAction SilentlyContinue
  $process = Start-Process -FilePath "node" -ArgumentList "dist/index.js" -WorkingDirectory $RepoRoot -WindowStyle Hidden -RedirectStandardOutput $ServerOut -RedirectStandardError $ServerErr -PassThru

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Get-McpListener) {
      Write-Host "MCP started, pid=$($process.Id)"
      return
    }
  }

  Write-Host "MCP did not become ready. Last stderr:"
  if (Test-Path -LiteralPath $ServerErr) { Get-Content -LiteralPath $ServerErr -Tail 20 }
}

function Stop-McpServer {
  Load-EnvFile
  $listener = Get-McpListener
  if (!$listener) {
    Write-Host "MCP is not running on port $(Get-McpPort)"
    return
  }

  $process = Get-McpProcess
  if ($process -and $process.CommandLine -notlike "*dist/index.js*") {
    Write-Host "Refusing to stop pid=$($listener.OwningProcess): command line does not look like this MCP server."
    Write-Host $process.CommandLine
    return
  }

  Stop-Process -Id $listener.OwningProcess -Force
  Write-Host "MCP stopped, pid=$($listener.OwningProcess)"
}

function Restart-McpServer {
  Stop-McpServer
  Start-Sleep -Milliseconds 800
  Start-McpServer
}

function Start-Tunnel {
  Load-EnvFile
  $cloudflaredExe = Get-CloudflaredExe
  $cloudflaredConfig = Get-CloudflaredConfig
  $tunnelName = Get-TunnelName
  $tunnelToken = Get-EnvValue "CLOUDFLARE_TUNNEL_TOKEN" ""
  $existing = Get-TunnelProcess
  if ($existing) {
    Write-Host "Tunnel already running, pid=$($existing.ProcessId)"
    return
  }
  $publicUrl = Get-McpBaseUrl
  if ($publicUrl.StartsWith("https://")) {
    try {
      $probe = Invoke-WebRequest -UseBasicParsing -Uri "$($publicUrl.TrimEnd('/'))/healthz" -TimeoutSec 4
      if ($probe.StatusCode -eq 200) {
        Write-Host "Public MCP endpoint is already reachable; tunnel startup skipped."
        return
      }
    } catch {}
  }
  if (!(Test-Path -LiteralPath $cloudflaredExe)) { throw "cloudflared.exe not found at $cloudflaredExe" }
  if ([string]::IsNullOrWhiteSpace($tunnelToken) -and !(Test-Path -LiteralPath $cloudflaredConfig)) {
    throw "Local config.yml missing. Set CLOUDFLARE_TUNNEL_TOKEN for a Cloudflare-managed tunnel."
  }

  $dataDir = Join-Path $RepoRoot "data"
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $out = Join-Path $dataDir "cloudflared.out.log"
  $err = Join-Path $dataDir "cloudflared.err.log"
  $args = if ($tunnelToken) { "tunnel run" } else { "tunnel --config `"$cloudflaredConfig`" run $tunnelName" }
  $previousToken = [Environment]::GetEnvironmentVariable("TUNNEL_TOKEN", "Process")
  try {
    if ($tunnelToken) { [Environment]::SetEnvironmentVariable("TUNNEL_TOKEN", $tunnelToken, "Process") }
    $process = Start-Process -FilePath $cloudflaredExe -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  } finally {
    [Environment]::SetEnvironmentVariable("TUNNEL_TOKEN", $previousToken, "Process")
  }
  Set-Content -LiteralPath (Get-TunnelPidFile) -Value $process.Id -NoNewline -Encoding Ascii
  Write-Host "Tunnel process started, pid=$($process.Id); check public health."
}

function Stop-Tunnel {
  $process = Get-TunnelProcess
  if (!$process) {
    Write-Host "Tunnel is not running."
    return
  }
  Stop-Process -Id $process.ProcessId -Force
  Remove-Item -LiteralPath (Get-TunnelPidFile) -Force -ErrorAction SilentlyContinue
  Write-Host "Tunnel stopped, pid=$($process.ProcessId)"
}

function Show-Logs {
  Write-Host ""
  Write-Host "server.out.log"
  if (Test-Path -LiteralPath $ServerOut) { Get-Content -LiteralPath $ServerOut -Tail 40 } else { Write-Host "(missing)" }
  Write-Host ""
  Write-Host "server.err.log"
  if (Test-Path -LiteralPath $ServerErr) { Get-Content -LiteralPath $ServerErr -Tail 40 } else { Write-Host "(missing)" }
  Write-Host ""
}

function Show-NonLocalListeners {
  $listeners = Get-NetTCPConnection -State Listen |
    Where-Object { $_.LocalAddress -notin @("127.0.0.1", "::1") } |
    Sort-Object LocalPort, LocalAddress

  $items = foreach ($listener in $listeners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
    [pscustomobject]@{
      LocalAddress = $listener.LocalAddress
      LocalPort = $listener.LocalPort
      PID = $listener.OwningProcess
      Name = $process.Name
      CommandLine = $process.CommandLine
    }
  }

  if (!$items) {
    Write-Host "No non-local TCP listeners found."
    return
  }

  $items | Format-Table -AutoSize
}

function Show-Menu {
  Write-Host ""
  Write-Host "chatgpt-local-agent-mcp-control"
  Write-Host "1. Status + health"
  Write-Host "2. Start local MCP server"
  Write-Host "3. Stop local MCP server"
  Write-Host "4. Restart local MCP server"
  Write-Host "5. Start Cloudflare tunnel"
  Write-Host "6. Stop Cloudflare tunnel"
  Write-Host "7. Endpoint info + scopes"
  Write-Host "8. Test public auth guard"
  Write-Host "9. Show logs"
  Write-Host "10. Show non-local TCP listeners"
  Write-Host "11. Open local dashboard"
  Write-Host "0. Exit"
}

Load-EnvFile
while ($true) {
  Show-Menu
  $choice = Read-Host "Select"
  try {
    switch ($choice) {
      "1" { Show-Status }
      "2" { Start-McpServer }
      "3" { Stop-McpServer }
      "4" { Restart-McpServer }
      "5" { Start-Tunnel }
      "6" { Stop-Tunnel }
      "7" { Show-EndpointInfo }
      "8" { Test-McpAuthGuard }
      "9" { Show-Logs }
      "10" { Show-NonLocalListeners }
      "11" { Open-Dashboard }
      "0" { break }
      default { Write-Host "Unknown option: $choice" }
    }
  } catch {
    Write-Host "ERROR: $($_.Exception.Message)"
  }
}
