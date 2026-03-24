param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$DashboardUrl = "http://127.0.0.1:4040",

    [int]$TimeoutSeconds = 90,

    [switch]$InjectProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) { return }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()

        if (-not $name) { return }
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, "Process"))) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Require-Env {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required environment variable: $Name"
    }
    return $value
}

function New-SupabaseHeaders {
    param([string]$ApiKey)

    $headers = @{
        apikey = $ApiKey
        Prefer = "return=representation"
    }

    # sb_secret/sb_publishable keys must not be used as Bearer tokens.
    if ($ApiKey -notmatch '^sb_') {
        $headers.Authorization = "Bearer $ApiKey"
    }

    return $headers
}

function Invoke-SupabaseGet {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$PathAndQuery
    )

    $uri = "$SupabaseUrl/rest/v1/$PathAndQuery"
    return Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
}

function Invoke-SupabasePost {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$Table,
        [object]$Body
    )

    $uri = "$SupabaseUrl/rest/v1/$Table"
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers -ContentType "application/json" -Body $json
}

function Get-CandidateTrackerItems {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$TenantId
    )

    $query = "tracker_work_items_v1?select=tracker_item_id,tracker_identifier,title,state,assigned_to_worker,updated_at&tenant_id=eq.$TenantId&state=in.(planned,in_progress,review)&order=updated_at.desc&limit=25"
    return Invoke-SupabaseGet -SupabaseUrl $SupabaseUrl -Headers $Headers -PathAndQuery $query
}

function Get-DashboardState {
    param([string]$DashboardUrl)

    $uri = "$DashboardUrl/api/v1/state"
    return Invoke-RestMethod -Method Get -Uri $uri
}

function Get-ProbeContext {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$TenantId
    )

    $loopItems = Invoke-SupabaseGet -SupabaseUrl $SupabaseUrl -Headers $Headers -PathAndQuery "loop_items?select=id,roadmap_item_id,tenant_id,updated_at&tenant_id=eq.$TenantId&roadmap_item_id=not.is.null&order=updated_at.desc&limit=1"
    if (-not $loopItems -or $loopItems.Count -eq 0) {
        throw "No loop_items row found with roadmap_item_id for tenant $TenantId"
    }

    $loop = $loopItems[0]

    $roadmap = Invoke-SupabaseGet -SupabaseUrl $SupabaseUrl -Headers $Headers -PathAndQuery "roadmap_items?select=id,title,status,updated_at&tenant_id=eq.$TenantId&id=eq.$($loop.roadmap_item_id)&limit=1"
    if (-not $roadmap -or $roadmap.Count -eq 0) {
        throw "Could not resolve roadmap item $($loop.roadmap_item_id) for loop $($loop.id)"
    }

    return @{
        loop = $loop
        roadmap = $roadmap[0]
    }
}

function Insert-ProbeRun {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$TenantId,
        [string]$RoadmapItemId,
        [string]$LoopItemId
    )

    $now = [DateTime]::UtcNow.ToString("o")
    $body = @{
        tenant_id = $TenantId
        roadmap_item_id = $RoadmapItemId
        loop_item_id = $LoopItemId
        external_system = "symphony"
        status = "queued"
        execution_phase = "planned"
        summary = "Synthetic polling probe run"
        metadata = @{
            source = "symphony_polling_probe"
            agent_provider = "codex"
            attempt_count = 1
        }
        started_at = $now
        updated_at = $now
    }

    $rows = Invoke-SupabasePost -SupabaseUrl $SupabaseUrl -Headers $Headers -Table "orchestration_runs" -Body $body
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Failed to insert probe orchestration_runs row"
    }

    return $rows[0]
}

function Get-Run {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$TenantId,
        [string]$RunId
    )

    $rows = Invoke-SupabaseGet -SupabaseUrl $SupabaseUrl -Headers $Headers -PathAndQuery "orchestration_runs?select=id,status,execution_phase,summary,updated_at,metadata&tenant_id=eq.$TenantId&id=eq.$RunId&limit=1"
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Run not found after insert: $RunId"
    }

    return $rows[0]
}

function Get-Transitions {
    param(
        [string]$SupabaseUrl,
        [hashtable]$Headers,
        [string]$TenantId,
        [string]$RunId
    )

    return Invoke-SupabaseGet -SupabaseUrl $SupabaseUrl -Headers $Headers -PathAndQuery "orchestration_transitions?select=id,transition_type,from_status,to_status,created_at&tenant_id=eq.$TenantId&run_id=eq.$RunId&order=created_at.asc&limit=30"
}

# Prefer local .env when process vars are not already set.
$dotEnvPath = Join-Path $PSScriptRoot "..\.env"
Load-DotEnv -Path $dotEnvPath

$supabaseUrl = [Environment]::GetEnvironmentVariable("SUPABASE_URL", "Process")
if ([string]::IsNullOrWhiteSpace($supabaseUrl)) {
    $supabaseUrl = [Environment]::GetEnvironmentVariable("NEXT_PUBLIC_SUPABASE_URL", "Process")
}
if ([string]::IsNullOrWhiteSpace($supabaseUrl)) {
    throw "Missing SUPABASE_URL (or NEXT_PUBLIC_SUPABASE_URL)"
}

$supabaseKey = [Environment]::GetEnvironmentVariable("SUPABASE_SECRET_KEY", "Process")
if ([string]::IsNullOrWhiteSpace($supabaseKey)) {
    $supabaseKey = [Environment]::GetEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY", "Process")
}
if ([string]::IsNullOrWhiteSpace($supabaseKey)) {
    throw "Missing SUPABASE_SECRET_KEY (or SUPABASE_SERVICE_ROLE_KEY)"
}

$headers = New-SupabaseHeaders -ApiKey $supabaseKey

Write-Section "Symphony Dashboard"
try {
    $state = Get-DashboardState -DashboardUrl $DashboardUrl
    $active = if ($state.PSObject.Properties.Name -contains 'running' -and $state.running) { $state.running.Count } else { 0 }
    $queuedRetries = if ($state.PSObject.Properties.Name -contains 'backoff_queue' -and $state.backoff_queue) { $state.backoff_queue.Count } else { 0 }
    Write-Host "Dashboard reachable: yes"
    Write-Host "Active agents: $active"
    Write-Host "Backoff queue: $queuedRetries"
} catch {
    Write-Host "Dashboard reachable: no ($($_.Exception.Message))" -ForegroundColor Yellow
}

Write-Section "Tracker Candidates"
$candidates = Get-CandidateTrackerItems -SupabaseUrl $supabaseUrl -Headers $headers -TenantId $TenantId
$candidateCount = if ($candidates) { $candidates.Count } else { 0 }
Write-Host "Eligible tracker rows (planned/in_progress/review): $candidateCount"
if ($candidateCount -gt 0) {
    $candidates | Select-Object -First 10 tracker_identifier, state, title, assigned_to_worker, updated_at | Format-Table
} else {
    Write-Host "No candidate rows available for polling right now." -ForegroundColor Yellow
}

if (-not $InjectProbe) {
    Write-Section "Result"
    Write-Host "Read-only check complete. Re-run with -InjectProbe to enqueue a synthetic run and watch pickup."
    exit 0
}

Write-Section "Inject Probe Run"
$ctx = Get-ProbeContext -SupabaseUrl $supabaseUrl -Headers $headers -TenantId $TenantId
Write-Host "Using roadmap item: $($ctx.roadmap.id) ($($ctx.roadmap.title))"
Write-Host "Using loop item: $($ctx.loop.id)"

$probe = Insert-ProbeRun -SupabaseUrl $supabaseUrl -Headers $headers -TenantId $TenantId -RoadmapItemId $ctx.roadmap.id -LoopItemId $ctx.loop.id
$probeId = $probe.id
Write-Host "Inserted probe run: $probeId"

Write-Section "Wait For Pickup"
$start = Get-Date
$deadline = $start.AddSeconds($TimeoutSeconds)
$lastStatus = "queued"

while ((Get-Date) -lt $deadline) {
    $run = Get-Run -SupabaseUrl $supabaseUrl -Headers $headers -TenantId $TenantId -RunId $probeId
    $lastStatus = $run.status
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] run status: $($run.status) | phase: $($run.execution_phase)"

    if ($run.status -ne "queued") {
        break
    }

    Start-Sleep -Seconds 3
}

$transitions = Get-Transitions -SupabaseUrl $supabaseUrl -Headers $headers -TenantId $TenantId -RunId $probeId
$transitionCount = if ($transitions) { $transitions.Count } else { 0 }

Write-Section "Probe Summary"
Write-Host "Run ID: $probeId"
Write-Host "Final observed status: $lastStatus"
Write-Host "Transitions recorded: $transitionCount"

if ($transitionCount -gt 0) {
    $transitions | Select-Object transition_type, from_status, to_status, created_at | Format-Table
}

if ($lastStatus -eq "queued") {
    Write-Host "Probe stayed queued: Symphony did not pick it up within timeout." -ForegroundColor Yellow
    exit 2
}

Write-Host "Probe was picked up by Symphony (status moved off queued)." -ForegroundColor Green
exit 0
