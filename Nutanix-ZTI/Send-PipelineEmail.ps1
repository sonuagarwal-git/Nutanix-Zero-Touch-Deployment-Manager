#Requires -Version 7.0

<#
.SYNOPSIS
    Send a pipeline result email for a Nutanix ZTI deployment run.

.DESCRIPTION
    Reads SMTP settings from deploy-cluster-app\.env (SMTP_HOST, SMTP_PORT, SMTP_USER),
    builds an HTML email with a per-step status table, and sends it to the recipient
    configured in the cluster config file (notify.to / notify.cc fields).

    If SMTP_HOST is not set in .env, or no To address is configured in the cluster
    config, the script exits cleanly with an informational message and sends nothing.

    Run standalone to test SMTP delivery, or called automatically by Start-Pipeline.ps1.

.PARAMETER ClusterName
    Name of the cluster that was deployed (e.g. my-cluster).

.PARAMETER Status
    Overall pipeline result: SUCCESS or FAILED.

.PARAMETER FailedStep
    (Optional) Name of the step that failed. Omit for successful runs.

.PARAMETER Duration
    Human-readable total duration string, e.g. "42m 17s".

.PARAMETER LogFile
    (Optional) Full path to the unified run log. Attached as a link in the email footer.

.PARAMETER StepResults
    (Optional) Array of hashtables, one per step:
      @{ Step = 1; Name = 'Phoenix Boot'; Status = 'OK'; Duration = '2m 5s' }
    Status values: OK, FAILED*, SKIPPED*

.PARAMETER To
    Recipient email address. Read from notify.to in the cluster config JSON.
    If empty, email is skipped silently.

.EXAMPLE
    # Quick connectivity test — no step results
    .\Send-PipelineEmail.ps1 -ClusterName "NTXTEST-01" -Status "SUCCESS" -Duration "42m 17s"

.EXAMPLE
    # Test with dummy step table
    $steps = @(
        @{ Step=1; Name='Phoenix Boot';       Status='OK';           Duration='2m 05s' },
        @{ Step=2; Name='Phoenix Boot Check'; Status='OK';           Duration='12m 33s' },
        @{ Step=3; Name='Node Discovery';     Status='FAILED (exit 1)'; Duration='1m 02s' },
        @{ Step=4; Name='Image & Deploy';     Status='SKIPPED (pipeline aborted)'; Duration='n/a' }
    )
    .\Send-PipelineEmail.ps1 -ClusterName "NTXTEST-01" -Status "FAILED" `
        -FailedStep "Node Discovery" -Duration "15m 40s" -StepResults $steps
.NOTES
    Author: Sonu Agarwal
    Date: Apr 03, 2026
    Version: 1.0#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClusterName,

    [Parameter(Mandatory)]
    [ValidateSet('SUCCESS', 'FAILED')]
    [string]$Status,

    [Parameter()]
    [string]$FailedStep = '',

    [Parameter()]
    [string]$Duration = '',

    [Parameter()]
    [string]$LogFile = '',

    [Parameter()]
    [object[]]$StepResults = @(),

    # Recipient — set by Start-Pipeline.ps1 from the web session user.
    # Falls back to the current Windows username (without domain) if not provided.
    [Parameter()]
    [string]$To = '',

    # Who triggered the run — displayed in the email body (name or email).
    # When not set, derived from $To.
    [Parameter()]
    [string]$TriggeredBy = '',

    # Optional extra CC addresses (comma-separated).
    [Parameter()]
    [string]$Cc = '',

    # Pipeline start/end times (DateTime objects). Used to compute CET timestamps.
    [Parameter()]
    [datetime]$StartTime = [datetime]::MinValue,

    [Parameter()]
    [datetime]$EndTime = [datetime]::MinValue,

    [Parameter()]
    [string]$ClusterVip = '',

    [Parameter()]
    [int]$NodeCount = 0
)

#region ── Resolve SMTP settings from .env ────────────────────────────────────

# SMTP host/port/from are read from deploy-cluster-app\.env.
# To and CC come from the cluster config JSON via -To / -Cc parameters.
$envFile  = Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy-cluster-app\.env'
$smtpHost = ''
$smtpPort = 25
$fromAddr = 'noreply@localhost'

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*SMTP_HOST=(.+)$')  { $smtpHost = $Matches[1].Trim() }
        if ($_ -match '^\s*SMTP_PORT=(\d+)$') { $smtpPort = [int]$Matches[1] }
        if ($_ -match '^\s*SMTP_USER=(.+)$')  { $fromAddr = $Matches[1].Trim() }
    }
} else {
    Write-Host "  .env not found -- skipping email notification." -ForegroundColor DarkGray
    exit 0
}

if (-not $smtpHost) {
    Write-Host "  SMTP_HOST not configured in .env -- skipping email notification." -ForegroundColor DarkGray
    exit 0
}

# If no recipient configured in cluster config, skip silently
if (-not $To) {
    Write-Host "  No recipient configured (notify.to not set in cluster config) -- skipping email." -ForegroundColor DarkGray
    exit 0
}

# Derive display name for the email body
if (-not $TriggeredBy) { $TriggeredBy = $To }

# Build the CC list
$extraCc = if ($Cc) { $Cc -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
$allCc   = $extraCc | Select-Object -Unique

#endregion

#region ── Build HTML body ─────────────────────────────────────────────────────

$statusColor  = if ($Status -eq 'SUCCESS') { '#27ae60' } else { '#c0392b' }
$statusIcon   = if ($Status -eq 'SUCCESS') { '&#9989;' } else { '&#10060;' }
$statusLabel  = if ($Status -eq 'SUCCESS') { 'COMPLETED SUCCESSFULLY' } else { 'FAILED' }

# Use UTC timestamps — timezone-neutral for shared/open-source use.
# Override by configuring your local timezone in the .env if needed.
$nowUtc       = [datetime]::UtcNow
$runTimestamp = $nowUtc.ToString('yyyy-MM-dd HH:mm') + ' UTC'

$startTimeCet = if ($StartTime -ne [datetime]::MinValue) {
    $utc = if ($StartTime.Kind -eq [System.DateTimeKind]::Local) { $StartTime.ToUniversalTime() } else { $StartTime }
    $utc.ToString('yyyy-MM-dd HH:mm') + ' UTC'
} else { $runTimestamp }

$endTimeCet = if ($EndTime -ne [datetime]::MinValue) {
    $utc = if ($EndTime.Kind -eq [System.DateTimeKind]::Local) { $EndTime.ToUniversalTime() } else { $EndTime }
    $utc.ToString('yyyy-MM-dd HH:mm') + ' UTC'
} else { $runTimestamp }

# Per-step HTML rows
$stepRowsHtml = ''
if ($StepResults.Count -gt 0) {
    foreach ($r in $StepResults) {
        $rowColor = switch -Wildcard ($r.Status) {
            'OK'               { '#eafaf1' }
            'FAILED*'          { '#fdecea' }
            'SKIPPED*aborted*' { '#f9f9f9' }
            'SKIPPED*'         { '#fef9e7' }
            default            { '#ffffff' }
        }
        $statusCell = switch -Wildcard ($r.Status) {
            'OK'               { '<span style="color:#27ae60;font-weight:bold;">&#9989; OK</span>' }
            'FAILED*'          { "<span style='color:#c0392b;font-weight:bold;'>&#10060; $($r.Status)</span>" }
            'SKIPPED*aborted*' { "<span style='color:#7f8c8d;'>&#9866; $($r.Status)</span>" }
            'SKIPPED*'         { "<span style='color:#e67e22;'>&#9654; $($r.Status)</span>" }
            default            { $r.Status }
        }
        $stepRowsHtml += @"
        <tr style="background:$rowColor;">
          <td style="padding:6px 12px;border-bottom:1px solid #ddd;text-align:center;color:#555;">$($r.Step)</td>
          <td style="padding:6px 12px;border-bottom:1px solid #ddd;">$($r.Name)</td>
          <td style="padding:6px 12px;border-bottom:1px solid #ddd;text-align:center;">$($r.Duration)</td>
          <td style="padding:6px 12px;border-bottom:1px solid #ddd;">$statusCell</td>
        </tr>
"@
    }
} else {
    $stepRowsHtml = @"
        <tr>
          <td colspan="4" style="padding:12px;text-align:center;color:#888;font-style:italic;">
            No step details provided.
          </td>
        </tr>
"@
}

# Optional log file path footer
$logFooter = ''
if ($LogFile) {
    $logFooter = @"
    <p style="font-size:12px;color:#888;margin-top:16px;">
      &#128196; Log file: <code style="background:#f4f4f4;padding:2px 6px;border-radius:3px;">$LogFile</code>
    </p>
"@
}

# Optional failed-step callout
$failedCallout = ''
if ($Status -eq 'FAILED' -and $FailedStep) {
    $failedCallout = @"
    <div style="background:#fdecea;border-left:4px solid #c0392b;padding:10px 16px;margin:16px 0;border-radius:4px;">
      <strong>Failed at step:</strong> $FailedStep
    </div>
"@
}

$durationLine = if ($Duration) {
    "<p style='margin:4px 0;'><strong>Total duration:</strong> $Duration</p>"
} else { '' }

$vipRow     = if ($ClusterVip) { "<tr><td style='padding:2px 8px 2px 0;color:#888;white-space:nowrap;'>&#127760; Cluster VIP</td><td style='padding:2px 0;'><strong>$ClusterVip</strong></td></tr>" } else { '' }
$nodeRow    = if ($NodeCount -gt 0) { "<tr><td style='padding:2px 8px 2px 0;color:#888;white-space:nowrap;'>&#128421; Node count</td><td style='padding:2px 0;'><strong>$NodeCount</strong></td></tr>" } else { '' }

$initiatorBlock = @"
    <div style="background:#f8f9fa;border:1px solid #e0e0e0;border-radius:6px;padding:10px 14px;margin:12px 0;font-size:13px;">
      <table style="border-collapse:collapse;width:100%;">
        <tr>
          <td style="padding:2px 8px 2px 0;color:#888;white-space:nowrap;">&#128100; Initiated by</td>
          <td style="padding:2px 0;"><strong>$TriggeredBy</strong></td>
        </tr>
        <tr>
          <td style="padding:2px 8px 2px 0;color:#888;white-space:nowrap;">&#128197; Start time</td>
          <td style="padding:2px 0;">$startTimeCet</td>
        </tr>
        <tr>
          <td style="padding:2px 8px 2px 0;color:#888;white-space:nowrap;">&#128198; End time</td>
          <td style="padding:2px 0;">$endTimeCet</td>
        </tr>
        $vipRow
        $nodeRow
      </table>
    </div>
"@

$htmlBody = @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#333;margin:0;padding:0;background:#f6f6f6;">
  <div style="max-width:680px;margin:24px auto;background:#fff;border-radius:8px;
              box-shadow:0 2px 8px rgba(0,0,0,.12);overflow:hidden;">

    <!-- Header bar -->
    <div style="background:$statusColor;padding:20px 24px;color:#fff;">
      <h2 style="margin:0;font-size:20px;font-weight:600;">
        $statusIcon &nbsp; Nutanix ZTI Pipeline — $statusLabel
      </h2>
      <p style="margin:4px 0 0;font-size:13px;opacity:.88;">$runTimestamp</p>
    </div>

    <!-- Summary block -->
    <div style="padding:20px 24px 8px;">
      <p style="margin:4px 0;"><strong>Cluster:</strong> $ClusterName</p>
      $durationLine
      $initiatorBlock
      $failedCallout
    </div>

    <!-- Step table -->
    <div style="padding:0 24px 8px;">
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f0f0f0;">
            <th style="padding:8px 12px;border-bottom:2px solid #ccc;text-align:center;width:40px;">#</th>
            <th style="padding:8px 12px;border-bottom:2px solid #ccc;text-align:left;">Step</th>
            <th style="padding:8px 12px;border-bottom:2px solid #ccc;text-align:center;width:90px;">Duration</th>
            <th style="padding:8px 12px;border-bottom:2px solid #ccc;text-align:left;">Result</th>
          </tr>
        </thead>
        <tbody>
$stepRowsHtml        </tbody>
      </table>
    </div>

    <!-- Footer -->
    <div style="padding:12px 24px 20px;border-top:1px solid #eee;">
      $logFooter
      <p style="margin:12px 0 4px;">Best regards,<br>
        <strong>Nutanix ZTI Automation Team</strong>
      </p>
      <p style="font-size:11px;color:#aaa;margin-top:12px;">
        Sent automatically by Nutanix ZTI
      </p>
    </div>

  </div>
</body>
</html>
"@

#endregion

#region ── Send email ──────────────────────────────────────────────────────────

$subject = if ($Status -eq 'SUCCESS') {
    "[ZTI] $ClusterName — Pipeline completed successfully"
} else {
    "[ZTI] $ClusterName — Pipeline FAILED$(if ($FailedStep) { " at: $FailedStep" })"
}

Write-Host ""
Write-Host "  Sending pipeline result email..." -ForegroundColor Cyan
Write-Host "  From : $fromAddr"                 -ForegroundColor Gray
Write-Host "  To   : $To"                       -ForegroundColor Gray
Write-Host "  CC   : $($allCc -join ', ')"      -ForegroundColor Gray
Write-Host "  Via  : ${smtpHost}:${smtpPort}"   -ForegroundColor Gray
Write-Host "  Subj : $subject"                  -ForegroundColor Gray
Write-Host ""

try {
    $msg            = [System.Net.Mail.MailMessage]::new()
    $msg.From       = $fromAddr
    $msg.To.Add($To)
    foreach ($addr in $allCc) {
        $msg.CC.Add($addr)
    }
    $msg.Subject    = $subject
    $msg.Body       = $htmlBody
    $msg.IsBodyHtml = $true

    # Attach log file if it exists and is under 10 MB
    if ($LogFile -and (Test-Path $LogFile)) {
        $logSize = (Get-Item $LogFile).Length
        if ($logSize -le 10MB) {
            $attachment = [System.Net.Mail.Attachment]::new($LogFile, 'text/plain')
            $msg.Attachments.Add($attachment)
            Write-Host "  Attach: $(Split-Path $LogFile -Leaf) ($([math]::Round($logSize/1KB, 1)) KB)" -ForegroundColor Gray
        } else {
            Write-Host "  ⚠ Log file too large to attach ($([math]::Round($logSize/1MB, 1)) MB > 10 MB) — skipped." -ForegroundColor Yellow
        }
    }

    $client            = [System.Net.Mail.SmtpClient]::new($smtpHost, $smtpPort)
    $client.EnableSsl  = $false
    $client.Timeout    = 15000

    $client.Send($msg)
    $msg.Dispose()
    $client.Dispose()

    Write-Host "  ✓ Email sent successfully." -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "  ✗ Failed to send email: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    # Non-fatal — the pipeline result stands regardless
    exit 1
}

exit 0

#endregion
