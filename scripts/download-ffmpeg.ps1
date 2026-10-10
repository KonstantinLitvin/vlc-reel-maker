# PowerShell helper to download and install FFmpeg for VLC ReelMaker
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 (3072) and TLS 1.3 (12288) are enabled safely across all .NET versions
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$targetDir = "$env:APPDATA\vlc\bin"
if (!(Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$zipPath = "$env:TEMP\ffmpeg_download.zip"
$extractDir = "$env:TEMP\ffmpeg_extracted"

# Reliable download mirrors (GitHub Release CDN and primary source)
$urls = @(
    'https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
    'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
    'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
)

$downloaded = $false
$webClient = New-Object System.Net.WebClient
$webClient.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) VLC-ReelMaker')

foreach ($url in $urls) {
    try {
        Write-Host "Downloading FFmpeg from $url ..."
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        $webClient.DownloadFile($url, $zipPath)
        if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 1000000)) {
            $downloaded = $true
            Write-Host "[OK] Download completed successfully."
            break
        }
    } catch {
        Write-Warning "Download mirror failed: $($_.Exception.Message)"
    }
}

if (!$downloaded) {
    Write-Error "All FFmpeg download mirrors failed. Please check internet connection."
    exit 1
}

try {
    Write-Host "Extracting archive..."
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $ffmpegBin = Get-ChildItem -Path $extractDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
    if (!$ffmpegBin) {
        Write-Error "ffmpeg.exe was not found in the extracted archive."
        exit 1
    }

    Copy-Item $ffmpegBin.FullName -Destination "$targetDir\ffmpeg.exe" -Force
    Write-Host "[OK] FFmpeg installed successfully to: $targetDir\ffmpeg.exe"
} finally {
    # Cleanup temporary files
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
}
