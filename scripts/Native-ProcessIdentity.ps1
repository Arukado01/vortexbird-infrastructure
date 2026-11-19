function Test-NativeProcessIdentity($process, $processId, $startedAt, [string]$executable) {
    if (-not $process -or $process.Id -ne $processId -or [string]::IsNullOrWhiteSpace($executable)) { return $false }
    try {
        if (-not [IO.Path]::IsPathFullyQualified($executable) -or -not [IO.Path]::IsPathFullyQualified($process.Path)) { return $false }
        if (-not [string]::Equals([IO.Path]::GetFullPath($process.Path), [IO.Path]::GetFullPath($executable), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        # ConvertFrom-Json may already have converted the saved ISO string to a date.
        if ($startedAt -is [datetime]) {
            if ($startedAt.Kind -eq [DateTimeKind]::Unspecified) { return $false }
            $expected = $startedAt.ToUniversalTime()
        } elseif ($startedAt -is [datetimeoffset]) {
            $expected = $startedAt.UtcDateTime
        } else {
            $expected = [datetime]::ParseExact([string]$startedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ($expected.Kind -eq [DateTimeKind]::Unspecified) { return $false }
            $expected = $expected.ToUniversalTime()
        }
        return $process.StartTime.ToUniversalTime().Ticks -eq $expected.Ticks
    } catch {
        return $false
    }
}
