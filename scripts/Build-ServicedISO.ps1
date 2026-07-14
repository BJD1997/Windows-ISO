<#
.SYNOPSIS
    Downloads the latest Windows 11 ISO + latest Cumulative Update, applies the CU
    to install.wim via DISM, and rebuilds a bootable ISO.

.DESCRIPTION
    Designed to run non-interactively on a GitHub Actions windows-2022 runner.
    All heavy work happens under -WorkDir (default D:\work) because the D: drive
    on windows-2022 runners has ~140 GB free, versus ~33 GB on C:.

    Consumer ISOs ship install.esd; this script exports the target edition to a
    serviceable install.wim before mounting.

.NOTES
    Requires: Fido.ps1 (fetched by the workflow), oscdimg.exe (Windows ADK
    Deployment Tools), and administrative rights (GitHub runners run elevated).
#>
[CmdletBinding()]
param(
    [string]$WinRelease   = "25H2",              # Fido -Rel value
    [string]$Edition      = "Pro",               # Fido -Ed value
    [string]$ImageEdition = "Windows 11 Pro",    # WIM ImageName to service
    [string]$Language     = "English",
    [string]$Arch         = "x64",
    [string]$Build        = "26200",             # OS build family for CU search (25H2 = 26200)
    [string]$WorkDir      = "D:\work",
    [string]$FidoPath     = "D:\work\Fido.ps1",
    [string]$OscdimgPath  = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",

    # Which CI system to emit output variables for.
    #   githubactions -> writes key=value lines to $env:GITHUB_OUTPUT
    #   azuredevops   -> emits ##vso[task.setvariable ...] logging commands
    #   none          -> just prints (useful for local runs)
    [ValidateSet("githubactions", "azuredevops", "none")]
    [string]$CiSystem     = "githubactions"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# -------- Paths --------
$IsoDownloadDir = Join-Path $WorkDir "iso_download"
$ExtractDir     = Join-Path $WorkDir "iso_extract"
$MountDir       = Join-Path $WorkDir "mount"
$CuDir          = Join-Path $WorkDir "cu"
$OutputDir      = Join-Path $WorkDir "output"

foreach ($d in @($IsoDownloadDir, $ExtractDir, $MountDir, $CuDir, $OutputDir)) {
    New-Item -Path $d -ItemType Directory -Force | Out-Null
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ------------------------------------------------------------------
# 1. Download the Windows ISO using Fido
# ------------------------------------------------------------------
function Get-WindowsIso {
    Write-Step "Requesting ISO download URL from Fido ($WinRelease $Edition $Arch)..."

    # Fido -GetUrl prints the official Microsoft download URL to stdout
    $url = & $FidoPath -Win 11 -Rel $WinRelease -Ed $Edition -Lang $Language -Arch $Arch -GetUrl
    if (-not $url) { throw "Fido did not return a download URL." }
    $url = ($url | Select-Object -Last 1).Trim()
    Write-Host "ISO URL: $url"

    $isoPath = Join-Path $IsoDownloadDir "windows.iso"
    Write-Step "Downloading ISO (this is several GB)..."
    # BITS-free, streamed download
    Invoke-WebRequest -Uri $url -OutFile $isoPath -UseBasicParsing
    Write-Host "Saved to $isoPath ($([math]::Round((Get-Item $isoPath).Length / 1GB, 2)) GB)"
    return $isoPath
}

# ------------------------------------------------------------------
# 2. Download the latest Cumulative Update from the MS Update Catalog
# ------------------------------------------------------------------
function Get-LatestCumulativeUpdate {
    $searchQuery = "Cumulative Update Windows 11 $Arch $WinRelease"
    # Encode the query: raw spaces in a URL behave inconsistently across hosts.
    $catalogUrl  = "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($searchQuery))"

    Write-Step "Searching Microsoft Update Catalog..."

    # Send a browser UA. The catalog can serve different markup to a bare
    # PowerShell user-agent coming from a datacenter IP than to a desktop.
    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    }
    $response = Invoke-WebRequest -Uri $catalogUrl -UseBasicParsing -Headers $headers
    $html = $response.Content

    # A result row's id looks like: <tr id="<guid>_R0" ...>
    # Splitting on '<tr ... id="' makes element 0 = all the page chrome BEFORE
    # the first row (scripts, search box, headers). That chunk is NOT a result
    # row. Previously it was only excluded by the build-number filter, so if the
    # build number happened to appear anywhere in the chrome, it survived, landed
    # at $rows[0], and the GUID regex blew up. Identify real rows FIRST.
    $rowPattern = '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_R\d+'
    $allRows = $html -split '<tr[^>]*id="' | Where-Object { $_ -match $rowPattern }

    if (-not $allRows) {
        Write-Warning "No result rows parsed from the catalog page."
        Write-Warning "Page length: $($html.Length) chars. First 500 chars follow:"
        Write-Warning ($html.Substring(0, [Math]::Min(500, $html.Length)))
        throw "Catalog returned no parseable result rows (search: '$searchQuery')."
    }

    Write-Host "Parsed $($allRows.Count) result row(s) from the catalog."

    # Now narrow to the update we actually want.
    $candidates = $allRows |
        Where-Object { $_ -match $Build } |
        Where-Object { $_ -notmatch 'Preview' -and $_ -notmatch '\.NET' -and $_ -notmatch 'Dynamic' }

    if (-not $candidates) {
        # Dump what we DID see -- makes a wrong -Build value obvious immediately.
        Write-Warning "No row matched build '$Build'. Titles returned by the catalog:"
        foreach ($r in $allRows) {
            if ($r -match '<a[^>]*>([^<]+)</a>') { Write-Warning "  - $($Matches[1].Trim())" }
        }
        throw "No cumulative update found for build $Build. Is -Build correct for $WinRelease?"
    }

    $firstRow = $candidates[0]

    # Anchored, so it can only ever match this row's own id -- not a GUID
    # belonging to some other row further down the chunk.
    if ($firstRow -notmatch $rowPattern) {
        throw "Could not extract update ID (row did not start with a GUID)."
    }
    $updateId = $Matches[1]

    if ($firstRow -match '<a[^>]*>([^<]+)</a>') { $updateTitle = $Matches[1].Trim() }

    if ($firstRow -match '(KB\d+)') {
        $kbNumber = $Matches[1]
        Write-Host "Found: $updateTitle"
    } else { throw "Could not extract KB number." }

    $postBody = @{
        updateIDs = "[{""size"":0,""uidInfo"":""$updateId"",""updateID"":""$updateId""}]"
    }
    $downloadPage = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" `
        -Method Post -Body $postBody -UseBasicParsing -Headers $headers

    $allUrls     = [regex]::Matches($downloadPage.Content, "https?://[^'""\s]+\.msu")
    $downloadUrl = ($allUrls | Where-Object { $_.Value -match $kbNumber }).Value | Select-Object -First 1
    if (-not $downloadUrl) { throw "Could not find download URL for $kbNumber." }

    $fileName = $downloadUrl -split '/' | Select-Object -Last 1
    $filePath = Join-Path $CuDir $fileName

    Write-Step "Downloading $kbNumber ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -UseBasicParsing
    Write-Host "Saved to $filePath"

    return [pscustomobject]@{ Path = $filePath; KB = $kbNumber; Title = $updateTitle }
}

# ------------------------------------------------------------------
# 3. Extract ISO contents to a writable folder
# ------------------------------------------------------------------
function Expand-Iso {
    param([string]$IsoPath)

    Write-Step "Mounting ISO..."
    $mount  = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $volume = ($mount | Get-Volume).DriveLetter
    $driveRoot = "${volume}:\"

    Write-Step "Copying ISO contents to $ExtractDir ..."
    Copy-Item -Path (Join-Path $driveRoot '*') -Destination $ExtractDir -Recurse -Force

    Dismount-DiskImage -ImagePath $IsoPath | Out-Null

    # Clear read-only attributes copied from the mounted ISO
    Get-ChildItem -Path $ExtractDir -Recurse -File |
        ForEach-Object { $_.Attributes = 'Normal' }

    # Free the raw ISO immediately to save disk
    Remove-Item $IsoPath -Force
    Write-Host "Extraction complete; raw ISO removed."
}

# ------------------------------------------------------------------
# 4. Ensure a serviceable install.wim (convert from install.esd if needed)
# ------------------------------------------------------------------
function Resolve-InstallWim {
    $sources = Join-Path $ExtractDir "sources"
    $wim = Join-Path $sources "install.wim"
    $esd = Join-Path $sources "install.esd"

    if (Test-Path $wim) {
        Write-Host "install.wim already present."
        return $wim
    }

    if (-not (Test-Path $esd)) { throw "Neither install.wim nor install.esd found in $sources." }

    Write-Step "Converting install.esd -> install.wim (edition: $ImageEdition)..."
    $images = Get-WindowsImage -ImagePath $esd
    $match  = $images | Where-Object { $_.ImageName -eq $ImageEdition }
    if (-not $match) {
        Write-Host "Available editions in ESD:"
        $images | ForEach-Object { Write-Host "  Index $($_.ImageIndex): $($_.ImageName)" }
        throw "Edition '$ImageEdition' not found in install.esd."
    }

    # Export only the target edition -> smaller single-edition WIM
    Export-WindowsImage -SourceImagePath $esd -SourceIndex $match.ImageIndex `
        -DestinationImagePath $wim -CompressionType Max | Out-Null

    Remove-Item $esd -Force
    Write-Host "Conversion done; install.esd removed."
    return $wim
}

# ------------------------------------------------------------------
# 5. Mount WIM, apply CU, dismount /commit
# ------------------------------------------------------------------
function Add-CuToWim {
    param([string]$WimPath, [string]$CuPath)

    $images = Get-WindowsImage -ImagePath $WimPath
    # After single-edition export, index is 1; still resolve by name for safety
    $match  = $images | Where-Object { $_.ImageName -eq $ImageEdition }
    if (-not $match) { $match = $images | Select-Object -First 1 }
    $index = $match.ImageIndex

    Write-Step "Mounting install.wim (index $index)..."
    Mount-WindowsImage -ImagePath $WimPath -Index $index -Path $MountDir

    try {
        Write-Step "Applying CU with DISM (slow; can take 30-60+ min)..."
        # DISM native call gives progress output vs. silent Add-WindowsPackage
        & dism.exe /Image:$MountDir /Add-Package /PackagePath:$CuPath
        if ($LASTEXITCODE -ne 0) { throw "DISM /Add-Package failed with exit code $LASTEXITCODE." }

        Write-Step "Cleaning up component store..."
        & dism.exe /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase
        # ResetBase can return 0x800f0806 harmlessly on some images; don't hard-fail
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Component cleanup returned exit code $LASTEXITCODE (continuing)."
        }

        Write-Step "Committing and dismounting..."
        Dismount-WindowsImage -Path $MountDir -Save
    }
    catch {
        Write-Warning "Servicing failed: $_"
        Write-Step "Discarding mount..."
        Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue
        throw
    }
}

# ------------------------------------------------------------------
# 6. Rebuild a bootable ISO with oscdimg
# ------------------------------------------------------------------
function New-BootableIso {
    param([string]$OutIsoPath)

    if (-not (Test-Path $OscdimgPath)) {
        throw "oscdimg.exe not found at $OscdimgPath. Install the ADK Deployment Tools."
    }

    $etfsboot = Join-Path $ExtractDir "boot\etfsboot.com"
    $efisys   = Join-Path $ExtractDir "efi\microsoft\boot\efisys.bin"
    if (-not (Test-Path $efisys)) { throw "efisys.bin not found; ISO layout unexpected." }

    Write-Step "Building bootable ISO -> $OutIsoPath ..."
    # Dual BIOS+UEFI boot. -m: no size limit, -o: dedupe, -u2: UDF, -udfver102
    $bootData = "2#p0,e,b`"$etfsboot`"#pEF,e,b`"$efisys`""
    & $OscdimgPath -bootdata:$bootData -m -o -u2 -udfver102 $ExtractDir $OutIsoPath
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE." }

    Write-Host "ISO created: $OutIsoPath ($([math]::Round((Get-Item $OutIsoPath).Length / 1GB, 2)) GB)"
}

# ==================================================================
# MAIN
# ==================================================================
$stamp   = Get-Date -Format "yyyy-MM-dd"
$isoName = "Windows11_${WinRelease}_${Edition}_${Arch}_${stamp}.iso"
$outIso  = Join-Path $OutputDir $isoName

$cu = Get-LatestCumulativeUpdate          # fail fast before the big ISO download
$isoPath = Get-WindowsIso
Expand-Iso -IsoPath $isoPath
$wim = Resolve-InstallWim
Add-CuToWim -WimPath $wim -CuPath $cu.Path
New-BootableIso -OutIsoPath $outIso

# ------------------------------------------------------------------
# Emit output variables for whichever CI system is driving this
# ------------------------------------------------------------------
function Set-CiOutput {
    param([string]$Name, [string]$Value)

    switch ($CiSystem) {
        "githubactions" {
            # snake_case keys, referenced as steps.<id>.outputs.<name>
            "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
        "azuredevops" {
            # isOutput=true so it's reachable as $(<stepName>.<name>)
            Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
        }
        "none" {
            Write-Host "[output] $Name = $Value"
        }
    }
}

# NOTE: GitHub uses snake_case, Azure DevOps YAML above expects camelCase.
# Emit both spellings so one script serves both pipelines.
Set-CiOutput -Name "iso_path"  -Value $outIso
Set-CiOutput -Name "iso_name"  -Value $isoName
Set-CiOutput -Name "cu_kb"     -Value $cu.KB
Set-CiOutput -Name "cu_title"  -Value $cu.Title

Set-CiOutput -Name "isoPath"   -Value $outIso
Set-CiOutput -Name "isoName"   -Value $isoName
Set-CiOutput -Name "cuKb"      -Value $cu.KB
Set-CiOutput -Name "cuTitle"   -Value $cu.Title

Write-Host "`nDone. Output ISO: $outIso" -ForegroundColor Green
