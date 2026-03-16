param(
    [string]$ManifestBaseUrl = "https://raw.githubusercontent.com/tinkervalley/toolkit/main/manifests",
    [string]$ScriptBaseUrl = "",
    [string]$BrandName = "the Tinker Valley Toolkit"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ScriptBaseUrl)) {
    if ($ManifestBaseUrl -match '^https?://') {
        $ScriptBaseUrl = $ManifestBaseUrl -replace '/manifests/?$', '/scripts'
    } else {
        $manifestRoot = Split-Path -Path $ManifestBaseUrl -Parent
        $ScriptBaseUrl = Join-Path $manifestRoot 'scripts'
    }
}

function Get-ManifestLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestName
    )

    if ($ManifestBaseUrl -match '^https?://') {
        $uri = ($ManifestBaseUrl.TrimEnd('/') + "/" + $ManifestName)
        $content = Invoke-RestMethod -Uri $uri -Method Get
        return ($content -split "`r?`n")
    }

    $path = Join-Path $ManifestBaseUrl $ManifestName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Manifest not found: $path"
    }

    return Get-Content -LiteralPath $path
}

function Resolve-ScriptTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptTarget
    )

    if ($ScriptTarget -match '^https?://') {
        return $ScriptTarget
    }

    if ($ScriptBaseUrl -match '^https?://') {
        return ($ScriptBaseUrl.TrimEnd('/') + "/" + $ScriptTarget.TrimStart('/'))
    }

    return Join-Path $ScriptBaseUrl $ScriptTarget
}

function Get-ManifestRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestName,

        [Parameter(Mandatory = $true)]
        [string[]]$FieldNames
    )

    $records = @()

    foreach ($line in Get-ManifestLines -ManifestName $ManifestName) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $parts = $trimmed.Split('|')
        $record = [ordered]@{}

        for ($i = 0; $i -lt $FieldNames.Count; $i++) {
            $value = ""
            if ($i -lt $parts.Count) {
                $value = $parts[$i].Trim()
            }
            $record[$FieldNames[$i]] = $value
        }

        $records += [pscustomobject]$record
    }

    return $records
}

function Select-Record {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [string]$LabelProperty,

        [string]$DescriptionProperty = ""
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "No items found for $Title."
    }

    while ($true) {
        Write-Host ""
        Write-Host "== $Title =="

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $label = $Items[$i].$LabelProperty
            if ($DescriptionProperty -and $Items[$i].$DescriptionProperty) {
                Write-Host ("{0}. {1} - {2}" -f ($i + 1), $label, $Items[$i].$DescriptionProperty)
            } else {
                Write-Host ("{0}. {1}" -f ($i + 1), $label)
            }
        }

        Write-Host "0. Back"
        $selection = Read-Host "Choose an option"

        if ($selection -eq '0') {
            return $null
        }

        if ($selection -as [int]) {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $Items.Count) {
                return $Items[$index]
            }
        }

        Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
    }
}

function Test-ConfirmationRequired {
    param(
        [string]$Value
    )

    return @('yes', 'y', 'true', '1') -contains $Value.ToLowerInvariant()
}

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    if (-not (Test-ConfirmationRequired -Value $Item.Confirm)) {
        return $true
    }

    $answer = Read-Host ("Confirm '{0}'? (y/N)" -f $Item.Name)
    return @('y', 'yes') -contains $answer.ToLowerInvariant()
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $target = Join-Path ([System.IO.Path]::GetTempPath()) ("tvt-" + [guid]::NewGuid().ToString() + $Extension)
    Invoke-WebRequest -Uri $Url -OutFile $target
    return $target
}

function Invoke-ManifestAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    switch ($Item.Type.ToUpperInvariant()) {
        'MSI' {
            $installer = Download-File -Url $Item.Target -Extension '.msi'
            Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $installer, '/qn', '/norestart') -Wait
        }
        'EXE' {
            $installer = Download-File -Url $Item.Target -Extension '.exe'
            $args = if ([string]::IsNullOrWhiteSpace($Item.Args)) { '/quiet' } else { $Item.Args }
            Start-Process -FilePath $installer -ArgumentList $args -Wait
        }
        'WINGET' {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                throw "winget is not available on this system."
            }

            $argumentList = @(
                'install',
                '--id', $Item.Target,
                '--exact',
                '--accept-package-agreements',
                '--accept-source-agreements'
            )

            if (-not [string]::IsNullOrWhiteSpace($Item.Args)) {
                $argumentList += $Item.Args
            }

            Start-Process -FilePath 'winget' -ArgumentList $argumentList -Wait
        }
        'RUN' {
            Invoke-Expression $Item.Target
        }
        'PS1' {
            Invoke-Expression ((Invoke-RestMethod -Uri $Item.Target -Method Get) | Out-String)
        }
        'SCRIPT' {
            $scriptTarget = Resolve-ScriptTarget -ScriptTarget $Item.Target
            if ($scriptTarget -match '^https?://') {
                Invoke-Expression ((Invoke-RestMethod -Uri $scriptTarget -Method Get) | Out-String)
            } else {
                & powershell.exe -ExecutionPolicy Bypass -File $scriptTarget
            }
        }
        default {
            throw "Unsupported action type: $($Item.Type)"
        }
    }
}

function Show-CategoryMenu {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Category
    )

    while ($true) {
        $items = Get-ManifestRecords -ManifestName ("windows_{0}.txt" -f $Category.Key) -FieldNames @('Name', 'Type', 'Target', 'Args', 'Confirm', 'Description')
        $selected = Select-Record -Title $Category.Name -Items $items -LabelProperty 'Name' -DescriptionProperty 'Description'

        if ($null -eq $selected) {
            return
        }

        if (-not (Confirm-Action -Item $selected)) {
            Write-Host "Action canceled." -ForegroundColor Yellow
            continue
        }

        try {
            Invoke-ManifestAction -Item $selected
            Write-Host ("Completed: {0}" -f $selected.Name) -ForegroundColor Green
        } catch {
            Write-Host ("Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }

        [void](Read-Host "Press Enter to continue")
    }
}

while ($true) {
    Write-Host ""
    Write-Host ("Welcome to {0}" -f $BrandName) -ForegroundColor Cyan

    $categories = Get-ManifestRecords -ManifestName 'windows_menu.txt' -FieldNames @('Name', 'Key', 'Description')
    $selectedCategory = Select-Record -Title 'Main Menu' -Items $categories -LabelProperty 'Name' -DescriptionProperty 'Description'

    if ($null -eq $selectedCategory) {
        break
    }

    Show-CategoryMenu -Category $selectedCategory
}
