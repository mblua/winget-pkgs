$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$evidenceDir = Join-Path $env:GITHUB_WORKSPACE 'evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
Start-Transcript -Path (Join-Path $evidenceDir 'transcript.txt')
try {
    $manifestDir = Join-Path $env:GITHUB_WORKSPACE 'manifests/m/mblua/AgentsCommander/0.30.5'
    $installerUrl = 'https://github.com/mblua/AgentsCommander/releases/download/v0.30.5/Agents.Commander_0.30.5_x64-setup.exe'
    $installerHash = '429C72004DCBA2343D147BF9E0283C03CC85DDC12EDCF6CC7202759F4CA380DF'
    $binaryHash = 'E66DC320CE27B3DE5A085E7E7453E85D1E4931E07EF9AC7B048D18FD1BE33A27'
    $installerPath = Join-Path $env:RUNNER_TEMP 'Agents.Commander_0.30.5_x64-setup.exe'
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
    if ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ne $installerHash) {
        throw 'Published installer checksum mismatch'
    }
    (Get-Item -LiteralPath $installerPath).VersionInfo |
        Select-Object CompanyName, ProductName, ProductVersion, FileVersion, OriginalFilename |
        ConvertTo-Json | Set-Content (Join-Path $evidenceDir 'installer-version.json')

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers
    }
    $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wingetCommand) {
        $wingetPath = $wingetCommand.Source
    } else {
        $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller | Select-Object -First 1
        if (-not $appInstaller) { throw 'WinGet was not registered after bootstrap' }
        $wingetPath = Join-Path $appInstaller.InstallLocation 'winget.exe'
    }

    function Invoke-WinGetChecked {
        param([string]$LogName, [string[]]$Arguments)
        & $wingetPath @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $evidenceDir $LogName)
        if ($LASTEXITCODE -ne 0) {
            throw "WinGet exited with $LASTEXITCODE for $($Arguments -join ' ')"
        }
    }
    function Get-AgentEntries {
        @(
            Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        ) | Where-Object DisplayName -eq 'Agents Commander'
    }

    Invoke-WinGetChecked 'winget-version.log' @('--version')
    Invoke-WinGetChecked 'winget-validate.log' @('validate', '--manifest', $manifestDir, '--disable-interactivity')
    Invoke-WinGetChecked 'winget-settings.log' @('settings', '--enable', 'LocalManifestFiles')
    if (@(Get-AgentEntries).Count -ne 0) { throw 'Runner already has Agents Commander installed' }
    Invoke-WinGetChecked 'winget-install.log' @('install', '--manifest', $manifestDir, '--scope', 'user', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')

    $entries = @(Get-AgentEntries)
    $entries | Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, UninstallString, QuietUninstallString, PSChildName |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'installed-registry.json')
    if ($entries.Count -ne 1) { throw "Expected one uninstall record, got $($entries.Count)" }
    $entry = $entries[0]
    if ($entry.DisplayVersion -ne '0.30.5') { throw "Unexpected installed version: $($entry.DisplayVersion)" }
    if ($entry.Publisher -ne 'AgentsCommander Contributors') { throw "Unexpected publisher: $($entry.Publisher)" }
    if (-not $entry.InstallLocation) { throw 'Installer did not record InstallLocation' }
    $binaryPath = Join-Path $entry.InstallLocation 'agentscommander.exe'
    if (-not (Test-Path -LiteralPath $binaryPath)) { throw 'Installed application executable is missing' }
    if ((Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash -ne $binaryHash) {
        throw 'Installed executable does not match the published Windows binary'
    }

    & $binaryPath --help 2>&1 | Tee-Object -FilePath (Join-Path $evidenceDir 'cli-help.log')
    if ($LASTEXITCODE -ne 0) { throw "Installed CLI --help failed: $LASTEXITCODE" }

    Invoke-WinGetChecked 'winget-uninstall.log' @('uninstall', '--name', 'Agents Commander', '--exact', '--silent', '--disable-interactivity', '--accept-source-agreements')
    if (@(Get-AgentEntries).Count -ne 0) { throw 'Uninstall left its application registry record behind' }
    if (Test-Path -LiteralPath $binaryPath) { throw 'Uninstall left the application executable behind' }

    [ordered]@{
        package = 'mblua.AgentsCommander'
        version = '0.30.5'
        installer_sha256 = $installerHash
        installed_binary_sha256 = $binaryHash
        checks = @('official-download-sha256', 'winget-validate', 'winget-silent-install', 'registry-metadata', 'installed-payload-sha256', 'cli-help', 'winget-silent-uninstall')
        outcome = 'passed'
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'result.json')
} finally {
    Stop-Transcript
}
