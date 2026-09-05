[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $HtmlPath,

    [ValidateRange(15, 180)]
    [int] $TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Get-Cloudflared([string] $ToolPath) {
    if (Test-Path -LiteralPath $ToolPath -PathType Leaf) {
        return $ToolPath
    }

    $toolDirectory = Split-Path -Parent $ToolPath
    [IO.Directory]::CreateDirectory($toolDirectory) | Out-Null

    $headers = @{ 'User-Agent' = 'Copilot-Expose-Skill' }
    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest' `
        -Headers $headers
    $asset = @($release.assets | Where-Object {
        $_.name -eq 'cloudflared-windows-amd64.exe'
    }) | Select-Object -First 1
    if ($null -eq $asset) {
        throw 'The latest cloudflared release has no Windows AMD64 executable.'
    }
    if ([string]::IsNullOrWhiteSpace([string] $asset.digest) -or
        -not ([string] $asset.digest).StartsWith('sha256:')) {
        throw 'Cloudflare did not publish a SHA-256 digest for cloudflared.'
    }

    $downloadPath = "$ToolPath.download"
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -Headers $headers
        $expectedHash = ([string] $asset.digest).Substring(7)
        $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
        if ($actualHash -cne $expectedHash.ToUpperInvariant()) {
            throw 'The downloaded cloudflared executable failed SHA-256 verification.'
        }
        Move-Item -LiteralPath $downloadPath -Destination $ToolPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath -PathType Leaf) {
            Remove-Item -LiteralPath $downloadPath -Force
        }
    }

    return $ToolPath
}

$resolvedHtmlPath = [IO.Path]::GetFullPath($HtmlPath)
if (-not (Test-Path -LiteralPath $resolvedHtmlPath -PathType Leaf)) {
    throw "HTML file was not found at '$resolvedHtmlPath'."
}
if ([IO.Path]::GetExtension($resolvedHtmlPath) -cne '.html') {
    throw 'HtmlPath must reference an .html file.'
}

$python = Get-Command python.exe, python -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $python) {
    throw 'Python was not found. Install Python 3 and ensure python.exe is on PATH.'
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$cloudflaredPath = Get-Cloudflared (Join-Path $skillRoot 'tools\cloudflared.exe')
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'CopilotExpose'
$statePath = Join-Path $runtimeRoot 'active.json'
[IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    & (Join-Path $PSScriptRoot 'Stop-Expose.ps1') | Out-Null
}

$shareId = [Guid]::NewGuid().ToString('N')
$siteRoot = Join-Path $runtimeRoot $shareId
[IO.Directory]::CreateDirectory($siteRoot) | Out-Null
Copy-Item -LiteralPath $resolvedHtmlPath -Destination (Join-Path $siteRoot 'index.html')

$port = Get-FreeTcpPort
$pythonOut = Join-Path $siteRoot 'python.stdout.log'
$pythonErr = Join-Path $siteRoot 'python.stderr.log'
$tunnelOut = Join-Path $siteRoot 'cloudflared.stdout.log'
$tunnelErr = Join-Path $siteRoot 'cloudflared.stderr.log'
$pythonProcess = $null
$tunnelProcess = $null

try {
    $quotedSiteRoot = '"' + $siteRoot.Replace('"', '\"') + '"'
    $pythonArguments = "-m http.server $port --bind 127.0.0.1 --directory $quotedSiteRoot"
    $pythonProcess = Start-Process `
        -FilePath $python.Source `
        -ArgumentList $pythonArguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $pythonOut `
        -RedirectStandardError $pythonErr `
        -PassThru

    $localUrl = "http://127.0.0.1:$port/"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $localReady = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($pythonProcess.HasExited) {
            $detail = Get-Content -LiteralPath $pythonErr -Raw -ErrorAction SilentlyContinue
            throw "The local HTML server exited unexpectedly. $detail"
        }
        try {
            $response = Invoke-WebRequest -Uri $localUrl -TimeoutSec 3 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                $localReady = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $localReady) {
        throw 'The local HTML server did not become ready in time.'
    }

    $tunnelProcess = Start-Process `
        -FilePath $cloudflaredPath `
        -ArgumentList "tunnel --url $localUrl --no-autoupdate" `
        -WindowStyle Hidden `
        -RedirectStandardOutput $tunnelOut `
        -RedirectStandardError $tunnelErr `
        -PassThru

    $publicUrl = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($tunnelProcess.HasExited) {
            $detail = Get-Content -LiteralPath $tunnelErr -Raw -ErrorAction SilentlyContinue
            throw "Cloudflare Tunnel exited unexpectedly. $detail"
        }
        $logs = @(
            Get-Content -LiteralPath $tunnelOut -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $tunnelErr -Raw -ErrorAction SilentlyContinue
        ) -join "`n"
        $match = [regex]::Match($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($match.Success) {
            $publicUrl = $match.Value
            try {
                $response = Invoke-WebRequest -Uri $publicUrl -TimeoutSec 10 -UseBasicParsing
                if ($response.StatusCode -eq 200) {
                    break
                }
            }
            catch {
                $publicUrl = $null
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if ([string]::IsNullOrWhiteSpace($publicUrl)) {
        throw 'The public Cloudflare URL did not become reachable in time.'
    }

    $state = [ordered]@{
        version = 1
        sourceHtmlPath = $resolvedHtmlPath
        siteRoot = $siteRoot
        localUrl = $localUrl
        publicUrl = $publicUrl
        pythonPid = $pythonProcess.Id
        pythonStartTimeUtc = $pythonProcess.StartTime.ToUniversalTime().ToString('O')
        tunnelPid = $tunnelProcess.Id
        tunnelStartTimeUtc = $tunnelProcess.StartTime.ToUniversalTime().ToString('O')
        startedAtUtc = [DateTime]::UtcNow.ToString('O')
    }
    [IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        Ready = $true
        PublicUrl = $publicUrl
        SourceHtmlPath = $resolvedHtmlPath
        StopCommand = "& `"$PSScriptRoot\Stop-Expose.ps1`""
    }
}
catch {
    foreach ($process in @($tunnelProcess, $pythonProcess)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $siteRoot -PathType Container) {
        Remove-Item -LiteralPath $siteRoot -Recurse -Force
    }
    throw
}

