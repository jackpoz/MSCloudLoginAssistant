function Connect-MSCloudLoginDefenderForEndpoint
{
    [CmdletBinding()]
    param()

    $ProgressPreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'

    if ($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'CredentialsWithApplicationId' -or
        $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'Credentials' -or
        $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'CredentialsWithTenantId')
    {
        Write-Verbose -Message 'Will try connecting with user credentials'
        Connect-MSCloudLoginDefenderForEndpointWithUser
    }
    elseif ($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'ServicePrincipalWithSecret')
    {
        Write-Verbose -Message 'Will try connecting with Application Secret'
        Connect-MSCloudLoginDefenderForEndpointWithAppSecret
    }
    elseif ($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'ServicePrincipalWithThumbprint')
    {
        Write-Verbose -Message 'Will try connecting with Application Secret'
        Connect-MSCloudLoginDefenderForEndpointWithCertificateThumbprint
    }
    elseif ($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthenticationType -eq 'AccessToken')
    {
        Write-Verbose -Message 'Will try connecting with Access Token'
        $Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessTokens[0])
        $AccessTokenValue = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($Ptr)
        $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessToken = $AccessTokenValue
    }
}

function Connect-MSCloudLoginDefenderForEndpointWithUser
{
    [CmdletBinding()]
    param()

    if ([System.String]::IsNullOrEmpty($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId))
    {
        $tenantid = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Credentials.UserName.Split('@')[1]
    }
    else
    {
        $tenantId = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId
    }
    $username = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Credentials.UserName
    $password = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Credentials.GetNetworkCredential().password


    if ([System.String]::IsNullOrEmpty($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationId))
    {
        throw 'ApplicationId is required for this authentication type'
    }
    $clientId = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationId
    $uri = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/{0}/oauth2/token" -f $tenantid
    $body = "resource=$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.HostUrl)/&client_id=$clientId&grant_type=password&username={1}&password={0}" -f [System.Web.HttpUtility]::UrlEncode($password), $username

    # Request token through ROPC
    try
    {
        $managementToken = Invoke-RestMethod $uri `
            -Method POST `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -ErrorAction SilentlyContinue

        $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessToken = $managementToken.token_type.ToString() + ' ' + $managementToken.access_token.ToString()
    }
    catch
    {
        if ($_.ErrorDetails.Message -like "*AADSTS50076*")
        {
            Write-Verbose -Message "Account used required MFA"
            Connect-MSCloudLoginDefenderForEndpointWithUserMFA
        }
    }
}

function Connect-MSCloudLoginDefenderForEndpointWithUserMFA
{
    [CmdletBinding()]
    param()

    if ([System.String]::IsNullOrEmpty($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId))
    {
        $tenantid = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Credentials.UserName.Split('@')[1]
    }
    else
    {
        $tenantId = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId
    }
    if ([System.String]::IsNullOrEmpty($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationId))
    {
        throw 'ApplicationId is required for this authentication type'
    }
    $clientId = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationId
    $deviceCodeUri = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/$tenantId/oauth2/devicecode"

    $body = @{
        client_id = $clientId
        resource  = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Scope
    }
    $DeviceCodeRequest = Invoke-RestMethod $deviceCodeUri `
            -Method POST `
            -Body $body

    Write-Host "`r`n$($DeviceCodeRequest.message)" -ForegroundColor Yellow

    $TokenRequestParams = @{
        Method = 'POST'
        Uri    = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/$TenantId/oauth2/token"
        Body   = @{
            grant_type = "urn:ietf:params:oauth:grant-type:device_code"
            code       = $DeviceCodeRequest.device_code
            client_id  = $clientId
        }
    }
    $TimeoutTimer = [System.Diagnostics.Stopwatch]::StartNew()
    while ([string]::IsNullOrEmpty($managementToken.access_token))
    {
        if ($TimeoutTimer.Elapsed.TotalSeconds -gt 300)
        {
            throw 'Login timed out, please try again.'
        }
        $managementToken = try
        {
            Invoke-RestMethod @TokenRequestParams -ErrorAction Stop
        }
        catch
        {
            $Message = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($Message.error -ne "authorization_pending")
            {
                throw
            }
        }
        Start-Sleep -Seconds 1
    }
    $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessToken = $managementToken.token_type.ToString() + ' ' + $managementToken.access_token.ToString()
}

function Connect-MSCloudLoginDefenderForEndpointWithAppSecret
{
    [CmdletBinding()]
    param()


    $uri = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/{0}/oauth2/v2.0/token" -f $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId
    $body = "scope=$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Scope).default&client_id=$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationId)&client_secret=$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationSecret)&grant_type=client_credentials"

    # Request token through ROPC
    $managementToken = Invoke-RestMethod $uri `
        -Method POST `
        -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -ErrorAction SilentlyContinue

    $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessToken = $managementToken.token_type.ToString() + ' ' + $managementToken.access_token.ToString()
}

function Connect-MSCloudLoginDefenderForEndpointWithCertificateThumbprint
{
    [CmdletBinding()]
    Param()
    $WarningPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'

    Write-Verbose -Message 'Attempting to connect to Whiteboard using CertificateThumbprint'
    $tenantId = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.TenantId

    try
    {
        $Certificate = Get-Item "Cert:\CurrentUser\My\$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.CertificateThumbprint)" -ErrorAction SilentlyContinue

        if ($null -eq $Certificate)
        {
            Write-Verbose 'Certificate not found in CurrentUser\My, trying LocalMachine\My'

            $Certificate = Get-ChildItem "Cert:\LocalMachine\My\$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.CertificateThumbprint)" -ErrorAction SilentlyContinue

            if ($null -eq $Certificate)
            {
                throw 'Certificate not found in LocalMachine\My nor CurrentUser\My'
            }
        }
        # Create base64 hash of certificate
        $CertificateBase64Hash = [System.Convert]::ToBase64String($Certificate.GetCertHash())

        # Create JWT timestamp for expiration
        $StartDate = (Get-Date '1970-01-01T00:00:00Z' ).ToUniversalTime()
        $JWTExpirationTimeSpan = (New-TimeSpan -Start $StartDate -End (Get-Date).ToUniversalTime().AddMinutes(2)).TotalSeconds
        $JWTExpiration = [math]::Round($JWTExpirationTimeSpan, 0)

        # Create JWT validity start timestamp
        $NotBeforeExpirationTimeSpan = (New-TimeSpan -Start $StartDate -End ((Get-Date).ToUniversalTime())).TotalSeconds
        $NotBefore = [math]::Round($NotBeforeExpirationTimeSpan, 0)

        # Create JWT header
        $JWTHeader = @{
            alg = 'RS256'
            typ = 'JWT'
            # Use the CertificateBase64Hash and replace/strip to match web encoding of base64
            x5t = $CertificateBase64Hash -replace '\+', '-' -replace '/', '_' -replace '='
        }

        # Create JWT payload
        $JWTPayLoad = @{
            # What endpoint is allowed to use this JWT
            aud = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/$TenantId/oauth2/token"

            # Expiration timestamp
            exp = $JWTExpiration

            # Issuer = your application
            iss = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationID

            # JWT ID: random guid
            jti = [guid]::NewGuid()

            # Not to be used before
            nbf = $NotBefore

            # JWT Subject
            sub = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationID
        }

        # Convert header and payload to base64
        $JWTHeaderToByte = [System.Text.Encoding]::UTF8.GetBytes(($JWTHeader | ConvertTo-Json))
        $EncodedHeader = [System.Convert]::ToBase64String($JWTHeaderToByte)

        $JWTPayLoadToByte = [System.Text.Encoding]::UTF8.GetBytes(($JWTPayload | ConvertTo-Json))
        $EncodedPayload = [System.Convert]::ToBase64String($JWTPayLoadToByte)

        # Join header and Payload with "." to create a valid (unsigned) JWT
        $JWT = $EncodedHeader + '.' + $EncodedPayload

        # Get the private key object of your certificate
        $PrivateKey = ([System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate))

        # Define RSA signature and hashing algorithm
        $RSAPadding = [Security.Cryptography.RSASignaturePadding]::Pkcs1
        $HashAlgorithm = [Security.Cryptography.HashAlgorithmName]::SHA256

        # Create a signature of the JWT
        $Signature = [Convert]::ToBase64String(
            $PrivateKey.SignData([System.Text.Encoding]::UTF8.GetBytes($JWT), $HashAlgorithm, $RSAPadding)
        ) -replace '\+', '-' -replace '/', '_' -replace '='

        # Join the signature to the JWT with "."
        $JWT = $JWT + '.' + $Signature

        # Create a hash with body parameters
        $Body = @{
            client_id             = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.ApplicationID
            client_assertion      = $JWT
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            scope                 = $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.Scope
            grant_type            = 'client_credentials'
        }

        $Url = "$($Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AuthorizationUrl)/$TenantId/oauth2/v2.0/token"

        # Use the self-generated JWT as Authorization
        $Header = @{
            Authorization = "Bearer $JWT"
        }

        # Splat the parameters for Invoke-Restmethod for cleaner code
        $PostSplat = @{
            ContentType = 'application/x-www-form-urlencoded'
            Method      = 'POST'
            Body        = $Body
            Uri         = $Url
            Headers     = $Header
        }

        $Request = Invoke-RestMethod @PostSplat

        # View access_token
        $Global:MSCloudLoginConnectionProfile.DefenderForEndpoint.AccessToken = 'Bearer ' + $Request.access_token
        Write-Verbose -Message 'Successfully connected to the DefenderForEndpoint API using Certificate Thumbprint'
    }
    catch
    {
        throw $_
    }
}
