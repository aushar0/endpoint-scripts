<#
.SYNOPSIS
    Audits why Windows 365 Cloud PCs are missing from an Autopilot dynamic
    device group.

.DESCRIPTION
    Pages all Entra ID device objects, isolates Windows 365 Cloud PCs by
    model, and joins them against the direct membership of a named group.
    For every Cloud PC it reports whether the [ZTDId] stamp exists in
    physicalIds, the join type, and the enrollment profile name - the three
    attributes that narrow each missing device to a ranked cause:

      1. Provisioning-path split (no ZTDID on objects provisioned by a
         different/older policy or via hybrid join; never backfilled)
      2. Autopilot device preparation path (groups via assigned group /
         enrollmentProfileName, not ZTDID)
      3. Compound rule clause (ZTDID present but an extra condition fails)
      4. Dynamic-group processing lag (resolves within about a day)

    It also prints provisioning-date ranges for the in-group and missing
    cohorts and flags a clean before/after boundary - the signature of a
    change event (provisioning policy created/edited, or Autopilot device
    preparation adoption) rather than an old standing gap.

    Read-only: makes no changes to any object. Tested status: parse-checked
    on Windows PowerShell 5.1 and logic-tested end-to-end against mocked
    Graph responses; live-tenant execution pending - review the output
    before acting on it.

    Requires the Microsoft.Graph.Authentication module. Consented scopes:
    Device.Read.All, Group.Read.All.

.PARAMETER GroupName
    Display name of the dynamic device group to audit.

.PARAMETER CsvPath
    Optional path to write the full per-device result table as CSV.

.EXAMPLE
    .\Find-CloudPcAutopilotGroupGaps.ps1 -GroupName "Autopilot Devices" -CsvPath .\gaps.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GroupName,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "The Microsoft.Graph.Authentication module is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication

Connect-MgGraph -Scopes Device.Read.All, Group.Read.All -NoWelcome

# --- Resolve the target group (exact display-name match)
$GroupNameEscaped = $GroupName -replace "'", "''"
$groupFilter = [uri]::EscapeDataString("displayName eq '$GroupNameEscaped'")
$groups = Invoke-MgGraphRequest -Method GET -Uri `
    "https://graph.microsoft.com/v1.0/groups?`$filter=$groupFilter&`$select=id,displayName,membershipRule,membershipRuleProcessingState"

if (-not $groups.value -or $groups.value.Count -eq 0) {
    throw "No group found with displayName '$GroupName'."
}
if ($groups.value.Count -gt 1) {
    $dupes = ($groups.value | ForEach-Object { $_.id }) -join ', '
    throw "Multiple groups named '$GroupName' exist ($dupes). Disambiguate first."
}
$group = $groups.value[0]

Write-Host ""
Write-Host "Group: $($group.displayName) ($($group.id))" -ForegroundColor Cyan
if ($group.membershipRule) {
    Write-Host "Rule:  $($group.membershipRule)"
}

# --- Group members (device objects only)
$memberIds = New-Object 'System.Collections.Generic.HashSet[string]'
try {
    $members = Invoke-MgGraphRequest -Method GET -All -Uri `
        "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/microsoft.graph.device?`$select=id"
}
catch {
    # OData cast unavailable (rare service hiccup): fall back to plain members
    $members = Invoke-MgGraphRequest -Method GET -All -Uri `
        "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$select=id,@odata.type" |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' }
}
foreach ($m in @($members)) { if ($m -and $m.id) { [void]$memberIds.Add($m.id) } }
Write-Host "Direct members (device objects): $($memberIds.Count)"

# --- All devices; isolate Cloud PCs per the documented model recipe
$devices = Invoke-MgGraphRequest -Method GET -All -Uri `
    "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,model,trustType,enrollmentProfileName,physicalIds,createdDateTime"

$cloudPcs = @($devices | Where-Object {
        ($_.model -and $_.model.StartsWith('Cloud PC', [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($_.model -and $_.model.StartsWith('Windows 365', [System.StringComparison]::OrdinalIgnoreCase))
    })

Write-Host "Cloud PCs found in tenant:          $($cloudPcs.Count)"
Write-Host ""

if ($cloudPcs.Count -eq 0) {
    Write-Warning "No Cloud PCs isolated by model. Check that model values begin with 'Cloud PC' or 'Windows 365'."
    return
}

# --- Per-device audit row
$rows = foreach ($d in $cloudPcs) {
    $physicalIds = @($d.physicalIds)
    $hasZtdid = $false
    foreach ($physId in $physicalIds) {
        if ($physId -and $physId.StartsWith('[ZTDId]:', [System.StringComparison]::OrdinalIgnoreCase)) {
            $hasZtdid = $true
            break
        }
    }
    [PSCustomObject]@{
        DisplayName       = $d.displayName
        Model             = $d.model
        JoinType          = $d.trustType
        EnrollmentProfile = $d.enrollmentProfileName
        Created           = $d.createdDateTime
        HasZtdid          = $hasZtdid
        InGroup           = $memberIds.Contains($d.id)
    }
}

# --- Summary clusters mapped to causes
$missing = @($rows | Where-Object { -not $_.InGroup })
$present = @($rows | Where-Object { $_.InGroup })

$clusterNoZtdid  = @($missing | Where-Object { -not $_.HasZtdid })
$clusterWithZtdid = @($missing | Where-Object { $_.HasZtdid })

Write-Host "==================== SUMMARY ====================" -ForegroundColor Cyan
Write-Host ("In group: {0}   Missing: {1}" -f $present.Count, $missing.Count)
Write-Host ""
Write-Host "Missing WITHOUT a ZTDID stamp: $($clusterNoZtdid.Count)  -> cause 1 (provisioning path / hybrid) or 2 (device preparation)"
if ($clusterNoZtdid.Count -gt 0) {
    $hybrid = @($clusterNoZtdid | Where-Object { $_.JoinType -eq 'ServerAd' })
    $byProfile = $clusterNoZtdid | Group-Object EnrollmentProfile | Sort-Object Count -Descending
    Write-Host "  of which hybrid-joined (trustType ServerAd): $($hybrid.Count)"
    Write-Host "  enrollment profiles among the missing:"
    foreach ($p in $byProfile) {
        Write-Host ("    {0,-40} {1}" -f ($p.Name -replace '^$', '(none)'), $p.Count)
    }
    Write-Host "  -> profiles named after device-preparation policies point at cause 2;"
    Write-Host "     a clean split by provisioning policy or by provisioned-before date points at cause 1."
}
Write-Host ""
Write-Host "Missing WITH a ZTDID stamp:   $($clusterWithZtdid.Count)  -> cause 3 (extra rule clause) or 4 (processing lag, resolves within about a day)"
if ($clusterWithZtdid.Count -gt 0) {
    Write-Host "  re-read the membership rule above for an 'and' clause these devices fail."
}

# --- Cohort dating: did membership split cleanly at a point in time?
$presentDates = @($present | Where-Object { $_.Created } | ForEach-Object { [datetime]$_.Created })
$missingDates = @($missing | Where-Object { $_.Created } | ForEach-Object { [datetime]$_.Created })
Write-Host ""
Write-Host "==================== COHORT TIMING ====================" -ForegroundColor Cyan
if ($presentDates.Count -gt 0) {
    Write-Host ("In-group Cloud PCs provisioned: {0:yyyy-MM-dd} to {1:yyyy-MM-dd}" -f ($presentDates | Measure-Object -Minimum -Maximum).Minimum, ($presentDates | Measure-Object -Minimum -Maximum).Maximum)
}
if ($missingDates.Count -gt 0) {
    Write-Host ("Missing Cloud PCs provisioned:  {0:yyyy-MM-dd} to {1:yyyy-MM-dd}" -f ($missingDates | Measure-Object -Minimum -Maximum).Minimum, ($missingDates | Measure-Object -Minimum -Maximum).Maximum)
    $maxPresent = ($presentDates | Measure-Object -Maximum).Maximum
    $minMissing = ($missingDates | Measure-Object -Minimum).Minimum
    if ($presentDates.Count -gt 0 -and $maxPresent -lt $minMissing) {
        Write-Host ""
        Write-Host ("CLEAN TEMPORARY BOUNDARY: every in-group Cloud PC predates {0:yyyy-MM-dd}, every missing one postdates it." -f $minMissing) -ForegroundColor Yellow
        Write-Host "  Points at a change event (provisioning policy created/edited, or device-preparation adoption)."
        Write-Host "  Check Intune audit logs for provisioning-policy changes around that date."
    } else {
        Write-Host "  No clean date boundary; the split follows another attribute (profile, join type) rather than time."
    }
}

# --- Detail table of everything missing
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "==================== MISSING DETAIL ====================" -ForegroundColor Cyan
    $missing |
        Sort-Object @{ Expression = 'HasZtdid'; Descending = $true }, DisplayName |
        Format-Table DisplayName, JoinType, EnrollmentProfile, Created, HasZtdid, @{ Label = 'InGroup'; Expression = { $_.InGroup } } -AutoSize |
        Out-String -Width 220 | Write-Host
}

if ($CsvPath) {
    $rows | Sort-Object InGroup, DisplayName | Export-Csv -Path $CsvPath -NoTypeInformation
    Write-Host "Full per-device table written to $CsvPath"
}
