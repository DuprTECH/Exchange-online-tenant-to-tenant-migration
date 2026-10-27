# App-only authentication (client credentials) for a tenant context.
# Supports certificate (JWT client assertion) or DPAPI-protected client secret.

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-ClientAssertion {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-Base64Url $Certificate.GetCertHash()) } | ConvertTo-Json -Compress
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now - 60
        exp = $now + 600
    } | ConvertTo-Json -Compress

    $unsigned = (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' +
                (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw "Certificate $($Certificate.Thumbprint) has no accessible RSA private key." }
    $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    "$unsigned.$(ConvertTo-Base64Url $sig)"
}

function Get-MigrationCertificate {
    param([Parameter(Mandatory)][string]$Thumbprint)
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        $cert = Get-Item -Path (Join-Path $store $Thumbprint) -ErrorAction SilentlyContinue
        if ($cert) { return $cert }
    }
    throw "Certificate with thumbprint $Thumbprint not found in CurrentUser\My or LocalMachine\My."
}

# A tenant context is a hashtable shared by all Graph calls for that tenant; it caches the token.
function New-TenantContext {
    param(
        [Parameter(Mandatory)]$TenantConfig,
        [string]$GraphApiVersion = 'beta',
        [string]$Name = 'tenant'
    )
    if (-not $TenantConfig.TenantId -or -not $TenantConfig.ClientId) {
        throw "Tenant '$Name' is not configured (TenantId/ClientId missing). Run the permission setup first."
    }
    @{
        Name            = $Name
        TenantId        = $TenantConfig.TenantId
        ClientId        = $TenantConfig.ClientId
        Thumbprint      = $TenantConfig.CertificateThumbprint
        SecretEncrypted = $TenantConfig.ClientSecretEncrypted
        GraphBase       = "https://graph.microsoft.com/$GraphApiVersion"
        Token           = $null
        TokenExpires    = [DateTime]::MinValue
    }
}

function Get-TenantToken {
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$Force)

    if (-not $Force -and $Context.Token -and $Context.TokenExpires -gt (Get-Date).AddMinutes(5)) {
        return $Context.Token
    }

    $body = @{
        client_id  = $Context.ClientId
        scope      = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'
    }
    if ($Context.Thumbprint) {
        $cert = Get-MigrationCertificate -Thumbprint $Context.Thumbprint
        $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body.client_assertion = New-ClientAssertion -TenantId $Context.TenantId -ClientId $Context.ClientId -Certificate $cert
    }
    elseif ($Context.SecretEncrypted) {
        $secure = ConvertTo-SecureString $Context.SecretEncrypted
        $body.client_secret = [System.Net.NetworkCredential]::new('', $secure).Password
    }
    else {
        throw "Tenant '$($Context.Name)' has neither certificate thumbprint nor client secret configured."
    }

    $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($Context.TenantId)/oauth2/v2.0/token" `
        -Body $body -ContentType 'application/x-www-form-urlencoded'
    $Context.Token = $resp.access_token
    $Context.TokenExpires = (Get-Date).AddSeconds([int]$resp.expires_in)
    $Context.Token
}

# Delegated device-code sign-in, used only by the permission setup (admin creates the app registration).
function Get-DelegatedAdminToken {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string[]]$Scopes = @('https://graph.microsoft.com/Application.ReadWrite.All',
                              'https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All',
                              'https://graph.microsoft.com/Organization.Read.All')
    )
    # Microsoft Graph Command Line Tools public client
    $clientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    $scope = ($Scopes + 'offline_access') -join ' '
    $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $clientId; scope = $scope } -ContentType 'application/x-www-form-urlencoded'

    Write-Host ''
    Write-Host $dc.message -ForegroundColor Yellow
    Write-Host ''

    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$dc.interval)
        try {
            $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $clientId
                device_code = $dc.device_code
            } -ContentType 'application/x-www-form-urlencoded'
            return $tok.access_token
        }
        catch {
            $err = $null
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
            if ($err -in 'authorization_pending', 'slow_down') { continue }
            throw
        }
    }
    throw 'Device code sign-in timed out.'
}
