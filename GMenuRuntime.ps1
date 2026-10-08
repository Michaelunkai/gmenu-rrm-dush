# Embedded verbatim into generated commands: no dependency on Micha's profile or F: drive.
function Get-GMenuStateRoot {
    $root='F:\backup\windowsapps\GMenuState'
    if(-not (Test-Path -LiteralPath 'F:\' -PathType Container)){throw 'GMenu durable state requires the F: drive.'}
    return $root
}
function Initialize-GMenuRuntime {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Security
    Add-Type -AssemblyName System.Net.Http
    if($PSVersionTable.PSVersion.Major -lt 6){Add-Type -AssemblyName System.ServiceProcess}
    if (-not ('GMenuPayload20260907' -as [type])) {
        if($PSVersionTable.PSVersion.Major -ge 7) {Add-Type -TypeDefinition $script:GMenuPayloadSource}
        else {Add-Type -TypeDefinition $script:GMenuPayloadSource -ReferencedAssemblies @('System.IO.Compression','System.IO.Compression.FileSystem','System.Security')}
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $payloadType='GMenuPayload20260907' -as [type]
    if($payloadType) {
        $progressProperty=$payloadType.GetProperty('RuntimeProgress')
        $progressField=$payloadType.GetField('RuntimeProgress')
        if($progressProperty -or $progressField) {
            $callback=[Action[string,long,long]]{param($phase,$done,$total) Write-GMenuProgress ('payload-'+[string]$phase) $done $total}
            if($progressProperty){$progressProperty.SetValue($null,$callback,$null)}else{$progressField.SetValue($null,$callback)}
        }
    }
}
function Start-GMenuHeartbeat([string]$Phase) {
    $script:GMenuHeartbeatStartedAt=Get-Date
    $type='GMenuPayload20260907' -as [type]
    if($type) {
        $method=$type.GetMethod('StartHeartbeat')
        if($method){[void]$method.Invoke($null,@($Phase))}
    }
}
function Set-GMenuHeartbeatPhase([string]$Phase) {
    $type='GMenuPayload20260907' -as [type]
    if($type) {
        $method=$type.GetMethod('SetHeartbeatPhase')
        if($method){[void]$method.Invoke($null,@($Phase))}
    }
}
function Stop-GMenuHeartbeat {
    $type='GMenuPayload20260907' -as [type]
    if($type) {
        $method=$type.GetMethod('StopHeartbeat')
        if($method){[void]$method.Invoke($null,@())}
    }
}
function Assert-GMenuPath([string]$Path) {
    $provider=$null;$drive=$null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive).TrimEnd('\')
    if($provider.Name -ne 'FileSystem'){throw 'Use a filesystem folder for the application.'}
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\') -or $full.StartsWith('\\')) { throw 'Use a local application folder, not a drive root or network share.' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Redirected destination is not allowed: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
    return $full
}
function Remove-GMenuWork([string]$Path,[string]$Parent) {
    $full = Assert-GMenuPath $Path
    if ([IO.Path]::GetDirectoryName($full) -ne [IO.Path]::GetFullPath($Parent).TrimEnd('\') -or
        [IO.Path]::GetFileName($full) -notmatch '^\.gmenu-(stage|previous|work)-[a-f0-9]{32}$') { throw 'Temporary cleanup path validation failed.' }
    for($attempt=0;$attempt -lt 10;$attempt++) {
        if(-not (Test-Path -LiteralPath $full)){return}
        try {[GMenuPayload20260907]::DeleteTree($full);return}
        catch {if($attempt -eq 9){throw};Start-Sleep -Milliseconds 500}
    }
}
function Protect-GMenuDirectory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    if($PSVersionTable.PSVersion.Major -ge 7) {
        [IO.FileSystemAclExtensions]::SetAccessControl((New-Object IO.DirectoryInfo($Path)),$acl)
    } else {
        [IO.Directory]::SetAccessControl($Path,$acl)
    }
}
function New-GMenuCredential([string]$UserName,[string]$Secret) {
    $secure=New-Object Security.SecureString
    foreach($character in $Secret.ToCharArray()){$secure.AppendChar($character)}
    $secure.MakeReadOnly()
    return New-Object Management.Automation.PSCredential($UserName,$secure)
}
function Invoke-GMenuRobocopy([string]$Robocopy,[string]$Source,[string]$Destination,[string[]]$Options,[string]$Phase,[long]$TotalBytes=0) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Robocopy
    $start.Arguments=([GMenuPayload20260907]::Quote($Source)+' '+[GMenuPayload20260907]::Quote($Destination)+' '+($Options -join ' '))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $outputTask=$process.StandardOutput.ReadToEndAsync()
        $errorTask=$process.StandardError.ReadToEndAsync()
        do {
            if($clock.ElapsedMilliseconds -ge 1000){
                if($TotalBytes -gt 0 -and (Test-Path -LiteralPath $Destination -PathType Container)) {
                    $copied=[long]((Get-ChildItem -LiteralPath $Destination -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
                    Write-GMenuProgress $Phase ([Math]::Min($TotalBytes,$copied)) $TotalBytes ('elapsed_ms='+$clock.ElapsedMilliseconds)
                } else { Write-GMenuProgress $Phase 0 0 ('elapsed_ms='+$clock.ElapsedMilliseconds) }
                $clock.Restart()
            }
        } while(-not $process.WaitForExit(250))
        $output=$outputTask.GetAwaiter().GetResult()
        $errors=$errorTask.GetAwaiter().GetResult()
        if($output){$output.TrimEnd() | Out-Host}
        if($errors){$errors.TrimEnd() | Out-Host}
        if($TotalBytes -gt 0 -and (Test-Path -LiteralPath $Destination -PathType Container)) {
            $copied=[long]((Get-ChildItem -LiteralPath $Destination -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
            Write-GMenuProgress $Phase ([Math]::Min($TotalBytes,$copied)) $TotalBytes ('complete exit='+$process.ExitCode)
        } else { Write-GMenuProgress $Phase 0 0 ('complete exit='+$process.ExitCode) }
        return [int]$process.ExitCode
    } finally {$process.Dispose()}
}
function Copy-GMenuStage([string]$Source,[string]$Destination,[switch]$ResumeSnapshot) {
    if(Test-Path -LiteralPath $Destination) {
        if(-not $ResumeSnapshot -or [IO.Path]::GetFileName($Destination) -notmatch '^snapshot-[0-9]+$' -or
           [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Destination)) -notmatch '^\.gmenu-work-[a-f0-9]{32}$') {throw 'Restore staging destination already exists.'}
        [void](Assert-GMenuPath $Destination)
    }
    Protect-GMenuDirectory $Destination
    $robocopy=Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $options=@('/E','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ','/MT:128','/NFL','/NDL','/NJH','/NJS','/NP')
    $totalBytes=[long]((Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
    Write-GMenuProgress 'stage-copy' 0 $totalBytes
    $copyExit=Invoke-GMenuRobocopy $robocopy $Source $Destination $options 'stage-copy' $totalBytes
    if($copyExit -lt 0 -or $copyExit -ge 8){throw 'Application staging copy failed; original application preserved.'}
    $verifyExit=Invoke-GMenuRobocopy $robocopy $Source $Destination ($options+@('/L')) 'stage-verify' $totalBytes
    if($verifyExit -ne 0){throw 'Application staging copy did not match its verified payload.'}
}
function Get-GMenuHubToken([string]$Repository,[pscredential]$Credential) {
    $headers = @{}
    if ($Credential) {
        $raw = $Credential.UserName + ':' + $Credential.GetNetworkCredential().Password
        $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
        $raw = $null
    }
    try {
        $response = Invoke-RestMethod -UseBasicParsing -Uri ('https://auth.docker.io/token?service=registry.docker.io&scope=repository:'+[uri]::EscapeDataString($Repository)+':pull') -Headers $headers -TimeoutSec 45
        $lifetimeSeconds=if($response.expires_in -and [int]$response.expires_in -gt 0){[int]$response.expires_in}else{300}
        $script:GMenuTokenRefreshAt=(Get-Date).AddSeconds([Math]::Max(30,$lifetimeSeconds-60))
        return [string]$response.token
    } catch { throw 'Docker Hub authentication failed. Private repositories require an authorized Docker Hub credential.' }
}
function Invoke-GMenuCredentialHelper {
    param([Parameter(Mandatory=$true)][string]$Helper,[Parameter(Mandatory=$true)][string]$Server,[ValidateRange(1000,60000)][int]$TimeoutMilliseconds=30000)
    # PS5 can prepend a console-encoding BOM to native pipeline input. Write the
    # public registry URL directly so the credential lookup key is byte-exact.
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Helper;$start.Arguments='get'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        # .NET Framework creates an autoflushing stdin writer during Start and
        # takes its encoding from Console.InputEncoding (including its BOM).
        if($start.PSObject.Properties['StandardInputEncoding']) {
            $start.StandardInputEncoding=New-Object Text.UTF8Encoding($false)
            [void]$process.Start()
        } else {
            $savedInputEncoding=[Console]::InputEncoding
            try {[Console]::InputEncoding=New-Object Text.UTF8Encoding($false);[void]$process.Start()}
            finally {[Console]::InputEncoding=$savedInputEncoding}
        }
        $outputTask=$process.StandardOutput.ReadToEndAsync()
        $errorTask=$process.StandardError.ReadToEndAsync()
        $inputBytes=[Text.Encoding]::UTF8.GetBytes($Server+"`n")
        $inputStream=$process.StandardInput.BaseStream
        $inputStream.Write($inputBytes,0,$inputBytes.Length)
        $inputStream.Close()
        if(-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            throw 'Docker credential helper timed out.'
        }
        $output=$outputTask.GetAwaiter().GetResult()
        [void]$errorTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
            throw ("Docker credential helper failed (exit {0})." -f $process.ExitCode)
        }
        return $output
    } finally {$process.Dispose()}
}
function Get-GMenuLocalHubCredential {
    $configPath = Join-Path (Get-GMenuStateRoot) 'Docker\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $server = 'https://index.docker.io/v1/'
    $helperName = [string]$config.credsStore
    if ($config.credHelpers -and $config.credHelpers.$server) { $helperName = [string]$config.credHelpers.$server }
    if ($helperName -match '^[a-zA-Z0-9_-]+$') {
        $helper = Get-Command ('docker-credential-'+$helperName+'.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if (-not $helper) {
            $candidate = Join-Path $env:ProgramFiles ('Docker\Docker\resources\bin\docker-credential-'+$helperName+'.exe')
            if (Test-Path -LiteralPath $candidate) { $helper=$candidate }
        }
        if ($helper) {
            $value = $null
            try {$value = Invoke-GMenuCredentialHelper -Helper $helper -Server $server} catch {Write-Verbose 'Docker credential helper could not return the saved Docker Hub credential.'}
            if ($value) {
                $record = ($value -join '') | ConvertFrom-Json
                if ($record.Username -and $record.Secret) {
                    return New-GMenuCredential ([string]$record.Username) ([string]$record.Secret)
                }
            }
        }
    }
    if ($config.auths -and $config.auths.$server -and $config.auths.$server.auth) {
        $value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$config.auths.$server.auth)).Split(':',2)
        if ($value.Count -eq 2) { return New-GMenuCredential $value[0] $value[1] }
    }
}
function Receive-GMenuHttp([string]$Uri,[string]$Destination,[string]$Token,[string]$Accept,[string]$ProgressPhase='http-download') {
    $maxAttempts=20
    for ($attempt=1;$attempt -le $maxAttempts;$attempt++) {
        $handler=New-Object Net.Http.HttpClientHandler
        $client=New-Object Net.Http.HttpClient($handler)
        $client.Timeout=[TimeSpan]::FromMinutes(30)
        $response=$null
        try {
            $request=New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get,$Uri)
            if ($Token) { $request.Headers.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',$Token) }
            if ($Accept) { [void]$request.Headers.TryAddWithoutValidation('Accept',$Accept) }
            $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) { throw ('HTTP '+[int]$response.StatusCode) }
            $inputStream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::Create)
            try {
                $headerLength=$response.Content.Headers.ContentLength
                $total=if($null -ne $headerLength){[long]$headerLength}else{0}
                [long]$done=0;$last=Get-Date
                Write-GMenuProgress $ProgressPhase 0 $total
                $buffer=New-Object byte[] 1048576
                while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $outputStream.Write($buffer,0,$read);$done+=$read
                    if(((Get-Date)-$last).TotalMilliseconds -ge 200){Write-GMenuProgress $ProgressPhase $done $total;$last=Get-Date}
                }
                Write-GMenuProgress $ProgressPhase $done $total
            } finally { $outputStream.Dispose();$inputStream.Dispose() }
            return
        } catch {
            $lastError=$_.Exception.GetBaseException().Message
            if ($attempt -eq $maxAttempts) { throw ('Docker Hub download failed after '+$maxAttempts+' attempts; existing app preserved. Last error: '+$lastError) }
            Write-Host ('GRESTORE_RETRY attempt='+$attempt+'/'+$maxAttempts+' reason='+$lastError)
            Start-Sleep -Seconds ([Math]::Min(30,[Math]::Max(1,$attempt*2)))
        } finally { if($response){$response.Dispose()};$client.Dispose();$handler.Dispose() }
    }
}
function Get-GMenuManifest([string]$Repository,[string]$Reference,[string]$Work,[string]$Token) {
    if ($Repository -notmatch '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$' -or $Reference -notmatch '^(sha256:[a-f0-9]{64}|[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$') { throw 'Invalid image reference.' }
    $file=Join-Path $Work 'registry-manifest.json'
    Receive-GMenuHttp ('https://registry-1.docker.io/v2/'+$Repository+'/manifests/'+$Reference) $file $Token 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
    $digest='sha256:'+([GMenuPayload20260907]::Hash($file))
    if ($Reference.StartsWith('sha256:') -and $digest -ne $Reference) { throw 'Registry manifest digest mismatch.' }
    $manifest=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if($manifest.manifests) {
        $children=@($manifest.manifests | Where-Object {$_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64'})
        if($children.Count -ne 1 -or $children[0].digest -eq $digest) {throw 'Image index has no unambiguous backup payload.'}
        $childFile=Join-Path $Work 'registry-child-manifest.json'
        if([string]$children[0].digest -notmatch '^sha256:[a-f0-9]{64}$'){throw 'Invalid child manifest digest.'}
        Receive-GMenuHttp ('https://registry-1.docker.io/v2/'+$Repository+'/manifests/'+$children[0].digest) $childFile $Token 'application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
        if(('sha256:'+([GMenuPayload20260907]::Hash($childFile))) -ne $children[0].digest){throw 'Child manifest digest mismatch.'}
        $manifest=Get-Content -LiteralPath $childFile -Raw | ConvertFrom-Json
    }
    if (-not $manifest.layers -or $manifest.schemaVersion -ne 2) { throw 'Unsupported image manifest.' }
    return [pscustomobject]@{Digest=$digest;Manifest=$manifest}
}
function Get-GMenuOwnedProcess([string]$Root) {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -and $_.Path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) } catch { $false } })
}
function Get-GMenuExecutableSubsystem([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $stream=$null;$reader=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if($stream.Length -lt 0x40){return $null}
        $reader=New-Object IO.BinaryReader($stream)
        if($reader.ReadUInt16() -ne 0x5a4d){return $null}
        $stream.Position=0x3c
        $peOffset=$reader.ReadInt32()
        if($peOffset -lt 0 -or $peOffset -gt ($stream.Length-24)){return $null}
        $stream.Position=$peOffset
        if($reader.ReadUInt32() -ne 0x00004550){return $null}
        $stream.Position=$peOffset+4+16
        $optionalHeaderSize=$reader.ReadUInt16()
        $optionalHeaderStart=$peOffset+24
        if($optionalHeaderSize -lt 70 -or $optionalHeaderStart+$optionalHeaderSize -gt $stream.Length){return $null}
        $stream.Position=$optionalHeaderStart
        if($reader.ReadUInt16() -notin @(0x10b,0x20b)){return $null}
        $stream.Position=$optionalHeaderStart+68
        switch([int]$reader.ReadUInt16()) {
            2 {return 'WindowsGui'}
            3 {return 'WindowsCui'}
            default {return 'Other'}
        }
    } catch {return $null}
    finally {
        if($reader){$reader.Dispose()}
        elseif($stream){$stream.Dispose()}
    }
}
function Resolve-GMenuOwnedServiceBinary([string]$Root,[string]$PathName) {
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $path=[Environment]::ExpandEnvironmentVariables([string]$PathName)
    $binary=$null
    if($path -match '^\s*"([^"]+\.exe)"'){$binary=$matches[1]}
    elseif($path -match '^\s*(.+?\.exe)(?:\s|$)'){$binary=$matches[1]}
    if(-not $binary){return $null}
    try {$binary=[IO.Path]::GetFullPath($binary)} catch {return $null}
    if($binary.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {return $binary}
    return $null
}
function Get-GMenuOwnedServices([string]$Root) {
    $serviceKeyRoot='HKLM:\SYSTEM\CurrentControlSet\Services'
    # Win32_Service enumeration can block indefinitely when the WMI provider is
    # unhealthy.  ServiceController + the SCM registry is the same authoritative
    # source for the fields needed here, without making gmenu hostage to WMI.
    foreach($controller in [ServiceProcess.ServiceController]::GetServices()) {
        try {
            $name=[string]$controller.ServiceName
            $settings=Get-ItemProperty -LiteralPath (Join-Path $serviceKeyRoot $name) -ErrorAction SilentlyContinue
            if(-not $settings){continue}
            $path=[Environment]::ExpandEnvironmentVariables([string]$settings.ImagePath)
            $binary=Resolve-GMenuOwnedServiceBinary $Root $path
            if(-not $binary){continue}
            $startMode=switch([int]$settings.Start) {
                0 {'System';break}
                1 {'Boot';break}
                2 {'Auto';break}
                3 {'Manual';break}
                4 {'Disabled';break}
                default {'Unknown';break}
            }
            [pscustomobject]@{
                Name=$name
                DisplayName=[string]$controller.DisplayName
                StartName=if($settings.ObjectName){[string]$settings.ObjectName}else{'LocalSystem'}
                StartMode=[string]$startMode
                PathName=$path
                State=$controller.Status.ToString()
            }
        } finally {
            if($controller -is [IDisposable]){$controller.Dispose()}
        }
    }
}
function Get-GMenuServiceManifest([string]$Root) {
    foreach($service in Get-GMenuOwnedServices $Root) {
        $settings=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$service.Name)
        if($service.StartName -notin @('LocalSystem','NT AUTHORITY\LocalService','NT AUTHORITY\NetworkService')) {throw "Service $($service.Name) requires an account-specific restore adapter."}
        [pscustomobject]@{
            Name=$service.Name;DisplayName=$service.DisplayName;StartName=$service.StartName;StartMode=$service.StartMode
            BinaryPath=([string]$service.PathName).Replace($Root,'{AppRoot}')
            Environment=@($settings.Environment | ForEach-Object {([string]$_).Replace($Root,'{AppRoot}')})
            Dependencies=@($settings.DependOnService);WasRunning=($service.State -eq 'Running')
        }
    }
}
function Resume-GMenuServices([string]$Root) {
    if(-not $script:GMenuStoppedServices -or -not $script:GMenuStoppedServices.ContainsKey($Root)){return}
    foreach($name in @($script:GMenuStoppedServices[$Root])) {
        Write-GMenuProgress ('start-service-'+$name)
        Start-Service -Name $name -ErrorAction Stop
        $service=Get-Service -Name $name
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
    }
    [void]$script:GMenuStoppedServices.Remove($Root)
}
function Install-GMenuServices([string]$Root,$Manifest) {
    foreach($record in @($Manifest.WindowsServices)) {
        if(-not $record){continue}
        if($record.Name -notmatch '^[a-zA-Z0-9_. -]+$' -or $record.StartName -notin @('LocalSystem','NT AUTHORITY\LocalService','NT AUTHORITY\NetworkService')) {throw 'Unsupported saved Windows service identity.'}
        $existing=Get-Service -Name $record.Name -ErrorAction SilentlyContinue
        if($existing) {
            if(-not @(Get-GMenuOwnedServices $Root | Where-Object Name -eq $record.Name).Count){throw "Service $($record.Name) belongs to another installation."}
            continue
        }
        $binary=([string]$record.BinaryPath).Replace('{AppRoot}',$Root)
        $exe=if($binary -match '^"([^"]+\.exe)"'){$matches[1]}elseif($binary -match '^(.+?\.exe)(?:\s|$)'){$matches[1]}else{throw 'Invalid service executable.'}
        if(-not ([IO.Path]::GetFullPath($exe)).StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Saved service executable is missing or outside the app folder.'}
        $parameters=@{Name=[string]$record.Name;BinaryPathName=$binary;DisplayName=[string]$record.DisplayName;StartupType='Manual'}
        if(@($record.Dependencies).Count){$parameters.DependsOn=[string[]]$record.Dependencies}
        if($record.StartName -ne 'LocalSystem'){$parameters.Credential=New-Object Management.Automation.PSCredential -ArgumentList ([string]$record.StartName),(New-Object Security.SecureString)}
        [void](New-Service @parameters)
        # Record immediately so a later restore failure can remove only services we created.
        $script:GMenuCreatedServices.Add([string]$record.Name)
        $environment=@($record.Environment | ForEach-Object {([string]$_).Replace('{AppRoot}',$Root)})
        if($environment.Count){[void](New-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$record.Name) -Name Environment -PropertyType MultiString -Value ([string[]]$environment) -Force)}
        $mode=switch($record.StartMode){'Auto'{'Automatic'} 'Disabled'{'Disabled'} default{'Manual'}}
        Set-Service -Name $record.Name -StartupType $mode
    }
}
function Initialize-GMenuTrayControl {
    if('GMenuTrayControl20260907' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GMenuTrayControl20260907 {
    public sealed class Window { public long Handle; public uint Thread; public string Class; public string Title; }
    private delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostThreadMessage(uint thread, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    public static Window[] Windows(int process) {
        var result = new List<Window>();
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint owner; uint thread=GetWindowThreadProcessId(window,out owner);
            if(owner==(uint)process) {
                var name=new StringBuilder(256); var title=new StringBuilder(512);
                GetClassName(window,name,name.Capacity); GetWindowText(window,title,title.Capacity);
                if(name.ToString().StartsWith("WindowsForms10.Window.",StringComparison.Ordinal))
                    result.Add(new Window {Handle=window.ToInt64(),Thread=thread,Class=name.ToString(),Title=title.ToString()});
            }
            return true;
        },IntPtr.Zero);
        return result.ToArray();
    }
    public static bool Responsive(long window) {
        UIntPtr result;
        return SendMessageTimeout(new IntPtr(window),0,UIntPtr.Zero,IntPtr.Zero,2,1000,out result)!=IntPtr.Zero;
    }
    public static bool Close(long window) {
        UIntPtr result;
        return SendMessageTimeout(new IntPtr(window),0x0010,UIntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero;
    }
    public static void Quit(uint thread) {
        if(!PostThreadMessage(thread,0x0012,UIntPtr.Zero,IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}
function Get-GMenuGuardianHealth([string[]]$Lines) {
    # Only inspect the latest pass: an old success must never mask a new failure.
    $pass=-1
    for($i=0;$i -lt $Lines.Count;$i++){if($Lines[$i] -match '=== Guardian pass '){$pass=$i}}
    if($pass -lt 0){return [pscustomobject]@{Status='NotVerified';Detail='No current Guardian verification pass.'}}
    $current=@($Lines[$pass..($Lines.Count-1)])
    $failure=@($current | Where-Object {$_ -match 'FAILED:'})
    if($failure.Count){return [pscustomobject]@{Status='NeedsAttention';Detail=($failure[-1] -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ','')}}
    if(@($current | Where-Object {$_ -match 'Guardian pass complete\.'}).Count){return [pscustomobject]@{Status='Verified';Detail='Guardian verification pass completed.'}}
    return [pscustomobject]@{Status='Checking';Detail='Guardian verification is still running.'}
}
function Get-GMenuGuardianProcess([string]$Root) {
    $expected=Join-Path $Root 'tizen\moonlight-setup-guardian\bin\MoonlightSetupGuardian.exe'
    Get-GMenuOwnedProcess $Root | Where-Object {$_.ProcessName -eq 'MoonlightSetupGuardian' -and $_.Path -ieq $expected}
}
function Select-GMenuWhisperShutdownWindow($Windows) {
    $matches=@($Windows | Where-Object {$_.Title -ceq 'Whisper.cpp STT'})
    if($matches.Count -ne 1){throw 'Whisper graceful shutdown requires exactly one dedicated Whisper.cpp STT window.'}
    return $matches[0]
}
function Get-GMenuWhisperProcess([string]$Root) {
    $paths=@(
        (Join-Path $Root 'Startup\WhisperSTTWatchdog.exe'),
        (Join-Path $Root 'Runtime\v20-lexical\WhisperSTT.exe'),
        (Join-Path $Root 'Runtime\v20-lexical\Release\whisper-server.exe')
    )
    Get-GMenuOwnedProcess $Root | Where-Object {$paths -contains $_.Path}
}
function Stop-GMenuWhisper([string]$Root) {
    $owned=@(Get-GMenuWhisperProcess $Root)
    if(-not $owned.Count){return}
    $main=@($owned | Where-Object {$_.Path -ieq (Join-Path $Root 'Runtime\v20-lexical\WhisperSTT.exe')})
    if($main.Count -ne 1){throw 'Whisper runtime process could not be identified safely; its files were preserved.'}
    Initialize-GMenuTrayControl
    $window=Select-GMenuWhisperShutdownWindow ([GMenuTrayControl20260907]::Windows($main[0].Id))
    if(-not [GMenuTrayControl20260907]::Responsive($window.Handle)){throw 'Whisper graceful-shutdown window is not responding; its files were preserved.'}
    if(-not [GMenuTrayControl20260907]::Close($window.Handle)){throw 'Whisper rejected its graceful-shutdown message; its files were preserved.'}
    $deadline=(Get-Date).AddSeconds(45)
    while(@(Get-GMenuWhisperProcess $Root).Count -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 250}
    if(@(Get-GMenuWhisperProcess $Root).Count){throw 'Whisper watchdog did not complete graceful shutdown; its files were preserved.'}
}
function Initialize-GMenuGuardianRuntime([string]$Exe) {
    $configPath=[IO.Path]::ChangeExtension($Exe,'.runtimeconfig.json')
    if(-not (Test-Path -LiteralPath $configPath)){return}
    $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    # This saved Guardian runs on the installed newer desktop runtime. Limit
    # roll-forward to this app; never change the machine-wide .NET environment.
    if($config.runtimeOptions.tfm -eq 'net7.0' -and -not $config.runtimeOptions.rollForward) {
        $config.runtimeOptions | Add-Member -NotePropertyName rollForward -NotePropertyValue 'Major'
        [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    }
}
function Stop-GMenuOwnedConsole([string]$Root,[int]$ProcessId) {
    # Signal from an isolated helper, never detach or signal the user's shell.
    # Refuse a shared console containing even one process outside this app.
    $parent=Get-GMenuStateRoot;[void][IO.Directory]::CreateDirectory($parent)
    $work=Join-Path $parent ('.gmenu-work-'+[guid]::NewGuid().ToString('N'));Protect-GMenuDirectory $work
    try {
        $source=Join-Path $work 'StopOwnedConsole.cs';$helper=Join-Path $work 'StopOwnedConsole.exe'
        [IO.File]::WriteAllText($source,@'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
class StopOwnedConsole {
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint id);
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list,uint count);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler,bool add);
    [DllImport("kernel32.dll")] static extern bool GenerateConsoleCtrlEvent(uint type,uint group);
    static int Main(string[] args) {
        try {
            var target=Process.GetProcessById(Int32.Parse(args[1]));
            string root=System.IO.Path.GetFullPath(args[0]).TrimEnd('\\')+"\\";
            if(!target.MainModule.FileName.StartsWith(root,StringComparison.OrdinalIgnoreCase))return 10;
            FreeConsole(); if(!AttachConsole((uint)target.Id))return 11;
            uint[] ids=new uint[2048]; uint count=GetConsoleProcessList(ids,(uint)ids.Length);
            if(count==0 || count>ids.Length)return 12;
            for(int i=0;i<count;i++) {
                if(ids[i]==Process.GetCurrentProcess().Id)continue;
                if(!Process.GetProcessById((int)ids[i]).MainModule.FileName.StartsWith(root,StringComparison.OrdinalIgnoreCase))return 13;
            }
            if(!SetConsoleCtrlHandler(IntPtr.Zero,true))return 14;
            if(!GenerateConsoleCtrlEvent(0,0))return 15;
            return target.WaitForExit(30000)?0:16;
        }catch{return 17;}finally{FreeConsole();}
    }
}
'@,(New-Object Text.UTF8Encoding($false)))
        $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $compiler /nologo /target:exe ('/out:'+$helper) $source | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not prepare the isolated console shutdown helper.'}
        $arguments=[GMenuPayload20260907]::Quote($Root)+' '+$ProcessId
        $stopper=Start-Process -FilePath $helper -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
        if($stopper.ExitCode -ne 0){throw "App console could not be stopped safely (code $($stopper.ExitCode)); its files were preserved."}
    }finally{Remove-GMenuWork $work $parent}
}
function Get-GMenuGenericCloseProcess([string]$Root,$Owned) {
    # Whisper has a dedicated hidden-window shutdown adapter. Sending a generic
    # CloseMainWindow first races that adapter against a disappearing HWND.
    if(Test-Path -LiteralPath (Join-Path $Root 'Startup\WhisperSTTWatchdog.exe')){return @()}
    @($Owned | Where-Object MainWindowHandle -ne 0)
}
function Stop-GMenuApp([string]$Root) {
    if(-not $script:GMenuStoppedServices){$script:GMenuStoppedServices=@{}}
    if(-not $script:GMenuStoppedServices.ContainsKey($Root)){$script:GMenuStoppedServices[$Root]=@()}
    $owned=@(Get-GMenuOwnedProcess $Root)
    foreach($process in Get-GMenuGenericCloseProcess $Root $owned) { [void]$process.CloseMainWindow() }
    try {
    foreach($service in Get-GMenuOwnedServices $Root | Where-Object State -ne 'Stopped') {
        # Record before stopping so error recovery also covers stop timeouts.
        if($script:GMenuStoppedServices[$Root] -notcontains $service.Name){$script:GMenuStoppedServices[$Root]+=$service.Name}
        Write-GMenuProgress ('stop-service-'+$service.Name)
        Stop-Service -Name $service.Name -ErrorAction Stop
        (Get-Service -Name $service.Name).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
    }
    if(Test-Path -LiteralPath (Join-Path $Root 'Startup\WhisperSTTWatchdog.exe')){Stop-GMenuWhisper $Root}
    # Tailscale's tray has no document window; its daemon has now flushed the state.
    # Match the owned executable, never terminate unrelated headless applications.
    if([IO.Path]::GetFileName($Root) -ieq 'tailscale') {
        foreach($process in Get-GMenuOwnedProcess $Root | Where-Object ProcessName -eq 'tailscale-ipn') {Stop-Process -Id $process.Id -ErrorAction Stop}
    }
    foreach($process in @(Get-GMenuOwnedProcess $Root | Where-Object {$_.ProcessName -in @('JackettConsole','Prowlarr.Console','Prowlarr','flaresolverr')})) {
        Stop-GMenuOwnedConsole $Root $process.Id
    }
    foreach($process in @(Get-GMenuGuardianProcess $Root)) {
        # A NotifyIcon ApplicationContext has no MainWindowHandle. Exit its actual
        # WinForms message loop, allowing normal disposal, instead of killing it.
        Initialize-GMenuTrayControl
        $log=Join-Path ([IO.Path]::GetDirectoryName($process.Path)) 'logs\guardian.log'
        $deadline=(Get-Date).AddSeconds(120)
        while(Test-Path -LiteralPath $log) {
            $health=Get-GMenuGuardianHealth @(Get-Content -LiteralPath $log -Tail 150)
            if($health.Status -ne 'Checking'){break}
            if((Get-Date) -ge $deadline){throw 'Guardian is still verifying its host; its running verification was preserved.'}
            Start-Sleep -Milliseconds 500
        }
        $threads=@([GMenuTrayControl20260907]::Windows($process.Id) | Select-Object -ExpandProperty Thread -Unique)
        if($threads.Count -ne 1){throw 'Guardian tray message loop could not be identified safely.'}
        [GMenuTrayControl20260907]::Quit([uint32]$threads[0])
    }
    $deadline=(Get-Date).AddSeconds(25)
    while(@(Get-GMenuOwnedProcess $Root).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if(@(Get-GMenuOwnedProcess $Root).Count) { throw 'App did not close cleanly. Backup/restore stopped before replacing its data.' }
    }catch{Resume-GMenuServices $Root;throw}
}
function Start-GMenuConsoleExecutable([string]$Root,$Manifest,[string]$Exe,[string[]]$Arguments,[switch]$NoWait) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Exe
    $start.Arguments=(@($Arguments | ForEach-Object {[GMenuPayload20260907]::Quote(([string]$_))}) -join ' ')
    $start.WorkingDirectory=[IO.Path]::GetDirectoryName($Exe)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($start)
    if(-not $process){throw 'Console application launcher process could not be started.'}
    [void]$process.Handle
    if($NoWait){return [int]$process.Id}
    $deadline=(Get-Date).AddSeconds(5)
    do {
        $process.Refresh()
        if($process.HasExited) {
            $code=[int]$process.ExitCode
            if($code -ne 0){throw ('Console application launcher exited with code {0}: {1}' -f $code,$Exe)}
            $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail='Console launcher completed successfully; no GUI window was expected.'}
            return [int]$process.Id
        }
        $owned=@(Get-GMenuOwnedProcess $Root | Where-Object Id -eq $process.Id)
        if($owned.Count) {
            $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail=('Console application is running without a GUI window (process {0}).' -f [int]$process.Id)}
            return [int]$process.Id
        }
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    throw 'Console application did not remain owned by the restored folder during startup verification.'
}
function Start-GMenuApp([string]$Root,$Manifest,[switch]$NoWait) {
    $script:GMenuLaunchHealth=$null
    # Upgrade metadata from commands published before script launchers were supported.
    if(-not $Manifest.LaunchKind -and $Manifest.Folder -in @('Jackett','Prowlarr','FlareSolverr')) {
        $relative='Start-'+$Manifest.Folder+'Portable.ps1'
        if(Test-Path -LiteralPath (Join-Path $Root $relative)) {
            $Manifest.Launcher=$relative
            $Manifest | Add-Member -NotePropertyName LaunchKind -NotePropertyValue 'HttpScript' -Force
            $uri=switch($Manifest.Folder){'Jackett'{'http://127.0.0.1:9117/api/v2.0/server/config'} 'Prowlarr'{'http://127.0.0.1:9696/ping'} 'FlareSolverr'{'http://127.0.0.1:8191/'}}
            $Manifest | Add-Member -NotePropertyName ReadinessUri -NotePropertyValue $uri -Force
        }
    }
    Resume-GMenuServices $Root
    foreach($record in @($Manifest.WindowsServices | Where-Object {$_ -and $_.WasRunning})) {
        if((Get-Service -Name $record.Name).Status -ne 'Running'){Start-Service -Name $record.Name -ErrorAction Stop}
    }
    $exe=[IO.Path]::GetFullPath((Join-Path $Root ([string]$Manifest.Launcher)))
    if($Manifest.LaunchKind -eq 'Directory') {
        (New-Object -ComObject Shell.Application).Explore($Root)
        $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail='Content restored and folder opened.'}
        return 0
    }
    if(-not $exe.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Recorded application launcher is missing or outside its folder.' }
    $arguments=@($Manifest.Arguments | ForEach-Object { ([string]$_).Replace('{AppRoot}',$Root) })
    $legacyConsole=($Manifest.LaunchKind -eq 'Exe' -and (Get-GMenuExecutableSubsystem $exe) -eq 'WindowsCui')
    if($Manifest.LaunchKind -eq 'Console' -or $legacyConsole) {
        if(-not @($arguments).Count) {
            (New-Object -ComObject Shell.Application).Explore($Root)
            $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail='Console launcher has no recorded arguments; restored folder opened without guessing a command.'}
            return 0
        }
        return (Start-GMenuConsoleExecutable $Root $Manifest $exe $arguments -NoWait:$NoWait)
    }
    if($Manifest.LaunchKind -in @('PowerShell','HttpScript','Command','Content')) {
        return (Start-GMenuScriptOrContent $Root $Manifest $exe $arguments -NoWait:$NoWait)
    }
    if($Manifest.Folder -ieq 'tv' -and $Manifest.Launcher -ieq 'tizen\moonlight-setup-guardian\bin\MoonlightSetupGuardian.exe'){Initialize-GMenuGuardianRuntime $exe}
    $line=(@($arguments | ForEach-Object {[GMenuPayload20260907]::Quote($_)}) -join ' ')
    $shell=New-Object -ComObject Shell.Application
    $shell.ShellExecute($exe,$line,[IO.Path]::GetDirectoryName($exe),'open',1)
    if($NoWait) {return}
    if($Manifest.Folder -ieq 'tv' -and $Manifest.Launcher -ieq 'tizen\moonlight-setup-guardian\bin\MoonlightSetupGuardian.exe') {
        Initialize-GMenuTrayControl
        $deadline=(Get-Date).AddSeconds(30)
        do {
            $responsive=@();$start=-1
            foreach($process in @(Get-GMenuGuardianProcess $Root)) {
                $windows=@([GMenuTrayControl20260907]::Windows($process.Id))
                $responsive=@($windows | Where-Object {[GMenuTrayControl20260907]::Responsive($_.Handle)})
                $log=Join-Path ([IO.Path]::GetDirectoryName($exe)) 'logs\guardian.log'
                $lines=if(Test-Path -LiteralPath $log){@(Get-Content -LiteralPath $log -Tail 150 -ErrorAction SilentlyContinue)}else{@()}
                # Exclude archived log entries bundled in the backup.
                $since=$process.StartTime.AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
                $start=-1
                for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} === Guardian pass ' -and [string]::CompareOrdinal($lines[$i].Substring(0,19),$since) -ge 0){$start=$i}}
                if($responsive.Count -and $start -ge 0) {
                    $health=Get-GMenuGuardianHealth @($lines[$start..($lines.Count-1)])
                    if($health.Status -in @('Verified','NeedsAttention')) {
                        $script:GMenuLaunchHealth=$health
                        if($health.Status -eq 'NeedsAttention'){Write-Warning ('Guardian tray opened, but its host setup needs repair: '+$health.Detail+' Log: '+$log)}
                        return [int]$process.Id
                    }
                }
            }
            Start-Sleep -Milliseconds 250
        }while((Get-Date) -lt $deadline)
        if($responsive.Count -and $start -ge 0){$script:GMenuLaunchHealth=[pscustomobject]@{Status='Checking';Detail='Guardian tray is responsive; host verification is still running.'};Write-Warning $script:GMenuLaunchHealth.Detail;return [int]$process.Id}
        throw 'Guardian did not initialize a responsive tray message loop and a fresh verification pass.'
    }
    if($Manifest.Folder -ieq 'tailscale') {
        $deadline=(Get-Date).AddSeconds(30)
        do {
            $tray=@(Get-GMenuOwnedProcess $Root | Where-Object ProcessName -eq 'tailscale-ipn')
            $state=& (Join-Path $Root 'tailscale.exe') status --json 2>$null | ConvertFrom-Json
            if($LASTEXITCODE -eq 0 -and $state.BackendState -eq 'Running' -and $state.Self.Online -and $tray.Count){return [int]$tray[0].Id}
            Start-Sleep -Milliseconds 500
        }while((Get-Date) -lt $deadline)
        throw 'Tailscale did not return to its connected, signed-in state.'
    }
    if($Manifest.Folder -ieq 'Whisper') {
        Initialize-GMenuTrayControl
        $deadline=(Get-Date).AddSeconds(90)
        do {
            $main=@(Get-GMenuWhisperProcess $Root | Where-Object {$_.Path -ieq (Join-Path $Root 'Runtime\v20-lexical\WhisperSTT.exe')})
            $server=@(Get-GMenuWhisperProcess $Root | Where-Object {$_.Path -ieq (Join-Path $Root 'Runtime\v20-lexical\Release\whisper-server.exe')})
            if($main.Count -eq 1 -and $server.Count -eq 1) {
                $windows=@([GMenuTrayControl20260907]::Windows($main[0].Id))
                $shutdown=@($windows | Where-Object {$_.Title -ceq 'Whisper.cpp STT' -and [GMenuTrayControl20260907]::Responsive($_.Handle)})
                $listener=@(Get-GMenuOwnedListener $Root 18178 | Where-Object OwningProcess -eq $server[0].Id)
                if($shutdown.Count -eq 1 -and $listener.Count -eq 1) {
                    $health=Get-GMenuWebHealth ([uri]'http://127.0.0.1:18178/health')
                    if($health -eq 'Verified') {
                        $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail='Whisper UI message loop and local transcription server are responsive.'}
                        return [int]$main[0].Id
                    }
                }
            }
            Start-Sleep -Milliseconds 250
        }while((Get-Date) -lt $deadline)
        throw 'Whisper did not initialize its responsive UI message loop and local transcription server.'
    }
    $deadline=(Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $visible=@(Get-GMenuOwnedProcess $Root | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Responding })
    } while(-not $visible.Count -and (Get-Date) -lt $deadline)
    if(-not $visible.Count) { throw 'No responsive app window appeared; previous installation retained for recovery.' }
    Start-Sleep -Seconds 3
    if(-not @(Get-GMenuOwnedProcess $Root | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Responding }).Count) { throw 'App exited during startup verification.' }
    return [int]$visible[0].Id
}
function Test-GMenuDaymarkSession($Manifest) {
    if(-not $Manifest.DaymarkSyncKey) { return $null }
    if([string]$Manifest.DaymarkSyncKey -notmatch '^[A-Za-z0-9_-]{22}$') { throw 'Invalid saved Daymark pairing.' }
    try {
        $state=Invoke-RestMethod -UseBasicParsing -Uri ('https://daymark-desktop.michaelovsky55555.chatgpt.site/api/sync/'+$Manifest.DaymarkSyncKey) -TimeoutSec 30 -MaximumRedirection 0
        if($null -eq $state.state.tasks -or $null -eq $state.state.projects) { throw 'Missing workspace state.' }
        $tasks=if($state.state.tasks -is [array]){@($state.state.tasks).Count}else{@($state.state.tasks.PSObject.Properties).Count}
        $projects=if($state.state.projects -is [array]){@($state.state.projects).Count}else{@($state.state.projects.PSObject.Properties).Count}
        return [pscustomobject]@{Status='SessionVerified';Tasks=$tasks;Projects=$projects;Revision=$state.revision}
    } catch { throw 'Saved Daymark workspace pairing did not verify. No logged-in readiness claim was made.' }
}
function Write-GMenuProgress([string]$Phase,[long]$Done=0,[long]$Total=0,[string]$Detail='') {
    if(-not $script:GMenuProgressStartedAt) {$script:GMenuProgressStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()}
    $elapsed=[int64](([Diagnostics.Stopwatch]::GetTimestamp()-$script:GMenuProgressStartedAt)*1000/[Diagnostics.Stopwatch]::Frequency)
    $percent=if($Total -gt 0){[Math]::Min(100.0,[Math]::Max(0.0,100.0*[double]$Done/[double]$Total))}else{0.0}
    $value=$percent.ToString('F4',[Globalization.CultureInfo]::InvariantCulture)
    $progressDetail=if($Total -gt 0){"$Done/$Total"}else{"count=$Done total=unknown mode=indeterminate"}
    if($Detail){$progressDetail+=' detail='+$Detail}
    Write-Host ("GMENU {0} {1}% {2} elapsed_ms={3}" -f $Phase,$value,$progressDetail,$elapsed)
}
function Write-GMenuHeartbeat([string]$Phase,[string]$Detail='') {
    # Kept as a compatibility shim for already-generated restore commands.  The
    # timer-based generic heartbeat was removed; every line is now a real
    # progress record with an explicit percentage and elapsed time.
    $detail=if($Detail){$Detail}else{'stage-start'}
    Write-GMenuProgress $Phase 0 0 $detail
}
function Get-GMenuFileSystemEntry([string]$Root) {
    # PS5 recursive enumeration is provider-dependent around junctions. Walk
    # real directories explicitly; emit links once and never descend into them.
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while($pending.Count) {
        foreach($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            $item
            if($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending.Push($item.FullName)
            }
        }
    }
}
function Get-GMenuLinkTarget($Link) {
    # LinkType/Target are extended PowerShell properties and can be unavailable
    # in a reloaded session. Read the actual reparse point without following it.
    if (-not ('GMenuLinkReader20260907' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class GMenuLinkReader20260907 {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
    public static string Read(string path) {
        using(var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
            if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open link: "+path);
            byte[] data=new byte[16384]; uint count;
            if(!DeviceIoControl(handle,0x000900a8,IntPtr.Zero,0,data,(uint)data.Length,out count,IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read link: "+path);
            if(count<16) throw new IOException("Truncated reparse point: "+path);
            uint tag=BitConverter.ToUInt32(data,0);
            int start=tag==0xa0000003 ? 16 : tag==0xa000000c ? 20 : 0;
            if(start==0) throw new IOException("Unsupported filesystem link: "+path);
            int offset=BitConverter.ToUInt16(data,8), length=BitConverter.ToUInt16(data,10);
            if(length==0 || (length%2)!=0 || start+offset+length>count)
                throw new IOException("Invalid reparse target: "+path);
            string target=Encoding.Unicode.GetString(data,start+offset,length);
            if(target.StartsWith(@"\??\UNC\",StringComparison.OrdinalIgnoreCase)) return @"\\"+target.Substring(8);
            if(target.StartsWith(@"\??\",StringComparison.OrdinalIgnoreCase)) return target.Substring(4);
            return target;
        }
    }
}
'@
    }
    $target=$null
    # Real filesystem entries use the native reader. Test/older provider
    # records may carry only LinkType/Target metadata, so retain that supported
    # representation when there is no readable reparse handle.
    try {
        if(Test-Path -LiteralPath $Link.FullName -ErrorAction SilentlyContinue) {
            $target=[GMenuLinkReader20260907]::Read($Link.FullName)
        }
    } catch {
        if($Link.LinkType -notin @('Junction','SymbolicLink') -or -not @($Link.Target)[0]) { throw }
    }
    if(-not $target -and $Link.LinkType -in @('Junction','SymbolicLink') -and @($Link.Target)[0]) {
        $target=[string]@($Link.Target)[0]
    }
    if(-not $target){throw "Unsupported filesystem link: $($Link.FullName)"}
    if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path ([IO.Path]::GetDirectoryName($Link.FullName)) $target}
    [IO.Path]::GetFullPath($target).TrimEnd('\')
}
function Get-GMenuLinkRecord([string]$Root,$Link,[int]$DataIndex=-1) {
    $target=Get-GMenuLinkTarget $Link
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolved=$false
    for($hop=0;$hop -lt 128;$hop++) {
        if(-not $seen.Add($target)){throw "Cyclic filesystem link cannot be backed up: $($Link.FullName)"}
        if(-not $target.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)) {
            $mapped=$null
            # Preserve the existing explicit Archive mapping. A renamed sibling
            # is portable only when the old root is absent and names differ by
            # spaces, underscores or hyphens. Never import an external tree.
            if($DataIndex -lt 0 -and $target -match '^[a-zA-Z]:\\') {
                $archive=Join-Path $Root ('Archive\'+$target.Substring(0,1)+'\'+$target.Substring(3))
                if(Test-Path -LiteralPath $archive){$mapped=$archive}
            }
            $parent=[IO.Path]::GetDirectoryName($Root)
            if(-not $mapped -and $target.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)) {
                $tail=$target.Substring($parent.Length+1)
                $separator=$tail.IndexOf('\')
                if($separator -gt 0) {
                    $oldName=$tail.Substring(0,$separator)
                    $oldRoot=Join-Path $parent $oldName
                    $sameName=($oldName -replace '[\s_-]','') -ieq ([IO.Path]::GetFileName($Root) -replace '[\s_-]','')
                    if($sameName -and -not (Test-Path -LiteralPath $oldRoot)) {
                        $mapped=Join-Path $Root $tail.Substring($separator+1)
                    }
                }
            }
            if(-not $mapped){throw "Link target is outside the captured application/data folder: $($Link.FullName) -> $target"}
            $target=$mapped
        }
        if($target -eq $Link.FullName -or $Link.FullName.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw "Cyclic filesystem link cannot be backed up: $($Link.FullName)"
        }
        # Resolve linked ancestors as well as the final entry. Store the final
        # physical in-root target so restoration does not depend on link order.
        $components=$target.Substring($Root.Length+1).Split('\')
        $cursor=$Root;$redirected=$false
        for($index=0;$index -lt $components.Length;$index++) {
            $cursor=Join-Path $cursor $components[$index]
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if(-not $item){throw "Link target is missing: $($Link.FullName) -> $cursor"}
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $target=Get-GMenuLinkTarget $item
                if($index+1 -lt $components.Length){$target=Join-Path $target ($components[($index+1)..($components.Length-1)] -join '\')}
                $target=[IO.Path]::GetFullPath($target).TrimEnd('\')
                $redirected=$true;break
            }
        }
        if(-not $redirected){$resolved=$true;break}
    }
    if(-not $resolved){throw "Filesystem link chain exceeds 128 hops: $($Link.FullName)"}
    [void](Assert-GMenuPath $target)
    [pscustomobject]@{Path=$Link.FullName.Substring($Root.Length+1);Target=$target.Substring($Root.Length+1);Kind=if($Link.PSIsContainer){'Junction'}else{'File'};DataIndex=$DataIndex}
}
function Restore-GMenuLink([string]$Root,$Link) {
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Link.Path));$target=[IO.Path]::GetFullPath((Join-Path $Root $Link.Target))
    if(-not $path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $target.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe restored link.'}
    [void](Assert-GMenuPath $path);[void](Assert-GMenuPath $target)
    if(Test-Path -LiteralPath $path){throw 'Restored link would overwrite an existing file.'}
    if($Link.Kind -eq 'File') {
        if(-not (Test-Path -LiteralPath $target -PathType Leaf)){throw 'Restored file link target is missing.'}
        # Hard links preserve shared model-cache bytes without requiring symlink privilege.
        [void](New-Item -ItemType HardLink -Path $path -Target $target -ErrorAction Stop)
    } else {
        if(-not (Test-Path -LiteralPath $target -PathType Container)){throw 'Restored directory link target is missing.'}
        [void](New-Item -ItemType Junction -Path $path -Target $target -ErrorAction Stop)
    }
}
function Get-GMenuLaunchSpec([string]$Root,[string]$Folder,[string]$Launcher) {
    $entry=$null
    $catalogHelper=Join-Path $PSScriptRoot 'Invoke-InstalledAppDockerRestoreAndLaunch.ps1'
    if(-not $Launcher -and (Test-Path -LiteralPath $catalogHelper)) {$entry=& $catalogHelper -Folder $Folder -CatalogOnly}
    if($entry -and $entry.Kind -eq 'PluginSync') {
        return [pscustomobject]@{Path='.';Kind='Directory';Arguments=@();Uri=$null}
    }
    if($Launcher){$path=if([IO.Path]::IsPathRooted($Launcher)){Assert-GMenuPath $Launcher}else{Assert-GMenuPath (Join-Path $Root $Launcher)}}
    elseif($entry.Path -and $entry.Kind -in @('PowerShell','HttpScript','Command','Content')) {
        $registeredPath=Assert-GMenuPath (Join-Path $Root $entry.Path)
        if(Test-Path -LiteralPath $registeredPath -PathType Leaf) {
            $path=$registeredPath
        } else {
            # Catalog metadata can outlive an installation or a partially
            # restored folder.  A missing implicit launcher is a data-only
            # backup case; an explicitly supplied -Launcher remains strict.
            Write-Host ("GMENU launch=directory reason=registered-launcher-missing path={0}" -f $entry.Path) -ForegroundColor Yellow
            return [pscustomobject]@{Path='.';Kind='Directory';Arguments=@();Uri=$null}
        }
    }
    else {
        $path=Resolve-GMenuLauncher $Root $Folder
        if(-not $path) {
            # A gmenu target may be a data/profile directory rather than an
            # application.  Start-GMenuApp already has a verified directory
            # restore path; use it when launcher discovery is empty or
            # ambiguous instead of failing before the backup can be planned.
            return [pscustomobject]@{Path='.';Kind='Directory';Arguments=@();Uri=$null}
        }
    }
    if(-not $path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Launcher must be an existing file inside the application folder.'}
    $extension=[IO.Path]::GetExtension($path).ToLowerInvariant()
    $kind=if($entry -and $entry.Kind -eq 'Content'){'Content'}elseif($entry -and $entry.Kind -eq 'HttpScript'){'HttpScript'}else{switch($extension){'.exe'{'Exe'} '.ps1'{'PowerShell'} '.cmd'{'Command'} '.bat'{'Command'} default{throw 'Use an EXE, PowerShell script, CMD/BAT launcher, or a registered content entry.'}}}
    if($kind -eq 'Exe' -and (Get-GMenuExecutableSubsystem $path) -eq 'WindowsCui'){$kind='Console'}
    $uri=$entry.Uri
    # These applications intentionally expose a local web UI instead of a desktop window.
    if($kind -eq 'PowerShell' -and $Folder -in @('Jackett','Prowlarr') -and [IO.Path]::GetFileName($path) -ieq ('Start-'+$Folder+'Portable.ps1')) {
        $kind='HttpScript';$uri=if($Folder -ieq 'Jackett'){'http://127.0.0.1:9117/api/v2.0/server/config'}else{'http://127.0.0.1:9696/ping'}
    }
    [pscustomobject]@{Path=$path.Substring($Root.Length+1);Kind=$kind;Arguments=@($entry.Arguments | Where-Object {$null -ne $_});Uri=$uri}
}
function Get-GMenuOwnedListener([string]$Root,[int]$Port) {
    $owned=@(Get-GMenuOwnedProcess $Root)
    # netstat is available even on Windows installations missing NetTCPIP/CIM providers.
    $rows=& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp
    if($LASTEXITCODE -ne 0){throw 'Could not inspect local listener ownership.'}
    foreach($row in $rows) {
        if($row -match ('^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):'+$Port+'\s+0\.0\.0\.0:0\s+\S+\s+(\d+)\s*$')) {
            $owner=[int]$matches[1]
            if($owned.Id -contains $owner){[pscustomobject]@{OwningProcess=$owner;Port=$Port}}
        }
    }
}
function Get-GMenuWebHealth([uri]$Uri) {
    if($Uri.Scheme -ne 'http' -or $Uri.Host -ne '127.0.0.1'){throw 'Web readiness must use the recorded local loopback endpoint.'}
    try {
        $response=Invoke-WebRequest -UseBasicParsing -Uri $Uri.AbsoluteUri -TimeoutSec 2 -MaximumRedirection 0 -ErrorAction Stop
        if($response.StatusCode -eq 200){return 'Verified'}
    }catch {
        $response=$_.Exception.Response
        if($response) {
            $status=[int]$response.StatusCode
            if($status -in @(401,403)){return 'AuthenticationRequired'}
            if($status -in @(301,302,303,307,308)) {
                $location=[string]$response.Headers.Location
                if(-not $location){$location=[string]$response.Headers['Location']}
                $redirect=New-Object Uri($Uri,$location)
                if($redirect.Authority -eq $Uri.Authority -and $redirect.AbsolutePath -match '(?i)/login/?$'){return 'AuthenticationRequired'}
            }
        }
    }
    return 'Checking'
}
function Repair-GMenuPythonLauncher([string]$Root,[string]$Launcher) {
    # Windows venv console .exe launchers embed the absolute interpreter path
    # that existed when the venv was built.  After a restore to another folder
    # that path can be dead even though the portable Python installation and
    # package sources are complete.  Repair only a declared pyproject entry
    # point, and only when its embedded interpreter is stale.
    $script:GMenuPythonRepairCount=0
    $pyproject=Join-Path $Root 'pyproject.toml'
    $venvScripts=Join-Path $Root '.venv\Scripts'
    $python=Join-Path $venvScripts 'python.exe'
    if(-not (Test-Path -LiteralPath $pyproject -PathType Leaf) -or
       -not (Test-Path -LiteralPath $venvScripts -PathType Container) -or
       -not (Test-Path -LiteralPath $python -PathType Leaf) -or
       -not (Test-Path -LiteralPath $Launcher -PathType Leaf)){return}
    $entries=@()
    $inScripts=$false
    foreach($line in Get-Content -LiteralPath $pyproject -ErrorAction Stop) {
        if($line -match '^\s*\[project\.scripts\]\s*$'){$inScripts=$true;continue}
        if($inScripts -and $line -match '^\s*\['){break}
        if($inScripts -and $line -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*["'']([^"'']+:[A-Za-z_][A-Za-z0-9_]*)["'']\s*$') {
            $entries+=[pscustomobject]@{Name=[string]$matches[1];Target=[string]$matches[2]}
        }
    }
    if(-not $entries.Count){return}
    $launcherText=[IO.File]::ReadAllText($Launcher)
    $updatedText=$launcherText
    $pythonSourceRoot=Join-Path $Root 'src'
    if((Test-Path -LiteralPath $pythonSourceRoot -PathType Container) -and
       [IO.Path]::GetExtension($Launcher) -in @('.cmd','.bat') -and
       $launcherText -notmatch '(?im)^\s*set\s+"PYTHONPATH=') {
        $pythonPathLine='set "PYTHONPATH='+$pythonSourceRoot+';%PYTHONPATH%"'
        $newline=if($launcherText.Contains("`r`n")){"`r`n"}else{"`n"}
        $updatedText=[regex]::Replace($updatedText,'(?im)^(@echo\s+off\r?\n)',{param($m)$m.Groups[1].Value+$pythonPathLine+$newline},1)
    }
    foreach($entry in $entries) {
        $console=Join-Path $venvScripts ($entry.Name+'.exe')
        if(-not (Test-Path -LiteralPath $console -PathType Leaf)){continue}
        $consoleText=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($console))
        $embedded=@()
        foreach($match in [regex]::Matches($consoleText,'(?i)([a-z]:\\[^"\x00]{1,240}\\python(?:w)?\.exe)')){$embedded+=$match.Groups[1].Value}
        if(-not $embedded.Count){continue}
        $currentPython=[IO.Path]::GetFullPath($python)
        $stale=$false
        foreach($oldPath in $embedded) {
            try {if(-not [IO.Path]::GetFullPath($oldPath).Equals($currentPython,[StringComparison]::OrdinalIgnoreCase)){$stale=$true;break}}
            catch {$stale=$true;break}
        }
        if(-not $stale){continue}
        $safeName=($entry.Name -replace '[^A-Za-z0-9_.-]','_')
        $shim=Join-Path $venvScripts ('gmenu-entrypoint-'+$safeName+'.py')
        $targetParts=$entry.Target.Split(':',2)
        if($targetParts.Count -ne 2){continue}
        $shimText="import sys`r`nfrom $($targetParts[0]) import $($targetParts[1])`r`nsys.argv[0] = '$($entry.Name.Replace("'","''"))'`r`nresult = $($targetParts[1])()`r`nif result is not None:`r`n    raise SystemExit(result)`r`n"
        if(Test-Path -LiteralPath $shim -PathType Leaf) {
            if([IO.File]::ReadAllText($shim) -cne $shimText){throw "Existing gmenu Python entrypoint shim differs: $shim"}
        } else {[IO.File]::WriteAllText($shim,$shimText,(New-Object Text.UTF8Encoding($false)))}
        $pattern='(?i)"(?<prefix>[^"\r\n]*?)\.venv\\Scripts\\'+[regex]::Escape($entry.Name)+'\.exe"'
        $replacement=[regex]::Replace($updatedText,$pattern,{param($m) '"'+$m.Groups['prefix'].Value+'.venv\Scripts\python.exe" "'+$m.Groups['prefix'].Value+'.venv\Scripts\gmenu-entrypoint-'+$safeName+'.py"'})
        if($replacement -cne $updatedText){
            $updatedText=$replacement
            Write-Verbose ("GMENU python-launcher-repair entry={0} root={1}" -f $entry.Name,$Root)
        }
    }
    if($updatedText -cne $launcherText) {
        $backupRoot=Join-Path (Get-GMenuStateRoot) 'CodeBackups\PythonLaunchers'
        [void][IO.Directory]::CreateDirectory($backupRoot)
        $hash=(Get-FileHash -LiteralPath $Launcher -Algorithm SHA256).Hash.ToLowerInvariant().Substring(0,16)
        $backup=Join-Path $backupRoot (([IO.Path]::GetFileName($Launcher))+'.'+$hash+'.bak')
        if(-not (Test-Path -LiteralPath $backup -PathType Leaf)){Copy-Item -LiteralPath $Launcher -Destination $backup -Force}
        [IO.File]::WriteAllText($Launcher,$updatedText,(New-Object Text.UTF8Encoding($false)))
        $script:GMenuPythonRepairCount=1
    }
}
function Start-GMenuScriptOrContent([string]$Root,$Manifest,[string]$Launcher,[string[]]$Arguments,[switch]$NoWait) {
    if($Manifest.LaunchKind -eq 'Content') {
        (New-Object -ComObject Shell.Application).Open($Launcher)
        $script:GMenuLaunchHealth=[pscustomobject]@{Status='Verified';Detail='Content restored and opened.'}
        return 0
    }
    if($Manifest.Folder -in @('Jackett','Prowlarr') -and [IO.Path]::GetFileName($Launcher) -ieq ('Start-'+$Manifest.Folder+'Portable.ps1')) {
        # Repair the same known quoting bug in scripts recovered from older images.
        $old=[IO.File]::ReadAllText($Launcher)
        $new=$old.Replace('-WorkingDirectory (Split-Path -Parent $Exe)','-WorkingDirectory ([WildcardPattern]::Escape((Split-Path -Parent $Exe)))')
        $new=$new.Replace('''--DataFolder'', $Data','''--DataFolder'', (''"''+$Data+''"'')')
        $new=$new.Replace('"-data=$Data"','(''"-data=''+$Data+''"'')')
        if($new -cne $old){[IO.File]::WriteAllText($Launcher,$new,(New-Object Text.UTF8Encoding($false)))}
    }
    Repair-GMenuPythonLauncher $Root $Launcher
    if($Manifest.LaunchKind -eq 'Command') {
        $hostExe=Join-Path $env:SystemRoot 'System32\cmd.exe'
        $line='/d /s /c ""'+$Launcher+'" '+(@($Arguments | ForEach-Object {[GMenuPayload20260907]::Quote($_)}) -join ' ')+'"'
    }else {
        $hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $line='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+[GMenuPayload20260907]::Quote($Launcher)+' '+(@($Arguments | ForEach-Object {[GMenuPayload20260907]::Quote($_)}) -join ' ')
    }
    # ProcessStartInfo treats the working directory literally; PS5 Start-Process
    # expands square brackets as wildcard syntax even for a verified real path.
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$hostExe;$start.Arguments=$line;$start.WorkingDirectory=[IO.Path]::GetDirectoryName($Launcher)
    # Command launchers are interactive applications (for example HereticAI's
    # terminal UI). Give them a real console window so the successful restore
    # leaves the application usable immediately; script launchers remain
    # hidden while their readiness checks run.
    $interactive=[bool]($Manifest.LaunchKind -eq 'Command' -and $Manifest.Interactive -ne $false)
    if($interactive -and [IO.Path]::GetExtension($Launcher) -in @('.cmd','.bat')) {
        # ShellExecute can create the independent console directly for a batch
        # launcher; wrapping it in another /c command loses quoting for paths
        # containing spaces and reports a false exit code.
        $hostExe=$Launcher
        $line=(@($Arguments | ForEach-Object {[GMenuPayload20260907]::Quote($_)}) -join ' ')
    }
    if($interactive) {
        # A separate shell-owned console survives the restore host closing;
        # inheriting the host console would terminate the app with the shell.
        $start.UseShellExecute=$true;$start.CreateNoWindow=$false
        $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Normal
    } else {
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    }
    $pythonSource=Join-Path $Root 'src'
    if(-not $interactive -and (Test-Path -LiteralPath $pythonSource -PathType Container) -and
       @(Get-ChildItem -LiteralPath $pythonSource -Directory -Force -ErrorAction SilentlyContinue | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName '__init__.py') -PathType Leaf}).Count) {
        $existingPythonPath=[string]$start.EnvironmentVariables['PYTHONPATH']
        $start.EnvironmentVariables['PYTHONPATH']=if($existingPythonPath){$pythonSource+';'+$existingPythonPath}else{$pythonSource}
    }
    $process=[Diagnostics.Process]::Start($start)
    if(-not $process){throw 'Application launcher process could not be started.'}
    # Retain the handle before a short launcher exits, so PS5/PS7 can read its exit code.
    [void]$process.Handle
    if($NoWait){return}
    if($interactive -and $Manifest.LaunchKind -eq 'Command') {
        # Interactive terminal applications (for example HereticAI) own the
        # console that was just opened.  Waiting for the command wrapper to
        # exit makes a successful launch look hung forever while the app is
        # still running.  Verify the handoff briefly, then return the live
        # launcher/child PID so restore can finish and the user can use it.
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if($process.HasExited -and $process.ExitCode -ne 0) {
            throw "Interactive application launcher exited with code $($process.ExitCode): $Launcher"
        }
        $script:GMenuLaunchHealth=[pscustomobject]@{
            Status='Verified'
            Detail='Interactive command console opened; readiness is owned by the application.'
        }
        return [int]$process.Id
    }
    $deadline=(Get-Date).AddSeconds(90)
    do {
        $process.Refresh()
        if($process.HasExited){$process.WaitForExit()}
        if($Manifest.LaunchKind -eq 'Command') {
            $owned=@(Get-GMenuOwnedProcess $Root | Where-Object {$_.Id -ne $process.Id})
            if($owned.Count) {
                $owner=$owned | Select-Object -First 1
                $script:GMenuLaunchHealth=[pscustomobject]@{
                    Status='Verified'
                    Detail=('Command launcher has an owned application process running (process {0}).' -f [int]$owner.Id)
                }
                return [int]$owner.Id
            }
        }
        if($process.HasExited -and $process.ExitCode -ne 0) {
            # Portable launchers commonly hand off to a child process and then
            # return the child's exit code.  A nonzero wrapper code is not a
            # restore failure when the owned application is actually running.
            # Give the handoff a bounded grace period, then verify ownership
            # from the restored folder before deciding whether to fail.
            $handoffDeadline=(Get-Date).AddSeconds(15)
            $owned=@()
            do {
                $owned=@(Get-GMenuOwnedProcess $Root)
                if($owned.Count){break}
                if((Get-Date) -ge $handoffDeadline){break}
                Start-Sleep -Milliseconds 250
            }while($true)
            if($owned.Count) {
                $owner=$owned | Select-Object -First 1
                $script:GMenuLaunchHealth=[pscustomobject]@{
                    Status='Verified'
                    Detail=('Launcher handed off to an owned application process (wrapper exit code {0}; process {1}).' -f [int]$process.ExitCode,[int]$owner.Id)
                }
                return [int]$owner.Id
            }
            throw "Application launcher exited with code $($process.ExitCode) and no owned application process was found: $Launcher"
        }
        if($Manifest.LaunchKind -eq 'HttpScript') {
            $uri=[uri]$Manifest.ReadinessUri
            if($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1'){throw 'Web readiness must use the recorded local loopback endpoint.'}
            $listener=@(Get-GMenuOwnedListener $Root $uri.Port)
            if($listener.Count) {
                $health=Get-GMenuWebHealth $uri
                if($health -in @('Verified','AuthenticationRequired') -and $process.HasExited -and $process.ExitCode -eq 0) {
                    $script:GMenuLaunchHealth=[pscustomobject]@{Status=$health;Detail=('Owned local web service is responsive: '+$uri.GetLeftPart([UriPartial]::Authority))}
                    if($health -eq 'AuthenticationRequired'){Write-Warning 'Application is running and requires sign-in. Saved authentication was preserved; a login page is not counted as a verified session.'}
                    return [int]$listener[0].OwningProcess
                }
            }
        }elseif($process.HasExited) {
            $script:GMenuLaunchHealth=[pscustomobject]@{Status='NotVerified';Detail='Launcher completed successfully; this script has no application-specific readiness check.'}
            return [int]$process.Id
        }
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    throw 'Application launcher did not complete its recorded readiness check within 90 seconds.'
}
function Resolve-GMenuLauncher([string]$Root,[string]$Folder) {
    # Read the same app mapping used by the existing g<app> commands, without
    # loading a profile, contacting Docker Hub, or starting a restore.
    $catalogHelper=Join-Path $PSScriptRoot 'Invoke-InstalledAppDockerRestoreAndLaunch.ps1'
    if(Test-Path -LiteralPath $catalogHelper -PathType Leaf) {
        $registered=& $catalogHelper -Folder $Folder -CatalogOnly
        if($registered -and $registered.Kind -eq 'Exe' -and $registered.Path) {
            $relative=[string]$registered.Path
            if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.($|[\\/])|:'){throw 'Registered app launcher must be relative to the selected folder.'}
            $known=[IO.Path]::GetFullPath((Join-Path $Root $relative))
            if($known.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($known) -ieq '.exe' -and (Test-Path -LiteralPath $known -PathType Leaf)) {
                return (Assert-GMenuPath $known)
            }
        }
    }
    # Prefer an explicit top-level start script before inspecting recursive
    # binaries. Portable applications often need that script to establish
    # their private profile/data/temp environment; launching an internal EXE
    # directly would silently bypass the portable contract.
    $rootScripts=@(Get-ChildItem -LiteralPath $Root -File | Where-Object {
        $_.Extension -in @('.cmd','.bat','.ps1') -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    })
    [string[]]$preferredScriptNames=@(('Start '+$Folder),('Start-'+$Folder),('Launch '+$Folder),('Launch-'+$Folder),$Folder)
    foreach($preferredScript in $preferredScriptNames) {
        $match=@($rootScripts | Where-Object BaseName -ieq $preferredScript)
        if(-not $match.Count) {
            $normalized=$preferredScript -replace '[\s_-]',''
            $match=@($rootScripts | Where-Object {($_.BaseName -replace '[\s_-]','') -ieq $normalized})
        }
        if($match.Count -eq 1){return (Assert-GMenuPath $match[0].FullName)}
        # Portable apps may ship the same entry point in several shell formats.
        # Prefer the command wrapper (which commonly forwards arguments), then
        # batch, then PowerShell; explicit -Launcher still overrides detection.
        if($match.Count -gt 1) {
            foreach($extension in @('.cmd','.bat','.ps1')) {
                $formatMatch=@($match | Where-Object Extension -ieq $extension)
                if($formatMatch.Count -eq 1){return (Assert-GMenuPath $formatMatch[0].FullName)}
                if($formatMatch.Count -gt 1){throw "Multiple top-level launch scripts match $preferredScript$extension; use -Launcher to select the intended copy."}
            }
        }
    }
    $rootExecutables=@(Get-ChildItem -LiteralPath $Root -File -Filter '*.exe' | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    $compact=$Folder -replace '[\s_-]',''
    [string[]]$preferredNames=@(('Start-'+$Folder),($Folder+'Portable'),$Folder,($compact+'Launcher'),$compact)
    foreach($preferred in $preferredNames) {
        $match=@($rootExecutables | Where-Object BaseName -eq $preferred)
        if($match.Count -eq 1){return $match[0].FullName}
    }
    Write-GMenuProgress 'detect-launcher'
    $pending=New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($Root)
    $candidates=New-Object 'Collections.Generic.List[IO.FileInfo]'
    $clock=[Diagnostics.Stopwatch]::StartNew();$visited=0
    while($pending.Count) {
        $directory=$pending.Dequeue();$visited++
        if($clock.ElapsedMilliseconds -ge 250){Write-GMenuProgress 'detect-launcher' $visited;$clock.Restart()}
        foreach($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($entry.PSIsContainer) {
                if($entry.Name -notmatch '^(?i:archive|archives|backup|backups|downloads|migration|\.git|node_modules)$|^\.(docker|gmenu)-'){$pending.Enqueue($entry.FullName)}
            }elseif($entry.Extension -ieq '.exe' -and $entry.BaseName -notmatch '(?i)unins|update|crash|helper|setup|install|runtime') {
                $candidates.Add($entry)
            }
        }
    }
    foreach($preferred in $preferredNames) {
        $match=@($candidates | Where-Object BaseName -eq $preferred)
        if($match.Count -eq 1){return $match[0].FullName}
        if($match.Count -gt 1) {
            # Multiple release folders: compare their version directory only when
            # every candidate has the same layout, so arbitrary copies do not win.
            $releases=@(foreach($candidate in $match) {
                $relative=$candidate.FullName.Substring($Root.TrimEnd('\').Length+1)
                if($relative -match '^(.*?)(?:^|\\)v?(\d+\.\d+(?:\.\d+){0,2})(\\.*)$') {
                    [pscustomobject]@{File=$candidate;Layout=($matches[1]+'{version}'+$matches[3]);Version=[version]$matches[2]}
                }
            })
            if($releases.Count -eq $match.Count -and @($releases.Layout | Select-Object -Unique).Count -eq 1) {
                $ordered=@($releases | Sort-Object Version -Descending)
                if($ordered[0].Version -gt $ordered[1].Version){return $ordered[0].File.FullName}
            }
            throw "Multiple installed launchers match $preferred; use -Launcher to select the intended copy."
        }
    }
    if($candidates.Count -eq 1){return $candidates[0].FullName}
    if($candidates.Count -gt 1){Write-Host 'GMENU launch=directory reason=launcher-ambiguous' -ForegroundColor Yellow}
    else {Write-Host 'GMENU launch=directory reason=no-launcher' -ForegroundColor Yellow}
    return $null
}
function Save-GMenuFunctionDefinition([string]$Name,[string]$ProfileSource,[switch]$UpgradeExisting) {
    if($Name -notmatch '^g[a-zA-Z0-9]+$' -or $Name -eq 'gmenu') {throw 'Invalid generated function name.'}
    # The generated command itself is the durable source of truth.  Profile
    # files are C: bootstrap artifacts and are intentionally never rewritten
    # by GMenu.  Keep an F: audit record for callers that still invoke this
    # compatibility function.
    $recordRoot=Join-Path (Get-GMenuStateRoot) 'CommandHistory\ProfileDefinitions'
    Protect-GMenuDirectory $recordRoot
    $record=Join-Path $recordRoot ($Name+'.ps1')
    $body=("function {0} {{`r`n    Invoke-GMenuSavedCommand -Name '{0}' -Arguments `$args`r`n}}" -f $Name)
    [IO.File]::WriteAllText($record,$body,(New-Object Text.UTF8Encoding($true)))
}
function Register-GMenuPortableCommand($Ticket,[string]$SourceScript,[switch]$UpgradeExisting) {
    if(-not $Ticket.Function -or $Ticket.Function -notmatch '^g[a-zA-Z0-9]+$' -or
       -not $SourceScript -or -not (Test-Path -LiteralPath $SourceScript)) {return}
    $content=[IO.File]::ReadAllText($SourceScript)
    if(-not $content.StartsWith('# GMENU GENERATED RESTORE COMMAND')) {return}
    $commandRoot=Join-Path (Get-GMenuStateRoot) 'Commands'
    Protect-GMenuDirectory $commandRoot
    $destination=Join-Path $commandRoot ($Ticket.Function+'.ps1')
    if($SourceScript -ine $destination) {
        if((Test-Path -LiteralPath $destination) -and
           -not ([IO.File]::ReadAllText($destination)).StartsWith('# GMENU GENERATED RESTORE COMMAND')) {throw 'An unrelated restore script already exists at the installation path.'}
        [IO.File]::WriteAllText($destination,$content,(New-Object Text.UTF8Encoding($false)))
    }
    # Keep an independent protected copy.  The profile wrapper is intentionally
    # only a dispatcher; this copy is the recovery source if the live command
    # file is removed or replaced by an unrelated script.
    $commandBackupRoot=Join-Path (Get-GMenuStateRoot) 'CommandBackups'
    Protect-GMenuDirectory $commandBackupRoot
    $commandBackup=Join-Path $commandBackupRoot ($Ticket.Function+'.ps1')
    $commandBackupTemporary=$commandBackup+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($commandBackupTemporary,$content,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $commandBackupTemporary -Destination $commandBackup -Force -ErrorAction Stop
    } finally {
        if(Test-Path -LiteralPath $commandBackupTemporary){Remove-Item -LiteralPath $commandBackupTemporary -Force -ErrorAction SilentlyContinue}
    }
    # Keep a second recovery copy outside the live command directory.  The
    # command directory is intentionally removable by maintenance commands;
    # losing it must not strand a published restore ticket and its private
    # decryption key.
    $fallbackRoot=Join-Path (Get-GMenuStateRoot) 'Fallback'
    $fallbackCommandRoot=Join-Path $fallbackRoot 'Commands'
    $fallbackBackupRoot=Join-Path $fallbackRoot 'CommandBackups'
    Protect-GMenuDirectory $fallbackCommandRoot
    Protect-GMenuDirectory $fallbackBackupRoot
    $fallbackDestination=Join-Path $fallbackCommandRoot ($Ticket.Function+'.ps1')
    $fallbackBackup=Join-Path $fallbackBackupRoot ($Ticket.Function+'.ps1')
    [IO.File]::WriteAllText($fallbackDestination,$content,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($fallbackBackup,$content,(New-Object Text.UTF8Encoding($false)))
    $fallbackReceipt=[ordered]@{
        Function=[string]$Ticket.Function
        Source=[string]$Ticket.Target
        Repository=[string]$Ticket.Repository
        Tag=[string]$Ticket.Tag
        Digest=[string]$Ticket.Digest
        Script=$fallbackDestination
        VerifiedRestore=$false
    }
    [IO.File]::WriteAllText((Join-Path $fallbackCommandRoot ($Ticket.Function+'.receipt.json')),($fallbackReceipt | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    if($UpgradeExisting) {
        $previous=Get-Command $Ticket.Function -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if($previous) {
            $history=Join-Path (Get-GMenuStateRoot) ('CommandHistory\'+$Ticket.Function)
            Protect-GMenuDirectory $history
            $backup=Join-Path $history ((Get-Date -Format 'yyyyMMddHHmmssfff')+'-'+[guid]::NewGuid().ToString('N')+'-previous-function.ps1')
            [IO.File]::WriteAllText($backup,("function global:"+$Ticket.Function+" {`r`n"+$previous.Definition+"`r`n}"),(New-Object Text.UTF8Encoding($true)))
        }
    }
    $batch='@echo off'+[Environment]::NewLine+'"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0'+$Ticket.Function+'.ps1" %*'+[Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $commandRoot ($Ticket.Function+'.cmd')),$batch,[Text.Encoding]::ASCII)
    $definition=[scriptblock]::Create(("Invoke-GMenuSavedCommand -Name '{0}' -Arguments `$args" -f $Ticket.Function))
    Set-Item -LiteralPath ('Function:\global:'+$Ticket.Function) -Value $definition -Force
}
function Invoke-GMenuRestore {
    [CmdletBinding()]
    param($Ticket,[string]$Destination,[pscredential]$Credential,[switch]$RestoreOnly)
    Initialize-GMenuRuntime
    Register-GMenuPortableCommand $Ticket $PSCommandPath
    if(-not $Destination) {
        $original=[string]$Ticket.Target
        if(Test-Path -LiteralPath ([IO.Path]::GetPathRoot($original))) { $Destination=$original }
        else { $Destination=Join-Path 'F:\backup\windowsapps\installed' $Ticket.Folder }
    }
    $target=Assert-GMenuPath $Destination
    $parent=[IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($parent)
    $id=[guid]::NewGuid().ToString('N')
    $workParent=Get-GMenuStateRoot
    [void][IO.Directory]::CreateDirectory($workParent)
    $work=Join-Path $workParent ('.gmenu-work-'+$id)
    $stage=Join-Path $parent ('.gmenu-stage-'+$id)
    $previous=Join-Path $parent ('.gmenu-previous-'+$id)
    Protect-GMenuDirectory $work
    $swapped=$false;$ready=$false;$hadPrevious=$false
    $script:GMenuCreatedServices=New-Object 'Collections.Generic.List[string]'
    $external=@()
    Write-GMenuProgress 'restore-start' 0 1 'initializing restore'
    try {
        Write-GMenuProgress 'restore-auth' 0 1 'requesting registry token'
        if(-not $Credential) {$Credential=Get-GMenuLocalHubCredential}
        $token=Get-GMenuHubToken $Ticket.Repository $Credential
        Write-GMenuProgress 'restore-auth' 1 1 'registry token acquired'
        Write-GMenuProgress 'restore-manifest' 0 1 'fetching verified manifest'
        $remote=Get-GMenuManifest $Ticket.Repository $Ticket.Digest $work $token
        Write-GMenuProgress 'restore-manifest' 1 1 'verified manifest acquired'
        $tar=Join-Path $env:SystemRoot 'System32\tar.exe'
        if(-not (Test-Path -LiteralPath $tar)) { throw 'Windows tar.exe is required; Docker Desktop and the old PowerShell profile are not required.' }
        $found=@{}
        $layerNumber=0
        foreach($layer in $remote.Manifest.layers) {
            if([string]$layer.digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid registry layer digest.' }
            if((Get-Date) -ge $script:GMenuTokenRefreshAt) {$token=Get-GMenuHubToken $Ticket.Repository $Credential}
            $layerNumber++
            $layerPhase=('restore-layer-{0}/{1}' -f $layerNumber,$remote.Manifest.layers.Count)
            Write-Host ('GRESTORE_DOWNLOAD layer='+$layerNumber+'/'+$remote.Manifest.layers.Count)
            $layerFile=Join-Path $work 'layer.tar'
            Receive-GMenuHttp ('https://registry-1.docker.io/v2/'+$Ticket.Repository+'/blobs/'+$layer.digest) $layerFile $token '' $layerPhase
            if(('sha256:'+([GMenuPayload20260907]::Hash($layerFile))) -ne $layer.digest) { throw 'Registry layer checksum mismatch.' }
            $members=@(& $tar -tf $layerFile)
            if($LASTEXITCODE -ne 0) { throw 'Could not list registry layer.' }
            foreach($part in $Ticket.Parts) {
                if([string]$part.Name -notmatch '^gmenu-payload-[0-9]{5}\.bin$') { throw 'Invalid payload part name.' }
                $matching=@($members | Where-Object { $_.TrimStart('./') -ceq ('home/'+$part.Name) })
                if($matching.Count -gt 1 -or ($matching.Count -and $found.ContainsKey($part.Name))) { throw 'Duplicate payload part in image.' }
                if($matching.Count -eq 1) {
                    $partFile=Join-Path $work $part.Name
                    [GMenuPayload20260907]::TarMember($tar,$layerFile,$matching[0],$partFile,[long]$part.Length)
                    if([GMenuPayload20260907]::Hash($partFile) -ne $part.Sha256) { throw 'Payload part checksum mismatch.' }
                    $found[$part.Name]=$true
                }
            }
            Remove-Item -LiteralPath $layerFile -Force
            Write-GMenuProgress $layerPhase $layerNumber $remote.Manifest.layers.Count
        }
        if($found.Count -ne @($Ticket.Parts).Count) { throw 'Published image is missing backup parts.' }
        $encrypted=Join-Path $work 'payload.enc'
        Write-GMenuProgress 'assemble-parts' 0 1 'joining verified encrypted parts'
        $stream=[IO.File]::Open($encrypted,[IO.FileMode]::CreateNew)
        try {
            [long]$assembleTotal=0;foreach($part in $Ticket.Parts){$assembleTotal+=[long]$part.Length}
            [long]$assembleDone=0;Write-GMenuProgress 'assemble-parts' 0 $assembleTotal
            foreach($part in $Ticket.Parts) {
                $file=Join-Path $work $part.Name
                $inputStream=[IO.File]::OpenRead($file)
                try {
                    $buffer=New-Object byte[] 1048576;$last=Get-Date
                    while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $stream.Write($buffer,0,$read);$assembleDone+=$read
                        if(((Get-Date)-$last).TotalMilliseconds -ge 200){Write-GMenuProgress 'assemble-parts' $assembleDone $assembleTotal;$last=Get-Date}
                    }
                } finally {$inputStream.Dispose()}
                Remove-Item -LiteralPath $file -Force
            }
            Write-GMenuProgress 'assemble-parts' $assembleDone $assembleTotal
        } finally {$stream.Dispose()}
        $zip=Join-Path $work 'payload.zip'
        Write-GMenuProgress 'decrypt' 0 1 'authenticating and decrypting payload'
        [GMenuPayload20260907]::Decrypt($encrypted,$zip,[Convert]::FromBase64String($Ticket.Key),[Convert]::FromBase64String($Ticket.IV),[Convert]::FromBase64String($Ticket.MacKey),$Ticket.Mac)
        Write-GMenuProgress 'decrypt' 1 1 'decryption complete'
        Remove-Item -LiteralPath $encrypted -Force
        $expanded=Join-Path $work 'expanded'
        [void][IO.Directory]::CreateDirectory($expanded)
        Write-GMenuProgress 'extract' 0 1 'validating and expanding archive'
        [GMenuPayload20260907]::Extract($zip,$expanded,[long]$Ticket.Bytes,[int]$Ticket.Files)
        Write-GMenuProgress 'extract' 1 1 'archive expanded and verified'
        Remove-Item -LiteralPath $zip -Force
        $manifest=Get-Content -LiteralPath (Join-Path $expanded 'gmenu-manifest.json') -Raw | ConvertFrom-Json
        if($manifest.Schema -ne 1 -or $manifest.Folder -ne $Ticket.Folder) { throw 'Backup metadata mismatch.' }
        $session=Test-GMenuDaymarkSession $manifest
        Write-GMenuProgress 'session-rewrap' 0 1 'restoring portable Windows session keys'
        foreach($key in $manifest.WindowsKeys) {
            $file=[IO.Path]::GetFullPath((Join-Path $expanded $key.Path))
            if(-not $file.StartsWith($expanded+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Session key path escaped extraction folder.' }
            $state=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            $clear=[Convert]::FromBase64String($key.Key)
            try {
                $protected=[Security.Cryptography.ProtectedData]::Protect($clear,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
                $state.os_crypt.encrypted_key=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('DPAPI')+$protected)
                [IO.File]::WriteAllText($file,($state | ConvertTo-Json -Depth 100),(New-Object Text.UTF8Encoding($false)))
            } finally {[Array]::Clear($clear,0,$clear.Length)}
        }
        Write-GMenuProgress 'session-rewrap' 1 1 'session keys restored'
        $dataIndex=0
        Write-GMenuProgress 'external-data' 0 1 'restoring external data mappings'
        foreach($dataRoot in $manifest.DataRoots) {
            if($dataRoot.Environment -notin @('APPDATA','LOCALAPPDATA','ProgramData','USERPROFILE') -or
               [IO.Path]::IsPathRooted($dataRoot.Relative) -or $dataRoot.Relative -match '(^|[\\/])\.\.?($|[\\/])|:') {throw 'Unsafe external-data mapping.'}
            $base=[Environment]::GetEnvironmentVariable($dataRoot.Environment)
            $dataTarget=Assert-GMenuPath (Join-Path $base $dataRoot.Relative)
            if(-not $dataTarget.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
               $target.StartsWith($dataTarget+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataTarget -eq $target) {throw 'External-data mapping overlaps the application or escapes the user data root.'}
            if(-not (Test-Path -LiteralPath $dataTarget)) {
                $dataParent=[IO.Path]::GetDirectoryName($dataTarget)
                [void][IO.Directory]::CreateDirectory($dataParent)
                $dataStage=Join-Path $dataParent ('.gmenu-stage-'+[guid]::NewGuid().ToString('N'))
                $record=[pscustomobject]@{Target=$dataTarget;Stage=$dataStage;Parent=$dataParent;Created=$false;DataIndex=$dataIndex}
                $external+=$record
                [GMenuPayload20260907]::CopyTree((Join-Path $expanded ('data'+$dataIndex)),$dataStage)
            }
            $dataIndex++
        }
        Write-GMenuProgress 'external-data' 1 1 'external data mappings restored'
        Write-GMenuProgress 'stage-copy' 0 1 'copying verified application files'
        Copy-GMenuStage (Join-Path $expanded 'app') $stage
        Write-GMenuProgress 'stage-copy' 1 1 'application files staged'
        Stop-GMenuApp $target
        [void](Assert-GMenuPath $target)
        if(Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $previous;$hadPrevious=$true }
        Move-Item -LiteralPath $stage -Destination $target
        $swapped=$true
        foreach($record in $external) {
            [void](Assert-GMenuPath $record.Target)
            if(Test-Path -LiteralPath $record.Target) {throw 'External data appeared during restore; refusing to overwrite it.'}
            Move-Item -LiteralPath $record.Stage -Destination $record.Target
            $record.Created=$true
        }
        foreach($link in $manifest.Links) {
            $linkRoot=$target
            if($null -ne $link.DataIndex -and $link.DataIndex -ge 0) {
                if($link.DataIndex -ge @($manifest.DataRoots).Count){throw 'Restored link references an unknown data folder.'}
                $dataRecord=@($external | Where-Object {$_.Created -and $_.DataIndex -eq $link.DataIndex})
                if(-not $dataRecord.Count){continue} # Existing user data is preserved untouched.
                $linkRoot=$dataRecord[0].Target
            }
            Restore-GMenuLink $linkRoot $link
        }
        Install-GMenuServices $target $manifest
        if($RestoreOnly) {
            Write-GMenuProgress 'restore-complete' 1 1 'restore-only requested; application not launched'
            $ready=$true
            [pscustomobject]@{Status='RESTORED_NOT_LAUNCHED';Path=$target;Image=($Ticket.Repository+'@'+$Ticket.Digest)}
        } else {
            Write-GMenuProgress 'launch' 0 1 'opening restored application and verifying readiness'
            $appPid=Start-GMenuApp $target $manifest
            Write-GMenuProgress 'launch' 1 1 'application launched and readiness checked'
            $ready=$true
            [pscustomobject]@{Status=if($script:GMenuLaunchHealth -and $script:GMenuLaunchHealth.Status -ne 'Verified'){'RESTORE_LAUNCHED_NEEDS_ATTENTION'}else{'RESTORE_LAUNCHED'};Path=$target;ProcessId=$appPid;AppHealth=if($script:GMenuLaunchHealth){$script:GMenuLaunchHealth.Status}else{'NotVerified'};Session=if($session){$session.Status}elseif($manifest.Folder -ieq 'tailscale'){'SessionVerified'}else{'NotVerified'};Image=($Ticket.Repository+'@'+$Ticket.Digest)}
        }
        if($hadPrevious) {
            if(-not $RestoreOnly -and $script:GMenuLaunchHealth -and $script:GMenuLaunchHealth.Status -ne 'Verified') {
                Write-Warning ('App health is not verified. Recovery folder retained: '+$previous)
            } else {Remove-GMenuWork $previous $parent}
        }
    } catch {
        foreach($name in $script:GMenuCreatedServices) {
            $service=Get-Service -Name $name -ErrorAction SilentlyContinue
            if($service -and $service.Status -ne 'Stopped'){Stop-Service -Name $name -ErrorAction Stop}
            & (Join-Path $env:SystemRoot 'System32\sc.exe') delete $name | Out-Null
        }
        if(-not $ready) {
            foreach($record in $external | Where-Object Created) {
                [void](Assert-GMenuPath $record.Target)
                Move-Item -LiteralPath $record.Target -Destination $record.Stage
            }
        }
        if($hadPrevious -and -not $swapped -and -not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $previous -Destination $target
        }
        if($swapped -and -not $ready) {
            try {
                Stop-GMenuApp $target
                Move-Item -LiteralPath $target -Destination $stage
                if($hadPrevious) {Move-Item -LiteralPath $previous -Destination $target}
            } catch {
                if(Test-Path -LiteralPath $previous -PathType Container){Write-Warning ('Recovery folder retained: '+$previous)}
                else {Write-Warning ('Rollback could not stop the app. Restored files remain at: '+$target)}
            }
        }
        throw
    } finally {
        Write-GMenuProgress 'cleanup' 0 1 'releasing temporary restore state'
        Resume-GMenuServices $target
        foreach($record in $external) {if(Test-Path -LiteralPath $record.Stage){Remove-GMenuWork $record.Stage $record.Parent}}
        Remove-GMenuWork $work $workParent
        if(Test-Path -LiteralPath $stage) {Remove-GMenuWork $stage $parent}
        Write-GMenuProgress 'cleanup' 1 1 'temporary restore state released'
    }
}
