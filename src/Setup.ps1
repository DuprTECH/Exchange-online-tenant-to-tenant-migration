# Creates an app registration with the Graph application permissions the migration needs,
# a self-signed certificate for authentication, and grants admin consent.

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'

$script:RequiredPermissions = @{
    Source = @('User.Read.All', 'MailboxFolder.Read.All', 'MailboxItem.Read.All', 'MailboxItem.ImportExport.All')
    Target = @('User.Read.All', 'MailboxFolder.ReadWrite.All', 'MailboxItem.Read.All', 'MailboxItem.ImportExport.All')
}

function Get-RequiredPermissions {
    param([ValidateSet('Source', 'Target', 'Both')][string]$Role)
    if ($Role -eq 'Both') { return @($script:RequiredPermissions.Source + $script:RequiredPermissions.Target | Sort-Object -Unique) }
    $script:RequiredPermissions[$Role]
}

# Entra ID is eventually consistent: objects created a moment ago may not be visible yet (HTTP 400/404).
function Invoke-WithReplicationRetry {
    param([Parameter(Mandatory)][scriptblock]$Action, [int]$Attempts = 12, [int]$DelaySeconds = 5)
    for ($i = 1; ; $i++) {
        try { return & $Action }
        catch {
            $code = $_.Exception.Data['StatusCode']
            if ($i -ge $Attempts -or $code -notin 400, 404) { throw }
            Write-Host "  waiting for Entra ID replication ($i/$Attempts)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Install-MigrationApp {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][ValidateSet('Source', 'Target', 'Both')][string]$Role,
        [string]$DisplayName = 'Mailbox Migrator',
        [int]$CertificateValidityMonths = 12
    )

    $token = Get-DelegatedAdminToken -TenantId $TenantId
    $ctx = @{ Name = 'setup'; GraphBase = 'https://graph.microsoft.com/v1.0' }
    $g = { param($Method, $Uri, $Body) Invoke-Graph -Context $ctx -Method $Method -Uri $Uri -Body $Body -BearerToken $token }

    $org = (& $g GET 'organization').value | Select-Object -First 1
    $tenantGuid = $org.id
    Write-Host "Signed in to tenant: $($org.displayName) ($tenantGuid)" -ForegroundColor Green

    # Resolve permission names to app role IDs from the tenant's Graph service principal.
    $graphSp = (& $g GET "servicePrincipals?`$filter=appId eq '$script:GraphAppId'").value | Select-Object -First 1
    $wanted = Get-RequiredPermissions -Role $Role
    $roles = foreach ($p in $wanted) {
        $r = $graphSp.appRoles | Where-Object { $_.value -eq $p } | Select-Object -First 1
        if ($r) { $r } else { Write-Warning "Permission '$p' is not available in this tenant - skipped. Migration may fail without it." }
    }

    # Certificate: reuse a still-valid one from a previous (interrupted) setup run, otherwise create.
    $subject = "CN=$DisplayName ($tenantGuid)"
    $cert = Get-ChildItem 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) {
        Write-Host "Reusing certificate $($cert.Thumbprint) from Cert:\CurrentUser\My" -ForegroundColor Green
    }
    else {
        $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddMonths($CertificateValidityMonths)
        Write-Host "Created certificate $($cert.Thumbprint) in Cert:\CurrentUser\My" -ForegroundColor Green
    }

    # App registration: reuse by display name so the setup can be rerun safely.
    $appName = "$DisplayName ($Role)"
    $appBody = @{
        requiredResourceAccess = @(@{
                resourceAppId  = $script:GraphAppId
                resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = 'Role' } })
            })
        keyCredentials         = @(@{
                type        = 'AsymmetricX509Cert'
                usage       = 'Verify'
                key         = [Convert]::ToBase64String($cert.RawData)
                displayName = $cert.Subject
            })
    }
    $app = (& $g GET "applications?`$filter=displayName eq '$appName'").value | Select-Object -First 1
    if ($app) {
        Invoke-WithReplicationRetry { $null = & $g PATCH "applications/$($app.id)" $appBody }
        Write-Host "Updated existing app registration $appName (appId $($app.appId))" -ForegroundColor Green
    }
    else {
        $appBody.displayName = $appName
        $appBody.signInAudience = 'AzureADMyOrg'
        $app = & $g POST 'applications' $appBody
        Write-Host "Created app registration $appName (appId $($app.appId))" -ForegroundColor Green
    }

    # Service principal: a freshly created app needs time to replicate before its SP can be created.
    $sp = (& $g GET "servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
    if (-not $sp) {
        $sp = Invoke-WithReplicationRetry { & $g POST 'servicePrincipals' @{ appId = $app.appId } }
        Write-Host "Created service principal $($sp.id)" -ForegroundColor Green
    }

    # Admin consent = app role assignments.
    $assigned = @(Invoke-WithReplicationRetry { (& $g GET "servicePrincipals/$($sp.id)/appRoleAssignments").value } |
        Where-Object { $_.resourceId -eq $graphSp.id } | ForEach-Object { $_.appRoleId })
    foreach ($r in $roles) {
        if ($assigned -contains $r.id) { Write-Host "  already granted $($r.value)" -ForegroundColor DarkGreen; continue }
        Invoke-WithReplicationRetry {
            $null = & $g POST "servicePrincipals/$($graphSp.id)/appRoleAssignedTo" @{
                principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id
            }
        }
        Write-Host "  granted $($r.value)" -ForegroundColor DarkGreen
    }

    Write-Host 'Waiting 30 s for permission propagation...' -ForegroundColor DarkGray
    Start-Sleep -Seconds 30

    [pscustomobject]@{
        TenantId              = $tenantGuid
        TenantName            = $org.displayName
        ClientId              = $app.appId
        AppObjectId           = $app.id
        CertificateThumbprint = $cert.Thumbprint
        ClientSecretEncrypted = $null
    }
}

# Verifies the app-only token contains all required roles.
function Test-MigrationApp {
    param([Parameter(Mandatory)][hashtable]$Context, [ValidateSet('Source', 'Target', 'Both')][string]$Role)
    $token = Get-TenantToken -Context $Context -Force
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $have = @($claims.roles)
    foreach ($p in Get-RequiredPermissions -Role $Role) {
        [pscustomobject]@{ Permission = $p; Granted = $have -contains $p }
    }
}
