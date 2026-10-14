# scripts/sync_wiki.ps1 - Mirror local wiki/ directory to GitHub Wiki repository
$ErrorActionPreference = "Stop"

$repoWikiUrl = "https://github.com/Swapnil-2004/A3-PS023-TC301.wiki.git"
$tempDir = Join-Path $env:TEMP ("gh_wiki_" + [System.Guid]::NewGuid().ToString("N"))

Write-Host "==> Checking if GitHub Wiki repository is initialized..."
try {
    $remoteCheck = git ls-remote $repoWikiUrl 2>&1
    if ($LASTEXITCODE -ne 0 -or $remoteCheck -match "not found") {
        Write-Error @"
[!] GitHub Wiki repository is not yet initialized by GitHub.
GitHub requires you to create the initial page once in your browser before enabling git access:
👉 Visit: https://github.com/Swapnil-2004/A3-PS023-TC301/wiki/_new
Click 'Save Page' to initialize it, then re-run this script!
"@
        exit 1
    }
} catch {
    Write-Error "Failed to check remote wiki: $_"
    exit 1
}

Write-Host "==> Cloning wiki repository..."
git clone $repoWikiUrl $tempDir

Write-Host "==> Copying wiki pages..."
Copy-Item -Path "wiki\*" -Destination $tempDir -Recurse -Force

Write-Host "==> Committing and pushing to GitHub Wiki..."
Push-Location $tempDir
try {
    git add .
    $status = git status --porcelain
    if ($status) {
        git commit -m "docs(wiki): update wiki documentation pages from main repository"
        git push origin master
        Write-Host "==> SUCCESS: GitHub Wiki pages published successfully!" -ForegroundColor Green
    } else {
        Write-Host "==> GitHub Wiki is already up to date." -ForegroundColor Cyan
    }
} finally {
    Pop-Location
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
