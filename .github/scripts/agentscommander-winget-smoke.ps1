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

    $wingetRelease = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.290'
    $bundlePath = Join-Path $env:RUNNER_TEMP 'WinGet.msixbundle'
    $dependenciesZip = Join-Path $env:RUNNER_TEMP 'WinGet-dependencies.zip'
    $dependenciesDir = Join-Path $env:RUNNER_TEMP 'WinGet-dependencies'
    Invoke-WebRequest -Uri "$wingetRelease/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $bundlePath
    Invoke-WebRequest -Uri "$wingetRelease/DesktopAppInstaller_Dependencies.zip" -OutFile $dependenciesZip
    Expand-Archive -LiteralPath $dependenciesZip -DestinationPath $dependenciesDir
    $dependencyPaths = @(Get-ChildItem -LiteralPath (Join-Path $dependenciesDir 'x64') -File -Recurse |
        Where-Object Extension -in @('.appx', '.msix') | Select-Object -ExpandProperty FullName)
    if ($dependencyPaths.Count -eq 0) { throw 'Official WinGet release has no x64 dependency packages' }
    Add-AppxPackage -Path $bundlePath -DependencyPath $dependencyPaths -ForceApplicationShutdown
    $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller | Select-Object -First 1
    if (-not $appInstaller) { throw 'WinGet was not registered after bootstrap' }
    $wingetPath = Join-Path $appInstaller.InstallLocation 'winget.exe'

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
    if (@(Get-AgentEntries).Count -ne 0) { throw 'Runner already has Agents Commander installed' }
    $installMethod = 'direct-nsis-silent-install'
    $directInstall = Start-Process -FilePath $installerPath -ArgumentList '/S' -WindowStyle Hidden -PassThru
    if (-not $directInstall.WaitForExit(120000)) { throw 'NSIS silent installation timed out' }
    if ($directInstall.ExitCode -ne 0) { throw "NSIS installer exited with $($directInstall.ExitCode)" }

    $entries = @(Get-AgentEntries)
    $entries | Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, UninstallString, QuietUninstallString, PSChildName |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'installed-registry.json')
    if ($entries.Count -ne 1) { throw "Expected one uninstall record, got $($entries.Count)" }
    $entry = $entries[0]
    if ($entry.DisplayVersion -ne '0.30.5') { throw "Unexpected installed version: $($entry.DisplayVersion)" }
    if ($entry.Publisher -ne 'AgentsCommander Contributors') { throw "Unexpected publisher: $($entry.Publisher)" }
    if (-not $entry.InstallLocation) { throw 'Installer did not record InstallLocation' }
    $binaryPath = Join-Path $entry.InstallLocation.Trim('"') 'agentscommander.exe'
    if (-not (Test-Path -LiteralPath $binaryPath)) { throw 'Installed application executable is missing' }
    $installedHash = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash
    $installedVersion = (Get-Item -LiteralPath $binaryPath).VersionInfo
    $installedVersion | Select-Object ProductName, ProductVersion, FileVersion |
        ConvertTo-Json | Set-Content (Join-Path $evidenceDir 'installed-version.json')
    if ($installedVersion.ProductVersion -notmatch '^0\.30\.5(?:$|\.)') { throw 'Installed executable has an unexpected product version' }
    $rawPath = Join-Path $env:RUNNER_TEMP 'agentscommander-published-raw.exe'
    Invoke-WebRequest -Uri 'https://github.com/mblua/AgentsCommander/releases/download/v0.30.5/agentscommander-windows-x86_64.exe' -OutFile $rawPath
    if ((Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash -ne $binaryHash) { throw 'Published raw executable checksum mismatch' }
    $compareCode = @'
import hashlib, json, pathlib, struct, sys
def inspect(path):
    data=pathlib.Path(path).read_bytes()
    pe=struct.unpack_from("<I",data,0x3c)[0]
    machine,count,timestamp=struct.unpack_from("<HHI",data,pe+4)
    if machine!=0x8664: raise RuntimeError("Expected an x64 application executable")
    opt=struct.unpack_from("<H",data,pe+20)[0]
    sections={}
    for i in range(count):
        offset=pe+24+opt+i*40
        name=data[offset:offset+8].rstrip(b"\0").decode("ascii")
        size,start=struct.unpack_from("<II",data,offset+16)
        sections[name]={"size":size,"sha256":hashlib.sha256(data[start:start+size]).hexdigest()}
    return {"sha256":hashlib.sha256(data).hexdigest(),"size":len(data),"coff_timestamp":timestamp,"sections":sections}
installed=pathlib.Path(sys.argv[1]).read_bytes()
raw=pathlib.Path(sys.argv[2]).read_bytes()
token=b"__TAURI_BUNDLE_TYPE_VAR_UNK"
if raw.count(token)!=1: raise RuntimeError("Expected exactly one Tauri bundle marker")
expected=raw.replace(token,b"__TAURI_BUNDLE_TYPE_VAR_NSS",1)
if installed!=expected: raise RuntimeError("Installed payload differs beyond Tauri's documented NSIS bundle marker")
print(json.dumps({"installed":inspect(sys.argv[1]),"published_raw":inspect(sys.argv[2]),"normalized_payload_match":True},indent=2))
'@
    & python -c $compareCode $binaryPath $rawPath | Set-Content (Join-Path $evidenceDir 'binary-comparison.json')
    if ($LASTEXITCODE -ne 0) { throw 'PE architecture or content inspection failed' }

    & $binaryPath --help 2>&1 | Tee-Object -FilePath (Join-Path $evidenceDir 'cli-help.log')
    if ($LASTEXITCODE -ne 0) { throw "Installed CLI --help failed: $LASTEXITCODE" }

    $uninstallerPath = $entry.UninstallString.Trim('"')
    $uninstallProcess = Start-Process -FilePath $uninstallerPath -ArgumentList '/S' -WindowStyle Hidden -PassThru
    if (-not $uninstallProcess.WaitForExit(60000)) { throw 'NSIS silent uninstall launcher timed out' }
    $uninstallDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((@(Get-AgentEntries).Count -ne 0 -or (Test-Path -LiteralPath $binaryPath)) -and [DateTime]::UtcNow -lt $uninstallDeadline) {
        Start-Sleep -Milliseconds 500
    }
    if (@(Get-AgentEntries).Count -ne 0) { throw 'NSIS uninstall left its application registry record behind' }
    if (Test-Path -LiteralPath $binaryPath) { throw 'NSIS uninstall left the application executable behind' }
    'Silent uninstall removed the application executable and uninstall registry record.' |
        Set-Content (Join-Path $evidenceDir 'nsis-uninstall.log')

    [ordered]@{
        package = 'mblua.AgentsCommander'
        version = '0.30.5'
        installer_sha256 = $installerHash
        installed_binary_sha256 = $installedHash
        published_raw_binary_sha256 = $binaryHash
        checks = @('official-download-sha256', 'winget-validate', $installMethod, 'registry-metadata', 'tauri-normalized-payload-match', 'cli-help', 'direct-nsis-silent-uninstall')
        outcome = 'passed'
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidenceDir 'result.json')
} finally {
    $wingetDiagnostics = Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir'
    if (Test-Path -LiteralPath $wingetDiagnostics) {
        Copy-Item -LiteralPath $wingetDiagnostics -Destination (Join-Path $evidenceDir 'winget-diagnostics') -Recurse
    }
    Stop-Transcript
}
