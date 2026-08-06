<#
.SYNOPSIS
    Watches a folder inside the VM for arriving PDFs and prints each one to a
    named Windows printer via SumatraPDF.

.DESCRIPTION
    An alternative to winbridge-print.sh's push-per-job model, for when it is
    more convenient to drop files into the VM (the dockur/windows shared
    folder, a mapped drive, whatever) than to have the Linux host connect in
    for every print job. See docs/devices.md.

    Idempotent: a file is moved into .\processed immediately after it prints
    successfully, or into .\failed if SumatraPDF exits non-zero, so it is
    never picked up and printed twice — including across a restart of this
    script after a crash.

.PARAMETER WatchFolder
    Folder to poll for arriving *.pdf files. Created if missing, along with
    its processed\ and failed\ subfolders.

.PARAMETER Printer
    The Windows printer name to print to.

.PARAMETER SumatraPath
    Path to SumatraPDF.exe. Defaults to where setup-windows.ps1 -WithPrinting
    installs it.

.PARAMETER IntervalSeconds
    How often to poll the folder. Default 5.

.EXAMPLE
    .\print-vm-side.ps1 -WatchFolder C:\winbridge\print -Printer "Office Printer"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WatchFolder,

    [Parameter(Mandatory = $true)]
    [string]$Printer,

    [string]$SumatraPath = 'C:\tools\sumatra\SumatraPDF.exe',

    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SumatraPath)) {
    throw "SumatraPDF not found at $SumatraPath. Run setup-windows.ps1 -WithPrinting, or pass -SumatraPath explicitly."
}

$processedFolder = Join-Path $WatchFolder 'processed'
$failedFolder = Join-Path $WatchFolder 'failed'
New-Item -ItemType Directory -Path $WatchFolder -Force | Out-Null
New-Item -ItemType Directory -Path $processedFolder -Force | Out-Null
New-Item -ItemType Directory -Path $failedFolder -Force | Out-Null

# A destination name collision (two files named the same, printed on
# different days) gets a unique prefix rather than overwriting whatever is
# already in processed\ or failed\ — those folders are a record, not scratch
# space.
function Move-Unique([string]$Path, [string]$Destination) {
    $target = Join-Path $Destination (Split-Path -Leaf $Path)
    if (Test-Path $target) {
        $target = Join-Path $Destination "$([guid]::NewGuid())-$(Split-Path -Leaf $Path)"
    }
    Move-Item -Path $Path -Destination $target -Force
}

# A file mid-copy (e.g. still being written over the shared folder) is
# skipped this poll rather than printed half-finished: two size checks one
# beat apart, only proceed if the size held steady between them. This is not
# a real file lock, just a good-enough guard for the common case.
function Test-StableFile([System.IO.FileInfo]$File) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $File.FullName)) { return $false }
    $before = (Get-Item $File.FullName).Length
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $File.FullName)) { return $false }
    $after = (Get-Item $File.FullName).Length
    return $before -eq $after
}

Write-Host "Watching $WatchFolder for *.pdf, printing to '$Printer' every $IntervalSeconds s."
Write-Host 'Ctrl+C to stop.'

while ($true) {
    $files = Get-ChildItem -Path $WatchFolder -Filter '*.pdf' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (-not (Test-StableFile $file)) { continue }

        # $ErrorActionPreference is 'Stop', so without this a single file that
        # cannot be moved — still locked by whatever wrote it, a permissions
        # problem — would end the whole watcher. A print spooler that quietly
        # stopped watching is worse than one noisy job.
        try {
            Write-Host "Printing $($file.Name) to '$Printer'..."
            # Start-Process does NOT quote the elements of -ArgumentList: it
            # joins the array with single spaces into one command line. So
            # anything that can contain a space — a printer name like "Office
            # Printer", a path under C:\Users\Some Name\ — has to carry its own
            # quotes, or SumatraPDF sees it as two arguments and prints
            # nothing.
            $arguments = @(
                '-print-to'
                '"{0}"' -f $Printer
                '"{0}"' -f $file.FullName
                '-silent'
            )
            $process = Start-Process -FilePath $SumatraPath `
                -ArgumentList $arguments `
                -Wait -PassThru -NoNewWindow

            if ($process.ExitCode -eq 0) {
                Move-Unique $file.FullName $processedFolder
            } else {
                Write-Warning "SumatraPDF exited $($process.ExitCode) for $($file.Name)"
                Move-Unique $file.FullName $failedFolder
            }
        } catch {
            Write-Warning "skipping $($file.Name): $_"
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
