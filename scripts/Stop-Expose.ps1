[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-TrackedProcess([int] $ProcessId, [string] $ExpectedStartTimeUtc) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return
    }

    $expected = [DateTime]::Parse(
        $ExpectedStartTimeUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $difference = [Math]::Abs(
        ($process.StartTime.ToUniversalTime() - $expected.ToUniversalTime()).TotalSeconds)
    if ($difference -gt 2) {
        throw "Refusing to stop PID $ProcessId because it is no longer the tracked process."
    }
    Stop-Process -Id $ProcessId -Force
}

$runtimeRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CopilotExpose'))
$statePath = Join-Path $runtimeRoot 'active.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    [pscustomobject]@{
        Stopped = $true
        WasRunning = $false
    }
    return
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
Stop-TrackedProcess -ProcessId $state.tunnelPid -ExpectedStartTimeUtc $state.tunnelStartTimeUtc
Stop-TrackedProcess -ProcessId $state.pythonPid -ExpectedStartTimeUtc $state.pythonStartTimeUtc

$siteRoot = [IO.Path]::GetFullPath([string] $state.siteRoot)
$allowedPrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $siteRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove unexpected staging path '$siteRoot'."
}
if (Test-Path -LiteralPath $siteRoot -PathType Container) {
    Remove-Item -LiteralPath $siteRoot -Recurse -Force
}
Remove-Item -LiteralPath $statePath -Force

[pscustomobject]@{
    Stopped = $true
    WasRunning = $true
    PublicUrl = [string] $state.publicUrl
}
