# Resilient Graph HTTP helper: token refresh, throttling (429/503 + Retry-After), transient retries.

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [int]$MaxRetries = 8,
        [switch]$NoAuth,        # for pre-authenticated URLs (import session)
        [string]$BearerToken    # explicit token (setup uses delegated token)
    )

    if ($Uri -notmatch '^https://') { $Uri = $Context.GraphBase + '/' + $Uri.TrimStart('/') }
    $json = if ($null -ne $Body -and $Body -isnot [string]) { $Body | ConvertTo-Json -Depth 20 -Compress } else { $Body }

    $authRetried = $false
    for ($attempt = 1; ; $attempt++) {
        $headers = @{ 'ConsistencyLevel' = 'eventual' }
        if ($BearerToken) { $headers.Authorization = "Bearer $BearerToken" }
        elseif (-not $NoAuth) { $headers.Authorization = "Bearer $(Get-TenantToken -Context $Context)" }

        $params = @{
            Method             = $Method
            Uri                = $Uri
            Headers            = $headers
            SkipHttpErrorCheck = $true
            TimeoutSec         = 600
        }
        if ($null -ne $json) { $params.Body = [Text.Encoding]::UTF8.GetBytes($json); $params.ContentType = 'application/json; charset=utf-8' }

        $resp = $null
        $status = 0
        $networkError = $null
        try {
            $resp = Invoke-WebRequest @params
            $status = [int]$resp.StatusCode
        }
        catch {
            $networkError = $_.Exception.Message
        }

        if ($resp -and $status -ge 200 -and $status -lt 300) {
            if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
            return $resp.Content | ConvertFrom-Json -Depth 50
        }

        if ($status -eq 401 -and -not $authRetried -and -not $NoAuth -and -not $BearerToken) {
            $authRetried = $true
            $null = Get-TenantToken -Context $Context -Force
            continue
        }

        $transient = $networkError -or $status -in 408, 429, 500, 502, 503, 504
        if (-not $transient -or $attempt -ge $MaxRetries) {
            $msg = if ($networkError) { $networkError } else { $resp.Content }
            $ex = [System.Exception]::new("Graph $Method $Uri failed (HTTP $status): $msg")
            $ex.Data['StatusCode'] = $status
            throw $ex
        }

        $wait = [Math]::Min(120, [Math]::Pow(2, $attempt))
        if ($resp -and $resp.Headers['Retry-After']) {
            $ra = 0
            if ([int]::TryParse(($resp.Headers['Retry-After'] | Select-Object -First 1), [ref]$ra)) { $wait = [Math]::Max($ra, 1) }
        }
        Start-Sleep -Seconds $wait
    }
}

# Follows @odata.nextLink and streams each element of .value to the pipeline.
function Invoke-GraphPaged {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Uri,
        [string]$BearerToken
    )
    $next = $Uri
    while ($next) {
        $page = Invoke-Graph -Context $Context -Uri $next -BearerToken $BearerToken
        if ($page.value) { $page.value }
        $next = $page.'@odata.nextLink'
    }
}
