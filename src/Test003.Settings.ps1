# specify the minumum required major PowerShell version that the build script should validate
[int]$script:requiredPSVersion = '5'
$script:PSRepository = @{
    Name                      = 'PSTestGallery'
    SourceLocation            = 'https://www.poshtestgallery.com/api/v2'
    PackageManagementProvider = 'NuGet'
    PublishLocation           = 'https://www.poshtestgallery.com/api/v2/package/'
    ScriptSourceLocation      = 'https://www.poshtestgallery.com/api/v2/items/psscript'
    ScriptPublishLocation     = 'https://www.poshtestgallery.com/api/v2/package/'
}

function Get-ModuleFingerPrint {
    param (
        $ModuleName
    )
    $ModuleVersion = (Get-Module $ModuleName).Version
    $commandList = Get-Command -Module $ModuleName
    Write-Build White "Calculating fingerprint Module: $ModuleName, $ModuleVersion"
    foreach ( $command in $commandList ) {
        if ($command.Parameters.Count -gt 0) {
            foreach ( $parameter in $command.parameters.keys ) {
                '{0}:{1}' -f $command.name, $command.parameters[$parameter].Name
                $command.parameters[$parameter].aliases |
                Foreach-Object { '{0}:{1}' -f $command.name, $_ }
            }
        }
        else {
            '{0}:' -f $command.name
        }
    }
}

Add-BuildTask PostInit -After Init {
    $ProjectRoot = Split-Path -Path $BuildRoot -Parent
    $ProjectName = $script:ModuleName
    $Repo = Get-GitHubRepository -RepositoryName $ProjectName
    $HashArguments = @{
        OwnerName      = $Repo.owner.UserName
        RepositoryName = $Repo.name
        BranchName     = 'main'
    }
    $StatusChecks = Get-ChildItem (Join-Path $ProjectRoot '.github/workflows/*.yml') |
    Select-String '(?:name:\s+?)(Run Test.*?$)' |
    Select-Object -ExpandProperty matches |
    Select-Object -ExpandProperty Groups |
    Where-Object name -eq  1 |
    Select-Object -ExpandProperty Value
    New-GitHubRepositoryBranchProtectionRule @HashArguments -StatusChecks $StatusChecks -EnforceAdmins
    Write-Build Green "      ...Repository Rules added successfully"
}

Add-BuildTask Init {
    Write-Build White '      Initialising Repository'
    $ProjectRoot = Split-Path -Path $BuildRoot -Parent
    $ProjectName = $script:ModuleName
    Push-Location $ProjectRoot
    $Repo = New-GitHubRepository -OrganizationName 'Riot-Enterprises' -RepositoryName $ProjectName
    if (!(Test-Path README.md)) {
        Set-Content -Path README.md -Value "# $ProjectName"
    }
    git init
    git add .
    git reset -- src/*
    git commit -m "Feat(Envirnment): :wrench: Initial commit infrastructure" --author 'Automation <auto@madspaniels.co.uk>'
    git branch -M main
    git remote add origin $repo.clone_url
    git push -u origin main
    git checkout -b Initial_Template
    git add .
    git commit -m "Feat(Module): :tada: Create Module from Template" --author 'Automation <auto@madspaniels.co.uk>'
    Pop-Location
    Write-Build Green "      ...Repository initialiased successfully"
}

Add-BuildTask GetPublishedModule -Before GenerateModuleVersion {
    try {
        $null = Get-PSRepository $script:PSRepository.Name -ErrorAction Stop
    }
    catch {
        $null = register-psrepository @script:PSRepository
    }
    try {
        $script:PublishedModule = Install-Module -Name $script:ModuleName -Repository $script:PSRepository.Name -Force -PassThru -ErrorAction Stop
        Import-Module "$($PublishedModule.InstalledLocation)/$script:ModuleName.psd1" -Force -ErrorAction Stop
        $script:PublishedModuleFingerprint = Get-ModuleFingerPrint $script:ModuleName
        Remove-Module $script:ModuleName -Force -ea Stop
    }
    catch {
        Write-Build Yellow "No Published Module"
        $script:PublishedModuleFingerprint = $null
    }
}

Add-BuildTask GenerateModuleVersion -Before FixManifest {
    if ($script:PublishedModuleFingerprint) {
        Import-Module $script:ModuleManifestFile -Force
        $script:ModuleFingerprint = Get-ModuleFingerPrint $script:ModuleName
        Remove-Module $script:ModuleName -Force
        $bumpVersionType = 'Patch'
        'Detecting new features'
        $script:ModuleFingerprint | Where-Object { $_ -notin $script:PublishedModuleFingerprint } |
        ForEach-Object {
            $bumpVersionType = 'Minor';
            Write-Build Yellow "    New Feature:  $_"
        }
        'Detecting breaking changes'
        $script:PublishedModuleFingerprint | Where-Object { $_ -notin $script:ModuleFingerprint } |
        ForEach-Object {
            $bumpVersionType = 'Major';
            Write-Build Red "Removed Feature:  $_"
        }
        $script:NewVersion = Step-Version -Version $script:PublishedModule.Version -By $bumpVersionType
        Write-Build Yellow "Published Version: $($script:PublishedModule.Version) $bumpVersiontype"
    }
    else {
        $script:NewVersion = $null
    }
    $TagVersion = (git ls-remote --tags origin | Select-String '\d+?\.\d+?\.\d+?' |
        Select-Object -ExpandProperty Matches | Select-Object -expandProperty Value |
        ForEach-Object { [Version]$_ } | Sort-Object -Descending |
        Select-Object -First 1)
    if ($TagVersion){
        Write-Build Yellow "Git Tag Version: $Tagversion"
        if ($TagVersion -ge [Version]$script:NewVersion){
            Write-Build 'Bumping Git Tag Version'
            $script:NewVersion = Step-Version -Version $TagVersion -By Patch
        }
    }
    Write-Build Yellow "New Generated Version: $script:NewVersion"
}

Add-BuildTask FixManifest -After Clean {
    $projectURI = (git config --get remote.origin.url) -replace '\.git',''
    $branch= (git rev-parse --abbrev-ref HEAD)
    $script:HashArguments = @{
        ProjectUri = $projectURI +'/'
        LicenseUri = $projectURI + "/blob/$branch/LICENSE"
        ReleaseNotes = $projectURI + "/blob/$branch/.github/CHANGELOG.md"
        FunctionsToExport = '*'
        CmdletsToExport = ''
        AliasesToExport = ''
    }
    if ($script:NewVersion) {
        $script:HashArguments.ModuleVersion = $script:NewVersion
    }
    if (Test-Path (Join-Path (Split-Path -Path $BuildRoot -Parent) (Join-Path "media" "$script:ModuleName.png")) -PathType Leaf ){
        $script:HashArguments.IconUri = $projectURI + "/raw/$branch/media/$script:ModuleName.png"
    }
    $script:HashArguments
    Update-ModuleManifest -Path $script:ModuleManifestFile @script:HashArguments
    Set-ModuleFunction -Path $script:ModuleManifestFile
    if (git diff --name-only $script:ModuleManifestFile) {
        $Branch = (git rev-parse --abbrev-ref HEAD)
        if ($Branch -ne 'main'){
            git reset
            git add $script:ModuleManifestFile
            git commit --author 'Automation <auto@madspaniels.co.uk>' -m 'refactor: :package: Automated update of Module Manifest'
        }
        $manifestInfo = Import-PowerShellDataFile -Path $script:ModuleManifestFile
        $script:ModuleVersion = $manifestInfo.ModuleVersion
        $script:ModuleDescription = $manifestInfo.Description
        $script:FunctionsToExport = $manifestInfo.FunctionsToExport
    }
}

Add-BuildTask Commitdocs -After Build {
    $ProjectRoot = Split-Path -Path $BuildRoot -Parent
    $DocsPath = (Join-Path $ProjectRoot 'Docs\*.md')
    $Branch = (git rev-parse --abbrev-ref HEAD)
    if ($Branch -ne 'main'){
        git reset
        git add $DocsPath
        git commit --author 'Automation <auto@madspaniels.co.uk>' -m 'docs: :memo: Automated update of Project Documentation'
    }
}
