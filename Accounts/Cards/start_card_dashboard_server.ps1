param(
    [int]$Port = 8081,
    [string]$Root = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedRoot = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Root path not found: $resolvedRoot"
}

$defaultDocument = "Accounts/Cards/card_database.html"
$shutdownAt = $null

$mimeMap = @{
    ".html" = "text/html; charset=utf-8"
    ".htm" = "text/html; charset=utf-8"
    ".css" = "text/css; charset=utf-8"
    ".js" = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".csv" = "text/csv; charset=utf-8"
    ".txt" = "text/plain; charset=utf-8"
    ".xml" = "application/xml; charset=utf-8"
    ".png" = "image/png"
    ".jpg" = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"
    ".webp" = "image/webp"
    ".svg" = "image/svg+xml"
    ".ico" = "image/x-icon"
    ".woff" = "font/woff"
    ".woff2" = "font/woff2"
}

function Write-TextResponse {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$StatusCode,
        [string]$Body,
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Is-LocalRequest {
    param([Parameter(Mandatory = $true)]$Context)
    $remoteAddress = $Context.Request.RemoteEndPoint.Address.ToString()
    return $remoteAddress -eq "127.0.0.1" -or $remoteAddress -eq "::1"
}

function Resolve-RequestedPath {
    param([Parameter(Mandatory = $true)][string]$RawUrl)

    $requestPath = [Uri]::UnescapeDataString(($RawUrl -split "\?", 2)[0])
    if ([string]::IsNullOrWhiteSpace($requestPath) -or $requestPath -eq "/") {
        $requestPath = "/$defaultDocument"
    }

    $relativePath = $requestPath.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativePath))
    if (-not $candidate.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $candidate
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

Write-Host "Serving $resolvedRoot at http://localhost:$Port"

try {
    $shouldStop = $false
    while (-not $shouldStop) {
        $iar = $listener.BeginGetContext($null, $null)
        while (-not $iar.AsyncWaitHandle.WaitOne(200)) {
            if ($shutdownAt -and (Get-Date) -ge $shutdownAt) {
                $shouldStop = $true
                break
            }
        }

        if ($shouldStop) {
            break
        }

        $context = $listener.EndGetContext($iar)
        $request = $context.Request

        if ($request.Url.AbsolutePath -eq "/__dashboard/ping" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-TextResponse -Context $context -StatusCode 403 -Body "Local requests only"
                continue
            }
            $shutdownAt = $null
            $context.Response.StatusCode = 204
            $context.Response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/shutdown" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-TextResponse -Context $context -StatusCode 403 -Body "Local requests only"
                continue
            }
            $shutdownAt = (Get-Date).AddSeconds(3)
            Write-TextResponse -Context $context -StatusCode 202 -Body "shutdown scheduled"
            continue
        }

        if ($request.HttpMethod -ne "GET") {
            Write-TextResponse -Context $context -StatusCode 405 -Body "Method not allowed"
            continue
        }

        $resolved = Resolve-RequestedPath -RawUrl $request.RawUrl
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            Write-TextResponse -Context $context -StatusCode 404 -Body "Not found"
            continue
        }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($resolved)
            $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
            $contentType = if ($mimeMap.ContainsKey($extension)) { $mimeMap[$extension] } else { "application/octet-stream" }

            $response = $context.Response
            $response.StatusCode = 200
            $response.ContentType = $contentType
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.OutputStream.Close()
        }
        catch {
            Write-TextResponse -Context $context -StatusCode 500 -Body "Server error"
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
