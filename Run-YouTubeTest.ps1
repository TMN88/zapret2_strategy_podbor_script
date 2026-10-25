param(
    [Parameter(Mandatory=$true)][string]$Router,
    [string]$Section
)
$ErrorActionPreference = 'Stop'
if ($Router -notmatch '^[a-zA-Z0-9_.:@-]+$' -or $Router.StartsWith('-')) {
    throw 'Use a router IP, hostname or root@hostname.'
}
if ($Section -and $Section -notmatch '^[a-zA-Z0-9_]+$') {
    throw 'Invalid Podkop section name.'
}
$source = Join-Path $PSScriptRoot 'youtube-test.sh'
$bytes = [IO.File]::ReadAllBytes($source)
$encoded = [Convert]::ToBase64String($bytes)
$target = if ($Router.Contains('@')) { $Router } else { "root@$Router" }
$sectionEnv = if ($Section) { "PODKOP_SECTION='$Section' " } else { '' }
# Send through stdin: no script-size limit in the SSH command line.
# SSH host identity checks use the user's normal configuration.
$remote = 'set -eu; umask 077; d=$(mktemp -d /tmp/youtube-upload.XXXXXX); trap ''rm -f "$d/run.sh"; rmdir "$d"'' EXIT; base64 -d > "$d/run.sh"; ' + $sectionEnv + 'sh "$d/run.sh"'
$startOutput = $encoded | & ssh $target $remote
$startOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "Router refused the run (SSH exit $LASTEXITCODE)." }
$match = [regex]::Match(($startOutput -join "`n"), '/root/youtube-test/run-[0-9-]+')
if (-not $match.Success) { throw 'Run directory was not returned. Check router output.' }
$run = $match.Value
# Follow colored output; disconnecting this viewer does not stop the worker.
$follow = @'
tail -n +1 -f '{RUN}/run.log' & viewer=$!
trap 'kill "$viewer" 2>/dev/null || true' EXIT
trap 'exit 1' HUP INT TERM
while :; do
    state=$(cat '{RUN}/status' 2>/dev/null)
    case "$state" in
        SUCCESS) sleep 2; exit 0 ;;
        RESTORED|RECOVERY_FAILED|FAILED) sleep 2; exit 1 ;;
    esac
    sleep 2
done
'@
& ssh $target ($follow.Replace('{RUN}', $run).Replace("`r", ''))
if ($LASTEXITCODE -ne 0) {
    throw "Run or connection ended without SUCCESS. Check $run/status and $run/run.log."
}
