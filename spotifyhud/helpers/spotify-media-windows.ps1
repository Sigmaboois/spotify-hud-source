param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int] $ParentProcessId,

    [ValidateSet('spotify', 'all', 'preferred')]
    [string] $MediaMode = 'spotify',

    [ValidateLength(0, 80)]
    [string] $PreferredPlayer = 'Spotify'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Drawing

# PowerShell cannot safely poll a redirected StreamReader without occasionally
# blocking. A background .NET reader keeps media polling independent of stdin.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

public static class SpotifyHudHost
{
    private const int MaximumQueuedLines = 256;
    private const int MaximumLineCharacters = 65536;
    private static readonly ConcurrentQueue<string> InputLines = new ConcurrentQueue<string>();

    public static volatile bool ParentExited;
    public static volatile bool InputClosed;
    public static volatile bool InputOverflowed;
    public static volatile bool InputLineTooLong;
    public static string InputFailure = "";

    public static void Start(int parentProcessId)
    {
        StartParentWatchdog(parentProcessId);
        StartInputReader();
    }

    public static bool TryReadLine(out string line)
    {
        return InputLines.TryDequeue(out line);
    }

    private static void StartParentWatchdog(int parentProcessId)
    {
        Process parent;
        try
        {
            parent = Process.GetProcessById(parentProcessId);
            if (parent.HasExited)
            {
                parent.Dispose();
                ParentExited = true;
                return;
            }
        }
        catch (ArgumentException)
        {
            ParentExited = true;
            return;
        }
        catch
        {
            // If Windows denies inspection, keep the helper alive. The owning
            // process can still close stdin or issue a shutdown command.
            return;
        }

        Thread thread = new Thread(() =>
        {
            try
            {
                parent.WaitForExit();
                ParentExited = true;
            }
            catch
            {
                // Do not terminate a valid helper solely because inspection failed.
            }
            finally
            {
                parent.Dispose();
            }
        });
        thread.IsBackground = true;
        thread.Name = "Spotify HUD parent watchdog";
        thread.Start();
    }

    private static void StartInputReader()
    {
        Thread thread = new Thread(() =>
        {
            try
            {
                // Read incrementally so a hostile or corrupt parent cannot make
                // TextReader.ReadLine allocate an unbounded string.
                System.Text.StringBuilder line = new System.Text.StringBuilder(1024);
                bool discardingOversizedLine = false;
                while (true)
                {
                    int value = Console.In.Read();
                    if (value < 0)
                    {
                        if (!discardingOversizedLine && line.Length > 0)
                            EnqueueLine(line.ToString().TrimEnd('\r'));
                        break;
                    }

                    char character = (char)value;
                    if (character == '\n')
                    {
                        if (!discardingOversizedLine)
                            EnqueueLine(line.ToString().TrimEnd('\r'));
                        line.Clear();
                        discardingOversizedLine = false;
                    }
                    else if (!discardingOversizedLine)
                    {
                        if (line.Length >= MaximumLineCharacters)
                        {
                            InputLineTooLong = true;
                            discardingOversizedLine = true;
                            line.Clear();
                        }
                        else
                        {
                            line.Append(character);
                        }
                    }
                }
            }
            catch (Exception exception)
            {
                InputFailure = exception.GetType().Name + ": " + exception.Message;
            }
            finally
            {
                InputClosed = true;
            }
        });
        thread.IsBackground = true;
        thread.Name = "Spotify HUD command reader";
        thread.Start();
    }

    private static void EnqueueLine(string line)
    {
        while (InputLines.Count >= MaximumQueuedLines)
        {
            string discarded;
            InputLines.TryDequeue(out discarded);
            InputOverflowed = true;
        }
        InputLines.Enqueue(line);
    }
}
'@

[SpotifyHudHost]::Start($ParentProcessId)

$script:protocolName = 'spotify-hud-media'
$script:protocolVersion = 2
$script:helperVersion = '2.0.0'
$script:sequence = [long] 0
$script:running = $true
$script:outputAvailable = $true
$script:stopReason = 'shutdown'

$script:pollIntervalMilliseconds = 900
$script:idleLoopMilliseconds = 100
$script:operationTimeoutMilliseconds = 5000
$script:streamReadTimeoutMilliseconds = 5000
$script:httpTimeoutMilliseconds = 7000
$script:maxArtworkBytes = 4194304
$script:maxArtworkDimension = 2048
$script:maxArtworkPixels = 4194304
$script:maxStateFileBytes = 2097152
$script:maxCacheEntries = 48
$script:lastApiRequestAtUtc = [DateTimeOffset]::MinValue
$script:trackLookupCache = @{}
$script:manager = $null
$script:activeSession = $null
$script:nextPollAtUtc = [DateTimeOffset]::MinValue
$script:forceRefresh = $true

$httpHandler = [System.Net.Http.HttpClientHandler]::new()
$httpHandler.AllowAutoRedirect = $true
$httpHandler.MaxAutomaticRedirections = 3
$httpHandler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$script:httpClient = [System.Net.Http.HttpClient]::new($httpHandler, $true)
$script:httpClient.Timeout = [TimeSpan]::FromMilliseconds($script:httpTimeoutMilliseconds)
$script:httpClient.DefaultRequestHeaders.UserAgent.ParseAdd('SpotifyHUD/2.0.0 (Minecraft Fabric local client)')

$script:asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } |
    Select-Object -First 1
$script:asStreamForReadMethod = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1

if ($null -eq $script:asTaskMethod -or $null -eq $script:asStreamForReadMethod) {
    throw 'A required Windows Runtime adapter is unavailable.'
}

$script:managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$script:mediaPropertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]

function Write-Diagnostic {
    param([Parameter(Mandatory = $true)] [string] $Message)
    try {
        [Console]::Error.WriteLine(('[{0}] {1}' -f [DateTimeOffset]::UtcNow.ToString('o'), $Message))
    }
    catch {
        # Diagnostics must never interfere with the protocol.
    }
}

function Write-JsonLine {
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Value)

    if (-not $script:outputAvailable) {
        return
    }

    $script:sequence++
    $Value['protocol'] = $script:protocolName
    $Value['protocolVersion'] = $script:protocolVersion
    $Value['helperVersion'] = $script:helperVersion
    $Value['sequence'] = $script:sequence
    $Value['timestampUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
    try {
        $json = $Value | ConvertTo-Json -Compress -Depth 8
        [Console]::Out.WriteLine($json)
        [Console]::Out.Flush()
    }
    catch {
        $script:outputAvailable = $false
        $script:running = $false
        $script:stopReason = 'stdout_closed'
    }
}

function Await-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)] [object] $Operation,
        [Parameter(Mandatory = $true)] [type] $ResultType,
        [int] $TimeoutMilliseconds = $script:operationTimeoutMilliseconds
    )

    $method = $script:asTaskMethod.MakeGenericMethod($ResultType)
    $task = $method.Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutMilliseconds)) {
        try { $Operation.Cancel() } catch { }
        throw [System.TimeoutException]::new("Windows media operation timed out after $TimeoutMilliseconds ms")
    }
    return $task.Result
}

function Get-ObjectProperty {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [object] $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Test-SafeImageDimensions {
    param([long] $Width, [long] $Height)

    return $Width -gt 0 -and $Height -gt 0 -and
        $Width -le $script:maxArtworkDimension -and
        $Height -le $script:maxArtworkDimension -and
        ($Width * $Height) -le $script:maxArtworkPixels
}

function Read-BigEndianUInt16 {
    param([byte[]] $Bytes, [int] $Offset)
    return ([long] $Bytes[$Offset] * 256L) + [long] $Bytes[$Offset + 1]
}

function Read-BigEndianUInt32 {
    param([byte[]] $Bytes, [int] $Offset)
    return ([long] $Bytes[$Offset] * 16777216L) +
        ([long] $Bytes[$Offset + 1] * 65536L) +
        ([long] $Bytes[$Offset + 2] * 256L) +
        [long] $Bytes[$Offset + 3]
}

function Get-PngDimensions {
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 33) {
        return $null
    }
    [byte[]] $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($Bytes[$index] -ne $signature[$index]) {
            return $null
        }
    }
    if ((Read-BigEndianUInt32 $Bytes 8) -ne 13 -or
        $Bytes[12] -ne 0x49 -or $Bytes[13] -ne 0x48 -or
        $Bytes[14] -ne 0x44 -or $Bytes[15] -ne 0x52) {
        return $null
    }
    return [pscustomobject]@{
        Width = Read-BigEndianUInt32 $Bytes 16
        Height = Read-BigEndianUInt32 $Bytes 20
    }
}

function Get-JpegDimensions {
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 11 -or
        $Bytes[0] -ne 0xFF -or $Bytes[1] -ne 0xD8) {
        return $null
    }

    $offset = 2
    while ($offset -lt $Bytes.Length - 1) {
        while ($offset -lt $Bytes.Length -and $Bytes[$offset] -ne 0xFF) { $offset++ }
        while ($offset -lt $Bytes.Length -and $Bytes[$offset] -eq 0xFF) { $offset++ }
        if ($offset -ge $Bytes.Length) { break }
        $marker = [int] $Bytes[$offset]
        $offset++

        if ($marker -eq 0xD8 -or $marker -eq 0xD9 -or ($marker -ge 0xD0 -and $marker -le 0xD7) -or $marker -eq 0x01) {
            continue
        }
        if ($offset + 1 -ge $Bytes.Length) { break }
        $segmentLength = Read-BigEndianUInt16 $Bytes $offset
        if ($segmentLength -lt 2 -or $offset + $segmentLength -gt $Bytes.Length) { break }

        $startOfFrameMarkers = @(0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF)
        if ($startOfFrameMarkers -contains $marker) {
            if ($segmentLength -lt 7) { return $null }
            return [pscustomobject]@{
                Height = Read-BigEndianUInt16 $Bytes ($offset + 3)
                Width = Read-BigEndianUInt16 $Bytes ($offset + 5)
            }
        }
        if ($marker -eq 0xDA) { break }
        $offset += $segmentLength
    }
    return $null
}

function Convert-ArtworkToPng {
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 8 -or $Bytes.Length -gt $script:maxArtworkBytes) {
        return $null
    }

    $pngDimensions = Get-PngDimensions $Bytes
    if ($null -ne $pngDimensions) {
        if (-not (Test-SafeImageDimensions $pngDimensions.Width $pngDimensions.Height)) {
            return $null
        }
        return ,$Bytes
    }

    $jpegDimensions = Get-JpegDimensions $Bytes
    if ($null -eq $jpegDimensions -or
        -not (Test-SafeImageDimensions $jpegDimensions.Width $jpegDimensions.Height)) {
        return $null
    }

    $input = [System.IO.MemoryStream]::new($Bytes, $false)
    $image = $null
    try {
        $image = [System.Drawing.Image]::FromStream($input, $false, $true)
        if (-not (Test-SafeImageDimensions $image.Width $image.Height) -or
            $image.Width -ne $jpegDimensions.Width -or $image.Height -ne $jpegDimensions.Height) {
            return $null
        }

        $output = [System.IO.MemoryStream]::new()
        try {
            $image.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
            if ($output.Length -le 0 -or $output.Length -gt $script:maxArtworkBytes) {
                return $null
            }
            [byte[]] $result = $output.ToArray()
            $resultDimensions = Get-PngDimensions $result
            if ($null -eq $resultDimensions -or
                -not (Test-SafeImageDimensions $resultDimensions.Width $resultDimensions.Height)) {
                return $null
            }
            return ,$result
        }
        finally {
            $output.Dispose()
        }
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $input.Dispose()
    }
}

function Read-BoundedStream {
    param(
        [Parameter(Mandatory = $true)] [System.IO.Stream] $Stream,
        [Parameter(Mandatory = $true)] [int] $MaximumBytes
    )

    $memory = [System.IO.MemoryStream]::new()
    try {
        [byte[]] $buffer = New-Object byte[] 65536
        while ($true) {
            $readTask = $Stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait($script:streamReadTimeoutMilliseconds)) {
                throw [System.TimeoutException]::new('Artwork stream read timed out.')
            }
            $read = [int] $readTask.Result
            if ($read -le 0) { break }
            if ($memory.Length + $read -gt $MaximumBytes) {
                throw [System.IO.InvalidDataException]::new("Artwork exceeded the $MaximumBytes byte limit.")
            }
            $memory.Write($buffer, 0, $read)
        }
        return ,([byte[]] $memory.ToArray())
    }
    finally {
        $memory.Dispose()
    }
}

function Read-Thumbnail {
    param([object] $ThumbnailReference)

    if ($null -eq $ThumbnailReference) {
        return ''
    }

    $randomAccessStreamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $randomAccessStream = Await-WinRtOperation $ThumbnailReference.OpenReadAsync() $randomAccessStreamType
    try {
        # MethodInfo.Invoke performs the required WinRT interface marshaling.
        # PowerShell's normal binder sees only System.__ComObject here and can
        # nondeterministically reject the same valid stream.
        $stream = $script:asStreamForReadMethod.Invoke($null, @($randomAccessStream))
        try {
            [byte[]] $rawBytes = Read-BoundedStream $stream $script:maxArtworkBytes
            [byte[]] $pngBytes = Convert-ArtworkToPng $rawBytes
            if ($null -eq $pngBytes) { return '' }
            return [Convert]::ToBase64String($pngBytes)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($randomAccessStream)) {
            $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($randomAccessStream)
        }
        elseif ($randomAccessStream -is [System.IDisposable]) {
            ([System.IDisposable] $randomAccessStream).Dispose()
        }
    }
}

function Normalize-MetadataText {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -gt 4096) { $Value = $Value.Substring(0, 4096) }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -notin @(
            [System.Globalization.UnicodeCategory]::NonSpacingMark,
            [System.Globalization.UnicodeCategory]::SpacingCombiningMark,
            [System.Globalization.UnicodeCategory]::EnclosingMark
        )) {
            $null = $builder.Append($character)
        }
    }

    $normalized = $builder.ToString().Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
    $normalized = $normalized.Replace('&', ' and ')
    $normalized = [regex]::Replace($normalized, '[^\p{L}\p{Nd}]+', ' ')
    return [regex]::Replace($normalized.Trim(), '\s+', ' ')
}

function Wait-ApiRequestSlot {
    $elapsed = ([DateTimeOffset]::UtcNow - $script:lastApiRequestAtUtc).TotalMilliseconds
    $remaining = 1050 - $elapsed
    if ($remaining -gt 0) {
        Start-Sleep -Milliseconds ([int] [Math]::Ceiling($remaining))
    }
    $script:lastApiRequestAtUtc = [DateTimeOffset]::UtcNow
}

function Invoke-BoundedHttpGet {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $Accept,
        [Parameter(Mandatory = $true)] [int] $MaximumBytes
    )

    Wait-ApiRequestSlot
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $null = $request.Headers.Accept.ParseAdd($Accept)
    $response = $null
    try {
        $response = $script:httpClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { return $null }

        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and $contentLength -gt $MaximumBytes) { return $null }
        $mediaType = [string] $response.Content.Headers.ContentType.MediaType
        if ($Accept -eq 'image/*' -and
            ([string]::IsNullOrWhiteSpace($mediaType) -or
             -not $mediaType.StartsWith('image/', [System.StringComparison]::OrdinalIgnoreCase))) {
            return $null
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            return ,(Read-BoundedStream $stream $MaximumBytes)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-Diagnostic ("Artwork request failed: {0}" -f $_.Exception.Message)
        return $null
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Get-ProtobufMapStrings {
    param(
        [Parameter(Mandatory = $true)] [byte[]] $Bytes,
        [Parameter(Mandatory = $true)] [string] $Key
    )

    [byte[]] $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    if ($keyBytes.Length -gt 64) { return }

    for ($index = 2; $index -le $Bytes.Length - $keyBytes.Length - 2; $index++) {
        if ($Bytes[$index - 2] -ne 0x0A -or $Bytes[$index - 1] -ne $keyBytes.Length) { continue }

        $matches = $true
        for ($keyIndex = 0; $keyIndex -lt $keyBytes.Length; $keyIndex++) {
            if ($Bytes[$index + $keyIndex] -ne $keyBytes[$keyIndex]) {
                $matches = $false
                break
            }
        }
        if (-not $matches) { continue }

        $cursor = $index + $keyBytes.Length
        if ($cursor -ge $Bytes.Length -or $Bytes[$cursor] -ne 0x12) { continue }
        $cursor++

        [long] $valueLength = 0
        $shift = 0
        $lengthComplete = $false
        while ($cursor -lt $Bytes.Length -and $shift -le 28) {
            $lengthByte = $Bytes[$cursor]
            $cursor++
            $valueLength = $valueLength -bor ([long] ($lengthByte -band 0x7F) -shl $shift)
            if (($lengthByte -band 0x80) -eq 0) {
                $lengthComplete = $true
                break
            }
            $shift += 7
        }
        if (-not $lengthComplete -or $valueLength -lt 0 -or
            $valueLength -gt 4096 -or $cursor + $valueLength -gt $Bytes.Length) {
            continue
        }

        [pscustomobject]@{
            Offset = $index
            Value = [System.Text.Encoding]::UTF8.GetString($Bytes, $cursor, [int] $valueLength)
        }
    }
}

function Get-SpotifyStateFiles {
    $userDirectories = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\SpotifyAB.SpotifyMusic_zpdnekdrzrea0\LocalState\Spotify\Users'),
        (Join-Path $env:LOCALAPPDATA 'Spotify\Users'),
        (Join-Path $env:APPDATA 'Spotify\Users')
    )

    foreach ($usersDirectory in $userDirectories) {
        if (-not (Test-Path -LiteralPath $usersDirectory -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $usersDirectory -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'context_player_state_restore' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Get-Item -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 -and $_.Length -le $script:maxStateFileBytes }
    }
}

function Read-SpotifyStateBytes {
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo] $StateFile)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $StateFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        if ($stream.Length -le 0 -or $stream.Length -gt $script:maxStateFileBytes) { return $null }
        return ,(Read-BoundedStream $stream $script:maxStateFileBytes)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-SpotifyStateTitleEntries {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($stateFile in (Get-SpotifyStateFiles | Sort-Object LastWriteTimeUtc -Descending)) {
        [byte[]] $bytes = Read-SpotifyStateBytes $stateFile
        if ($null -eq $bytes) { continue }
        foreach ($entry in @(Get-ProtobufMapStrings $bytes 'title')) {
            $title = [string] $entry.Value
            if (-not [string]::IsNullOrWhiteSpace($title) -and $seen.Add($title)) {
                [pscustomobject]@{
                    Title = $title
                    StateModifiedUtc = [DateTimeOffset] $stateFile.LastWriteTimeUtc
                }
            }
        }
    }
}

function Get-SpotifyStateImageId {
    param(
        [Parameter(Mandatory = $true)] [string] $ExpectedTitle,
        [string] $ExpectedAlbum = ''
    )

    $expected = Normalize-MetadataText $ExpectedTitle
    if ([string]::IsNullOrWhiteSpace($expected)) { return '' }
    $expectedAlbum = Normalize-MetadataText $ExpectedAlbum

    foreach ($stateFile in (Get-SpotifyStateFiles | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            [byte[]] $bytes = Read-SpotifyStateBytes $stateFile
            if ($null -eq $bytes) { continue }
            $titles = @(Get-ProtobufMapStrings $bytes 'title')
            $albums = @(Get-ProtobufMapStrings $bytes 'album_title')

            foreach ($titleEntry in $titles) {
                if ((Normalize-MetadataText ([string] $titleEntry.Value)) -ne $expected) { continue }
                if (-not [string]::IsNullOrWhiteSpace($expectedAlbum)) {
                    $nearbyAlbums = @($albums | Where-Object {
                        [Math]::Abs([long] $_.Offset - [long] $titleEntry.Offset) -le 4096
                    })
                    if ($nearbyAlbums.Count -gt 0 -and -not ($nearbyAlbums | Where-Object {
                        (Normalize-MetadataText ([string] $_.Value)) -eq $expectedAlbum
                    })) { continue }
                }

                foreach ($imageKey in @('image_xlarge_url', 'image_large_url', 'image_url', 'image_small_url')) {
                    $nearest = @(Get-ProtobufMapStrings $bytes $imageKey) |
                        Where-Object { [Math]::Abs([long] $_.Offset - [long] $titleEntry.Offset) -le 4096 } |
                        Sort-Object { [Math]::Abs([long] $_.Offset - [long] $titleEntry.Offset) } |
                        Select-Object -First 1
                    if ($null -ne $nearest -and ([string] $nearest.Value) -match '^spotify:image:([0-9a-fA-F]{40})$') {
                        return $Matches[1].ToLowerInvariant()
                    }
                }
            }
        }
        catch {
            # Spotify replaces this state atomically while it is being read.
        }
    }
    return ''
}

function Invoke-TrackCacheMaintenance {
    param([DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)

    foreach ($key in @($script:trackLookupCache.Keys)) {
        $entry = $script:trackLookupCache[$key]
        if ($null -eq $entry -or $entry.ExpiresAtUtc -le $Now) {
            $null = $script:trackLookupCache.Remove($key)
        }
    }
    if ($script:trackLookupCache.Count -le $script:maxCacheEntries) { return }

    $removeCount = $script:trackLookupCache.Count - $script:maxCacheEntries
    $oldestKeys = @($script:trackLookupCache.GetEnumerator() |
        Sort-Object { $_.Value.LastAccessAtUtc } |
        Select-Object -First $removeCount |
        ForEach-Object { $_.Key })
    foreach ($key in $oldestKeys) {
        $null = $script:trackLookupCache.Remove($key)
    }
}

function Get-TrackArtwork {
    param(
        [Parameter(Mandatory = $true)] [string] $Title,
        [Parameter(Mandatory = $true)] [string] $Artist,
        [string] $Album = ''
    )

    $cacheKey = "$(Normalize-MetadataText $Title)`0$(Normalize-MetadataText $Artist)`0$(Normalize-MetadataText $Album)"
    if ($cacheKey -eq "`0`0") { return '' }

    $now = [DateTimeOffset]::UtcNow
    Invoke-TrackCacheMaintenance $now
    $cached = $script:trackLookupCache[$cacheKey]
    if ($null -ne $cached -and $cached.ExpiresAtUtc -gt $now) {
        $cached.LastAccessAtUtc = $now
        if (-not [string]::IsNullOrWhiteSpace([string] $cached.Artwork) -or
            $cached.NextStateRetryAtUtc -gt $now) {
            return [string] $cached.Artwork
        }
    }
    else {
        $cached = $null
    }

    $artwork = if ($null -ne $cached) { [string] $cached.Artwork } else { '' }
    if ([string]::IsNullOrWhiteSpace($artwork)) {
        $imageId = Get-SpotifyStateImageId $Title $Album
        if (-not [string]::IsNullOrWhiteSpace($imageId)) {
            [byte[]] $spotifyImage = Invoke-BoundedHttpGet (
                'https://i.scdn.co/image/{0}' -f $imageId
            ) 'image/*' $script:maxArtworkBytes
            [byte[]] $pngBytes = Convert-ArtworkToPng $spotifyImage
            if ($null -ne $pngBytes -and $pngBytes.Length -ge 64) {
                $artwork = [Convert]::ToBase64String($pngBytes)
            }
        }
    }

    $retryAt = if ([string]::IsNullOrWhiteSpace($artwork)) { $now.AddSeconds(30) } else { [DateTimeOffset]::MaxValue }
    $script:trackLookupCache[$cacheKey] = [pscustomobject]@{
        Artwork = $artwork
        NextStateRetryAtUtc = $retryAt
        ExpiresAtUtc = $now.AddHours(12)
        LastAccessAtUtc = $now
    }
    Invoke-TrackCacheMaintenance $now
    return $artwork
}

function Get-StableArtworkId {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        [byte[]] $digest = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return ([BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha256.Dispose()
    }
}

$script:lastArtworkKey = ''
$script:nextArtworkAttemptAtUtc = [DateTimeOffset]::MinValue
$script:artworkDeliveredForKey = $false

function Reset-ArtworkEmission {
    $script:lastArtworkKey = ''
    $script:nextArtworkAttemptAtUtc = [DateTimeOffset]::MinValue
    $script:artworkDeliveredForKey = $false
}

function Get-ArtworkEmission {
    param(
        [Parameter(Mandatory = $true)] [string] $Title,
        [Parameter(Mandatory = $true)] [string] $Artist,
        [string] $Album = '',
        [object] $Thumbnail = $null,
        [bool] $AllowSpotifyLookup = $true,
        [string] $KeyScope = 'spotify'
    )

    $artworkKey = "$(Normalize-MetadataText $KeyScope)`0$(Normalize-MetadataText $Title)`0$(Normalize-MetadataText $Artist)`0$(Normalize-MetadataText $Album)"
    $trackChanged = $artworkKey -ne $script:lastArtworkKey
    if ($trackChanged) {
        $script:lastArtworkKey = $artworkKey
        $script:nextArtworkAttemptAtUtc = [DateTimeOffset]::MinValue
        $script:artworkDeliveredForKey = $false
    }

    $result = [ordered]@{
        id = Get-StableArtworkId $artworkKey
        changed = $trackChanged
        included = $false
        base64 = ''
        mime = 'image/png'
    }
    if ($script:artworkDeliveredForKey -or [DateTimeOffset]::UtcNow -lt $script:nextArtworkAttemptAtUtc) {
        return $result
    }

    $artwork = ''
    if ($null -ne $Thumbnail) {
        try {
            $artwork = Read-Thumbnail $Thumbnail
        }
        catch {
            Write-Diagnostic ("GSMTC artwork unavailable: {0}" -f $_.Exception.Message)
        }
    }
    if ([string]::IsNullOrWhiteSpace($artwork) -and $AllowSpotifyLookup) {
        $artwork = Get-TrackArtwork $Title $Artist $Album
    }

    if ([string]::IsNullOrWhiteSpace($artwork)) {
        $script:nextArtworkAttemptAtUtc = [DateTimeOffset]::UtcNow.AddSeconds(30)
    }
    else {
        $script:artworkDeliveredForKey = $true
        $script:nextArtworkAttemptAtUtc = [DateTimeOffset]::MaxValue
        $result.included = $true
        $result.changed = $true
        $result.base64 = $artwork
    }
    return $result
}

function Get-SpotifyWindowTrack {
    $processes = @(Get-Process -Name Spotify -ErrorAction SilentlyContinue)
    try {
        $window = $processes |
            Where-Object {
                $_.MainWindowHandle -ne 0 -and $_.Responding -and
                -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
            } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($null -eq $window) { return $null }

        $caption = [string] $window.MainWindowTitle
        if ($caption -in @('Spotify', 'Spotify Free', 'Spotify Premium')) { return $null }

        $processStartedUtc = [DateTimeOffset] $window.StartTime.ToUniversalTime()
        foreach ($entry in (Get-SpotifyStateTitleEntries | Sort-Object { $_.Title.Length } -Descending)) {
            # State from a previous app launch is not allowed to validate a current caption.
            if ($entry.StateModifiedUtc -lt $processStartedUtc.AddMinutes(-10) -or
                $entry.StateModifiedUtc -lt [DateTimeOffset]::UtcNow.AddDays(-1)) {
                continue
            }
            $pattern = '^(?<artist>.+?)\s+[-\u2013\u2014]\s+' + [regex]::Escape([string] $entry.Title) + '$'
            if ($caption -match $pattern -and -not [string]::IsNullOrWhiteSpace($Matches.artist)) {
                return [pscustomobject]@{
                    Artist = ([string] $Matches.artist).Trim()
                    Title = ([string] $entry.Title).Trim()
                    StateModifiedUtc = $entry.StateModifiedUtc
                    ProcessId = [int] $window.Id
                }
            }
        }
        return $null
    }
    finally {
        foreach ($process in $processes) { $process.Dispose() }
    }
}

function Get-ControlCapabilities {
    param([object] $PlaybackInfo)

    $disabled = [ordered]@{
        play = $false
        pause = $false
        playPause = $false
        next = $false
        previous = $false
        seek = $false
    }
    if ($null -eq $PlaybackInfo -or $null -eq $PlaybackInfo.Controls) { return $disabled }
    $controls = $PlaybackInfo.Controls
    return [ordered]@{
        play = [bool] $controls.IsPlayEnabled
        pause = [bool] $controls.IsPauseEnabled
        playPause = [bool] $controls.IsPlayPauseToggleEnabled
        next = [bool] $controls.IsNextEnabled
        previous = [bool] $controls.IsPreviousEnabled
        seek = [bool] $controls.IsPlaybackPositionEnabled
    }
}

function Select-SpotifySession {
    param([Parameter(Mandatory = $true)] [object] $Manager)

    $candidates = @()
    foreach ($candidate in $Manager.GetSessions()) {
        try {
            $appId = [string] $candidate.SourceAppUserModelId
            if ($MediaMode -eq 'spotify' -and $appId -notmatch '(?i)spotify') { continue }
            if ($MediaMode -eq 'preferred' -and
                -not [string]::IsNullOrWhiteSpace($PreferredPlayer) -and
                $appId.IndexOf($PreferredPlayer, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

            $playback = $candidate.GetPlaybackInfo()
            $timeline = $candidate.GetTimelineProperties()
            $playbackStatus = [string] $playback.PlaybackStatus.ToString()
            $score = switch ($playbackStatus) {
                'Playing' { 4000 }
                'Paused' { 3000 }
                'Changing' { 2500 }
                'Stopped' { 1000 }
                default { 0 }
            }
            $lastUpdated = [DateTimeOffset] $timeline.LastUpdatedTime
            if ($lastUpdated.Year -ge 1970) {
                $ageMinutes = [Math]::Max(0, ([DateTimeOffset]::Now - $lastUpdated).TotalMinutes)
                $score += [int] [Math]::Max(0, 1000 - [Math]::Min(1000, $ageMinutes))
            }
            if ($timeline.EndTime.TotalMilliseconds -gt 0) { $score += 100 }

            $candidates += [pscustomobject]@{
                Session = $candidate
                Playback = $playback
                Timeline = $timeline
                AppId = $appId
                Score = $score
            }
        }
        catch {
            Write-Diagnostic ("Ignoring an unreadable media session: {0}" -f $_.Exception.Message)
        }
    }
    return $candidates | Sort-Object Score -Descending | Select-Object -First 1
}

function New-EmptyState {
    param(
        [string] $Status = 'idle',
        [string] $ErrorMessage = '',
        [string] $ErrorCode = ''
    )

    $value = [ordered]@{
        type = 'state'
        status = $Status
        heartbeat = $true
        empty = $true
        source = 'none'
        player = ''
        fallback = $false
        stale = $false
        title = ''
        artist = ''
        album = ''
        positionMillis = [long] 0
        durationMillis = [long] 0
        playbackStatus = 'unknown'
        playing = $false
        canControl = $false
        controls = Get-ControlCapabilities $null
        artwork = ''
        artworkId = ''
        artworkChanged = $true
        artworkIncluded = $false
        artworkMime = 'image/png'
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $value['error'] = $ErrorMessage
        $value['errorCode'] = $ErrorCode
        $value['transient'] = $true
    }
    return $value
}

function Write-SpotifyWindowFallback {
    param([string] $Warning = '')

    $windowTrack = Get-SpotifyWindowTrack
    if ($null -eq $windowTrack) { return $false }

    $title = [string] $windowTrack.Title
    $artist = [string] $windowTrack.Artist
    $artwork = Get-ArtworkEmission $title $artist
    $state = [ordered]@{
        type = 'state'
        status = 'degraded'
        heartbeat = $true
        empty = $false
        source = 'window'
        player = 'Spotify'
        fallback = $true
        stale = $false
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        sourceStateModifiedUtc = ([DateTimeOffset] $windowTrack.StateModifiedUtc).ToString('o')
        title = $title
        artist = $artist
        album = ''
        positionMillis = [long] 0
        durationMillis = [long] 0
        playbackStatus = 'unknown'
        playing = $false
        canControl = $false
        controls = Get-ControlCapabilities $null
        artwork = [string] $artwork.base64
        artworkId = [string] $artwork.id
        artworkChanged = [bool] $artwork.changed
        artworkIncluded = [bool] $artwork.included
        artworkMime = [string] $artwork.mime
    }
    if (-not [string]::IsNullOrWhiteSpace($Warning)) {
        $state['warning'] = $Warning
        $state['warningCode'] = 'gsmtc_unavailable'
    }
    Write-JsonLine $state
    return $true
}

function Write-SpotifySessionState {
    param([Parameter(Mandatory = $true)] [object] $Selection)

    $session = $Selection.Session
    $playback = $session.GetPlaybackInfo()
    $timeline = $session.GetTimelineProperties()
    $media = Await-WinRtOperation $session.TryGetMediaPropertiesAsync() $script:mediaPropertiesType
    $playbackStatus = ([string] $playback.PlaybackStatus.ToString()).ToLowerInvariant()
    $isPlaying = $playbackStatus -eq 'playing'

    [long] $positionMillis = $timeline.Position.TotalMilliseconds
    [long] $durationMillis = $timeline.EndTime.TotalMilliseconds
    if ($isPlaying) {
        $lastUpdated = [DateTimeOffset] $timeline.LastUpdatedTime
        if ($lastUpdated.Year -ge 1970) {
            $elapsed = ([DateTimeOffset]::Now - $lastUpdated).TotalMilliseconds
            if ($elapsed -gt 0 -and $elapsed -lt 86400000) {
                $positionMillis += [long] $elapsed
            }
        }
    }
    if ($positionMillis -lt 0) { $positionMillis = 0 }
    if ($durationMillis -lt 0) { $durationMillis = 0 }
    if ($durationMillis -gt 0 -and $positionMillis -gt $durationMillis) {
        $positionMillis = $durationMillis
    }

    $title = [string] $media.Title
    $artist = [string] $media.Artist
    $album = [string] $media.AlbumTitle
    $isSpotify = ([string] $Selection.AppId) -match '(?i)spotify'
    $artwork = Get-ArtworkEmission $title $artist $album $media.Thumbnail $isSpotify ([string] $Selection.AppId)
    $capabilities = Get-ControlCapabilities $playback
    $canControl = $capabilities.Values -contains $true

    Write-JsonLine ([ordered]@{
        type = 'state'
        status = if ([string]::IsNullOrWhiteSpace($title)) { 'idle' } else { $playbackStatus }
        heartbeat = $true
        empty = [string]::IsNullOrWhiteSpace($title)
        source = 'gsmtc'
        player = [string] $Selection.AppId
        sessionAppId = [string] $Selection.AppId
        fallback = $false
        stale = $false
        title = $title
        artist = $artist
        album = $album
        positionMillis = $positionMillis
        durationMillis = $durationMillis
        playbackStatus = $playbackStatus
        playing = $isPlaying
        canControl = $canControl
        controls = $capabilities
        artwork = [string] $artwork.base64
        artworkId = [string] $artwork.id
        artworkChanged = [bool] $artwork.changed
        artworkIncluded = [bool] $artwork.included
        artworkMime = [string] $artwork.mime
    })
}

function Get-NormalizedCommandName {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z]', ''))
}

function Write-CommandResult {
    param(
        [string] $Id,
        [string] $Command,
        [bool] $Ok,
        [string] $Code = '',
        [string] $Message = '',
        [System.Collections.IDictionary] $Details = $null
    )

    $value = [ordered]@{
        type = 'commandResult'
        status = if ($Ok) { 'ok' } else { 'error' }
        heartbeat = $true
        id = $Id
        command = $Command
        ok = $Ok
    }
    if (-not [string]::IsNullOrWhiteSpace($Code)) { $value['code'] = $Code }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $value['message'] = $Message }
    if ($null -ne $Details) { $value['details'] = $Details }
    Write-JsonLine $value
}

function Invoke-BooleanControlOperation {
    param(
        [Parameter(Mandatory = $true)] [object] $Operation,
        [Parameter(Mandatory = $true)] [string] $Id,
        [Parameter(Mandatory = $true)] [string] $Command
    )

    try {
        $accepted = [bool] (Await-WinRtOperation $Operation ([bool]))
        if ($accepted) {
            Write-CommandResult $Id $Command $true
            $script:forceRefresh = $true
        }
        else {
            Write-CommandResult $Id $Command $false 'rejected' 'Spotify rejected the media command.'
        }
    }
    catch {
        Write-CommandResult $Id $Command $false 'operation_failed' $_.Exception.Message
    }
}

function Invoke-MediaCommand {
    param([Parameter(Mandatory = $true)] [string] $Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $request = $null
    try {
        $request = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-CommandResult '' '' $false 'invalid_json' 'Command input was not valid JSON.'
        return
    }

    $id = [string] (Get-ObjectProperty $request 'id' '')
    if ($id.Length -gt 128) { $id = $id.Substring(0, 128) }
    $rawCommand = [string] (Get-ObjectProperty $request 'command' (Get-ObjectProperty $request 'action' ''))
    $command = Get-NormalizedCommandName $rawCommand
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [Guid]::NewGuid().ToString('N') }

    if ($command -eq 'ping') {
        Write-CommandResult $id $command $true '' '' ([ordered]@{
            activeSession = $null -ne $script:activeSession
            parentAlive = -not [SpotifyHudHost]::ParentExited
        })
        return
    }
    if ($command -eq 'shutdown' -or $command -eq 'stop') {
        Write-CommandResult $id 'shutdown' $true
        $script:running = $false
        $script:stopReason = 'command'
        return
    }
    if ($command -eq 'refresh') {
        Reset-ArtworkEmission
        $script:forceRefresh = $true
        Write-CommandResult $id $command $true
        return
    }

    $sessionCommands = @('play', 'pause', 'playpause', 'toggle', 'toggleplaypause', 'next', 'previous', 'prev', 'seek')
    if ($sessionCommands -notcontains $command) {
        Write-CommandResult $id $command $false 'unknown_command' 'Unsupported media command.'
        return
    }

    $session = $script:activeSession
    if ($null -eq $session) {
        Write-CommandResult $id $command $false 'no_active_session' 'No controllable Spotify media session is active.'
        return
    }

    try {
        $playback = $session.GetPlaybackInfo()
        $controls = Get-ControlCapabilities $playback
        switch ($command) {
            'play' {
                if (-not $controls.play) {
                    Write-CommandResult $id $command $false 'not_supported' 'Play is not available for this session.'
                }
                else { Invoke-BooleanControlOperation $session.TryPlayAsync() $id $command }
            }
            'pause' {
                if (-not $controls.pause) {
                    Write-CommandResult $id $command $false 'not_supported' 'Pause is not available for this session.'
                }
                else { Invoke-BooleanControlOperation $session.TryPauseAsync() $id $command }
            }
            { $_ -in @('playpause', 'toggle', 'toggleplaypause') } {
                if ($controls.playPause) {
                    Invoke-BooleanControlOperation $session.TryTogglePlayPauseAsync() $id 'playPause'
                }
                elseif ([string] $playback.PlaybackStatus.ToString() -eq 'Playing' -and $controls.pause) {
                    Invoke-BooleanControlOperation $session.TryPauseAsync() $id 'playPause'
                }
                elseif ($controls.play) {
                    Invoke-BooleanControlOperation $session.TryPlayAsync() $id 'playPause'
                }
                else {
                    Write-CommandResult $id 'playPause' $false 'not_supported' 'Play/pause is not available for this session.'
                }
            }
            'next' {
                if (-not $controls.next) {
                    Write-CommandResult $id $command $false 'not_supported' 'Next track is not available for this session.'
                }
                else { Invoke-BooleanControlOperation $session.TrySkipNextAsync() $id $command }
            }
            { $_ -in @('previous', 'prev') } {
                if (-not $controls.previous) {
                    Write-CommandResult $id 'previous' $false 'not_supported' 'Previous track is not available for this session.'
                }
                else { Invoke-BooleanControlOperation $session.TrySkipPreviousAsync() $id 'previous' }
            }
            'seek' {
                if (-not $controls.seek) {
                    Write-CommandResult $id $command $false 'not_supported' 'Seeking is not available for this session.'
                    break
                }

                $positionValue = Get-ObjectProperty $request 'positionMillis' $null
                $deltaValue = Get-ObjectProperty $request 'deltaMillis' $null
                if ($null -eq $positionValue -and $null -eq $deltaValue) {
                    Write-CommandResult $id $command $false 'invalid_argument' 'Seek requires positionMillis or deltaMillis.'
                    break
                }
                try {
                    if ($null -ne $positionValue) {
                        [long] $positionMillis = $positionValue
                    }
                    else {
                        $timeline = $session.GetTimelineProperties()
                        [long] $positionMillis = [long] $timeline.Position.TotalMilliseconds + [long] $deltaValue
                    }
                    if ($positionMillis -lt 0) { $positionMillis = 0 }
                    $timelineForLimit = $session.GetTimelineProperties()
                    [long] $durationMillis = $timelineForLimit.EndTime.TotalMilliseconds
                    if ($durationMillis -gt 0 -and $positionMillis -gt $durationMillis) {
                        $positionMillis = $durationMillis
                    }
                    if ($positionMillis -gt 922337203685477) {
                        throw [System.ArgumentOutOfRangeException]::new('positionMillis')
                    }
                    [long] $positionTicks = $positionMillis * 10000L
                    Invoke-BooleanControlOperation $session.TryChangePlaybackPositionAsync($positionTicks) $id $command
                }
                catch {
                    Write-CommandResult $id $command $false 'invalid_argument' 'Seek position was outside the valid range.'
                }
            }
            default {
                Write-CommandResult $id $command $false 'unknown_command' 'Unsupported media command.'
            }
        }
    }
    catch {
        Write-CommandResult $id $command $false 'operation_failed' $_.Exception.Message
        $script:forceRefresh = $true
    }
}

function Read-PendingCommands {
    if ([SpotifyHudHost]::InputLineTooLong) {
        [SpotifyHudHost]::InputLineTooLong = $false
        Write-CommandResult '' '' $false 'input_too_long' 'A command exceeded the 65,536 character limit.'
    }
    if ([SpotifyHudHost]::InputOverflowed) {
        [SpotifyHudHost]::InputOverflowed = $false
        Write-CommandResult '' '' $false 'input_overflow' 'Command input exceeded the 256-line queue; oldest commands were dropped.'
    }
    if (-not [string]::IsNullOrWhiteSpace([SpotifyHudHost]::InputFailure)) {
        $failure = [SpotifyHudHost]::InputFailure
        [SpotifyHudHost]::InputFailure = ''
        Write-JsonLine ([ordered]@{
            type = 'status'
            status = 'degraded'
            heartbeat = $true
            code = 'stdin_failure'
            message = $failure
        })
    }

    $processed = 0
    $line = $null
    while ($processed -lt 64 -and [SpotifyHudHost]::TryReadLine([ref] $line)) {
        Invoke-MediaCommand $line
        $processed++
        if (-not $script:running) { break }
        $line = $null
    }
}

Write-JsonLine ([ordered]@{
    type = 'hello'
    status = 'ready'
    heartbeat = $true
    platform = 'windows'
    transport = 'ndjson'
    mediaProvider = $MediaMode
    commands = @('ping', 'refresh', 'play', 'pause', 'playPause', 'next', 'previous', 'seek', 'shutdown')
    limits = [ordered]@{
        artworkBytes = $script:maxArtworkBytes
        artworkDimension = $script:maxArtworkDimension
        artworkPixels = $script:maxArtworkPixels
        commandCharacters = 65536
        commandQueue = 256
    }
})

try {
    while ($script:running) {
        if ([SpotifyHudHost]::ParentExited) {
            $script:stopReason = 'parent_exited'
            break
        }

        Read-PendingCommands
        if (-not $script:running) { break }

        # Process all queued input before honoring EOF so piped shutdown commands
        # still receive a result.
        if ([SpotifyHudHost]::InputClosed) {
            $probe = $null
            if (-not [SpotifyHudHost]::TryReadLine([ref] $probe)) {
                $script:stopReason = 'stdin_closed'
                break
            }
            Invoke-MediaCommand $probe
            continue
        }

        $now = [DateTimeOffset]::UtcNow
        if (-not $script:forceRefresh -and $now -lt $script:nextPollAtUtc) {
            Start-Sleep -Milliseconds $script:idleLoopMilliseconds
            continue
        }
        $script:forceRefresh = $false
        $script:nextPollAtUtc = $now.AddMilliseconds($script:pollIntervalMilliseconds)

        try {
            if ($null -eq $script:manager) {
                $script:manager = Await-WinRtOperation $script:managerType::RequestAsync() $script:managerType
            }
            $selection = Select-SpotifySession $script:manager
            if ($null -eq $selection) {
                $script:activeSession = $null
                if (-not (Write-SpotifyWindowFallback)) {
                    Reset-ArtworkEmission
                    Write-JsonLine (New-EmptyState 'idle')
                }
                continue
            }

            $script:activeSession = $selection.Session
            Write-SpotifySessionState $selection
        }
        catch {
            $message = $_.Exception.Message
            $script:manager = $null
            $script:activeSession = $null
            if (-not (Write-SpotifyWindowFallback $message)) {
                Reset-ArtworkEmission
                Write-JsonLine (New-EmptyState 'error' $message 'gsmtc_failure')
            }
        }
    }
}
finally {
    if ($script:outputAvailable) {
        Write-JsonLine ([ordered]@{
            type = 'status'
            status = 'stopped'
            heartbeat = $true
            reason = $script:stopReason
        })
    }
    $script:activeSession = $null
    $script:manager = $null
    if ($null -ne $script:httpClient) {
        $script:httpClient.Dispose()
        $script:httpClient = $null
    }
}
