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
# Large-file downloader.
#
# Ordered for a CI runner (fat pipe, no competing traffic, no user session):
#
#   1. aria2c  - parallel range requests (-x16). Neither BITS nor curl splits a
#                SINGLE file across connections; aria2c does, and MS's CDN
#                supports ranges. This is the big win: often 5-10x.
#   2. curl.exe- in System32 on Server 2019+. Single-stream but solid, resumes,
#                no service dependency.
#   3. BITS    - deliberately POLITE (throttles, yields to other traffic), which
#                is worthless on a dedicated runner. Worse, it's a service that
#                expects a user session and can PARK A JOB indefinitely in a
#                non-interactive context. Wrapped in a hard timeout below so a
#                stuck job can't eat the whole 360-min budget.
#   4. IWR     - last resort. $ProgressPreference off; rendering the progress
#                bar dominates the transfer on multi-GB files (minutes vs hours).
# ------------------------------------------------------------------
function Get-LargeFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Description = "file",
        [int]$BitsTimeoutMinutes = 20
    )

    # ---------------------------------------------------------------------
    # NOTE: every native command below ends in `2>&1 | Out-Host`. That is
    # LOAD-BEARING, not cosmetic.
    #
    # A native exe's stdout goes to PowerShell's SUCCESS STREAM. Un-redirected,
    # every line aria2c/curl prints becomes part of THIS FUNCTION'S OUTPUT. A
    # caller doing `Get-LargeFile ...; return $path` then returns an ARRAY of
    # [downloader chatter..., path]. Pass that to a [string] parameter and
    # PowerShell silently joins it with spaces -> a garbage path, and downstream
    # tools report a baffling "cannot find the file specified" for a file you
    # can plainly see on disk.
    #
    # Out-Host writes to the console (still visible in CI logs) while emitting
    # NOTHING to the pipeline. Do not "simplify" it away.
    # ---------------------------------------------------------------------

    $sw = [Diagnostics.Stopwatch]::StartNew()

    function Report($tool) {
        $sw.Stop()
        $gb = (Get-Item $OutFile).Length / 1GB
        $mbps = if ($sw.Elapsed.TotalSeconds -gt 0) {
            ($gb * 1024) / $sw.Elapsed.TotalSeconds
        } else { 0 }
        Write-Host ("{0}: {1:N2} GB in {2:N1} min ({3:N1} MB/s)" -f `
            $tool, $gb, $sw.Elapsed.TotalMinutes, $mbps) -ForegroundColor Green
    }

    function Clear-Partial {
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        # aria2c leaves a .aria2 control file behind on failure
        if (Test-Path "$OutFile.aria2") { Remove-Item "$OutFile.aria2" -Force -ErrorAction SilentlyContinue }
    }

    # --- 1. aria2c (parallel) ---
    $aria = Get-Command aria2c.exe -ErrorAction SilentlyContinue
    if ($aria) {
        Write-Host "Downloading $Description via aria2c (16 connections)..."
        $dir  = Split-Path $OutFile -Parent
        $file = Split-Path $OutFile -Leaf
        & $aria.Source `
            -x16 -s16 -k 10M `
            --max-tries=5 --retry-wait=5 `
            --file-allocation=falloc `
            --console-log-level=warn --summary-interval=30 `
            --allow-overwrite=true --auto-file-renaming=false `
            -d $dir -o $file $Uri 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) { Report "aria2c"; return }
        Write-Warning "aria2c exited $LASTEXITCODE. Falling back to curl.exe."
        Clear-Partial
    }

    # --- 2. curl.exe ---
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (Test-Path $curl) {
        Write-Host "Downloading $Description via curl.exe..."
        & $curl -L --fail --retry 3 --retry-delay 5 --retry-all-errors `
            -C - -o $OutFile $Uri 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) { Report "curl"; return }
        Write-Warning "curl.exe exited $LASTEXITCODE. Falling back to BITS."
        Clear-Partial
    }

    # --- 3. BITS (with a hang guard) ---
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $svc = Get-Service -Name BITS -ErrorAction Stop
        if ($svc.Status -ne 'Running') { Start-Service -Name BITS -ErrorAction Stop }

        Write-Host "Downloading $Description via BITS (timeout ${BitsTimeoutMinutes}m)..."

        # -Asynchronous so we can poll. A synchronous Start-BitsTransfer that
        # parks in a non-interactive session would block forever.
        $job = Start-BitsTransfer -Source $Uri -Destination $OutFile `
            -Priority Foreground -Asynchronous -ErrorAction Stop

        $deadline = (Get-Date).AddMinutes($BitsTimeoutMinutes)
        while ($job.JobState -in @('Connecting','Transferring','Queued','TransientError')) {
            if ((Get-Date) -gt $deadline) {
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                throw "BITS exceeded ${BitsTimeoutMinutes} min (state: $($job.JobState)) - likely stalled."
            }
            Start-Sleep -Seconds 5
            $job = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
        }

        if ($job.JobState -ne 'Transferred') {
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            throw "BITS ended in state '$($job.JobState)'."
        }

        Complete-BitsTransfer -BitsJob $job
        Report "BITS"
        return
    }
    catch {
        Write-Warning "BITS failed: $($_.Exception.Message)"
        Write-Warning "Falling back to Invoke-WebRequest."
        Clear-Partial
    }

    # --- 4. Invoke-WebRequest (last resort) ---
    Write-Host "Downloading $Description via Invoke-WebRequest..."
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # <-- do not remove; see header
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    }
    finally {
        $ProgressPreference = $prevProgress
    }
    Report "IWR"
}

# ------------------------------------------------------------------
# 1. Download the Windows ISO using Fido
# ------------------------------------------------------------------
function Get-WindowsIso {
    Write-Step "Requesting ISO download URL from Fido ($WinRelease $Edition $Arch)..."

    # Fido runs in a SEPARATE PowerShell process. Two reasons, both real:
    #
    # 1. StrictMode. This script sets `Set-StrictMode -Version Latest`, and
    #    strict mode is INHERITED by child scopes. Fido is not strict-mode-safe:
    #    on the happy path it evaluates `if ($r.Errors)` against a response
    #    object that legitimately HAS no Errors property. Normally that yields
    #    $null; under strict mode it is a terminating error --
    #      "The property 'Errors' cannot be found on this object"
    #    -- so Fido would blow up precisely BECAUSE Microsoft answered correctly.
    #
    # 2. Fido calls `exit` on several paths. A separate process keeps that from
    #    tearing down this script.
    $fidoArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $FidoPath,
        '-Win',  '11',
        '-Rel',  $WinRelease,
        '-Ed',   $Edition,
        '-Lang', $Language,
        '-Arch', $Arch,
        '-GetUrl'
    )

    $output = & powershell.exe @fidoArgs 2>&1
    $fidoExit = $LASTEXITCODE

    # Fido prints chatter alongside the URL; take the last thing that IS a URL.
    $url = $output |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object   { $_ -match '^https?://' } |
        Select-Object  -Last 1

    if (-not $url) {
        Write-Warning "Fido exit code: $fidoExit"
        Write-Warning "Fido output:"
        $output | ForEach-Object { Write-Warning "  $_" }
        # If the dump above mentions a ban / message code 715-123130, Microsoft
        # has blocked this runner's IP -- see README, 'When Fido gets blocked'.
        throw "Fido did not return a download URL."
    }

    Write-Host "ISO URL: $url"

    $isoPath = Join-Path $IsoDownloadDir "windows.iso"
    Write-Step "Downloading ISO (several GB)..."
    Get-LargeFile -Uri $url -OutFile $isoPath -Description "Windows ISO"
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
    Get-LargeFile -Uri $downloadUrl -OutFile $filePath -Description $kbNumber
    Write-Host "Saved to $filePath"

    return [pscustomobject]@{ Path = $filePath; KB = $kbNumber; Title = $updateTitle }
}

# ------------------------------------------------------------------
# 3. Extract ISO contents to a writable folder
# ------------------------------------------------------------------
function Expand-Iso {
    param([string]$IsoPath)

    # Guard: if a caller ever leaks native-command output into a return value
    # again, $IsoPath arrives as space-joined garbage. Catch it HERE, loudly,
    # instead of letting 7-Zip or Mount-DiskImage report an inscrutable
    # "cannot find the file specified" about a file that obviously exists.
    if ([string]::IsNullOrWhiteSpace($IsoPath) -or
        -not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Expand-Iso got a bad ISO path. Received: '$IsoPath'"
    }

    # Prefer 7-Zip over Mount-DiskImage.
    #
    # Mount-DiskImage is fragile on a CI runner: it depends on the Virtual Disk
    # service, needs a free drive letter to hand out, and refuses SPARSE files.
    # A 16-connection aria2c download writes out of order, which on NTFS can
    # produce exactly that -- and the mount then fails with
    #   HRESULT 0x80070003  "The system cannot find the path specified"
    # on a file you can plainly see on disk. Deeply unhelpful error.
    #
    # 7z reads the ISO as an archive: no service, no drive letter, sparse is
    # irrelevant. It's also ONE pass, vs mount -> copy every file -> dismount.
    $7zPath = $null
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $7zPath = $cmd.Source
    } elseif (Test-Path "C:\Program Files\7-Zip\7z.exe") {
        $7zPath = "C:\Program Files\7-Zip\7z.exe"
    }

    if ($7zPath) {
        Write-Step "Extracting ISO with 7-Zip -> $ExtractDir ..."
        # -y assume yes, -bso0/-bsp0 silence per-file and progress spam
        & $7zPath x $IsoPath "-o$ExtractDir" -y -bso0 -bsp0 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed (exit $LASTEXITCODE)." }
    }
    else {
        Write-Warning "7-Zip not found; falling back to Mount-DiskImage."
        Write-Step "Mounting ISO..."
        $mount     = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $volume    = ($mount | Get-Volume).DriveLetter
        $driveRoot = "${volume}:\"

        Write-Step "Copying ISO contents to $ExtractDir ..."
        Copy-Item -Path (Join-Path $driveRoot '*') -Destination $ExtractDir -Recurse -Force

        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }

    # Files off an ISO come out read-only. DISM and oscdimg need to write here.
    Get-ChildItem -Path $ExtractDir -Recurse -File |
        ForEach-Object { $_.Attributes = 'Normal' }

    # Fail here, not 40 minutes deep in DISM, if the extract went sideways.
    $sourcesDir = Join-Path $ExtractDir "sources"
    if (-not (Test-Path $sourcesDir)) {
        throw "Extraction produced no 'sources' folder -- ISO layout unexpected or extract failed."
    }

    # Free ~8 GB immediately -- the disk budget is tight.
    Remove-Item $IsoPath -Force

    $count = (Get-ChildItem -Path $ExtractDir -Recurse -File).Count
    Write-Host "Extraction complete: $count files. Raw ISO removed."
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
# Language MUST be in the filename. Without it, an English and a Dutch build
# produce the same name -> the same blob key -> the second silently overwrites
# the first. (Fido uses "English"/"Dutch"; keep it short and path-safe here.)
$langTag = ($Language -replace '[^A-Za-z0-9]', '')
$isoName = "Windows11_${WinRelease}_${Edition}_${langTag}_${Arch}_${stamp}.iso"
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
