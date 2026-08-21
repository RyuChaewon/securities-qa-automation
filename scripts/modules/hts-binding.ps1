<#
.SYNOPSIS 논리 역할과 승인된 시나리오 요구사항을 현재 HTS 컨트롤 identity에 연결한다.
.DESCRIPTION Binding은 탐색 snapshot을 소비해 후보를 선택하지만 UI 입력, 결과 판정 또는 리포트 작성을 수행하지 않는다.
#>

function New-HtsBindingContext {
    param(
        [Parameter(Mandatory = $true)]$DiscoveryContext,
        [Parameter(Mandatory = $true)]$Dependencies
    )

    [pscustomobject]@{
        DiscoveryContext = $DiscoveryContext
        Dependencies = $Dependencies
    }
}

function New-HtsExecutionCaseContext {
    param(
        [string]$ScreensCsv = '',
        [bool]$ScenarioMode = $false,
        $ScenarioPlan = $null,
        [string[]]$RequestedScenarioCaseIds = @(),
        [bool]$PlanOnly = $false,
        [string[]]$ExecutableScenarioCaseIds = @(),
        [Parameter(Mandatory = $true)]$Dataset,
        [Parameter(Mandatory = $true)]$TestPack
    )

    [pscustomobject]@{
        ScreensCsv = $ScreensCsv
        ScenarioMode = $ScenarioMode
        ScenarioPlan = $ScenarioPlan
        RequestedScenarioCaseIds = @($RequestedScenarioCaseIds)
        PlanOnly = $PlanOnly
        ExecutableScenarioCaseIds = @($ExecutableScenarioCaseIds)
        Dataset = $Dataset
        TestPack = $TestPack
    }
}

function Get-ExecutionCasesFromApprovedPlans {
    param([Parameter(Mandatory = $true)]$Context)

    $selected = @($Context.ScreensCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Context.ScenarioMode) {
        $plannedScreens = @{}
        foreach ($scenarioCase in @($Context.ScenarioPlan.cases)) {
            if ($selected.Count -gt 0 -and $selected -notcontains [string]$scenarioCase.screenNumber) { continue }
            if ($Context.RequestedScenarioCaseIds.Count -gt 0 -and $Context.RequestedScenarioCaseIds -notcontains [string]$scenarioCase.caseId) { continue }
            if (-not $Context.PlanOnly -and $Context.ExecutableScenarioCaseIds -notcontains [string]$scenarioCase.caseId) { continue }
            if ($Context.PlanOnly -and $Context.RequestedScenarioCaseIds.Count -eq 0) {
                $screenKey = [string]$scenarioCase.screenNumber
                if ($plannedScreens.ContainsKey($screenKey)) { continue }
                $plannedScreens[$screenKey] = $true
            }
            $screenRows = @($Context.Dataset.screens | Where-Object { [string]$_.screenNumber -eq [string]$scenarioCase.screenNumber -and $_.enabled -ne $false } | Select-Object -First 1)
            $accountRows = @($Context.Dataset.accounts | Where-Object { [string]$_.id -eq [string]$scenarioCase.accountId -and $_.enabled -ne $false } | Select-Object -First 1)
            if ($screenRows.Count -eq 0 -or $accountRows.Count -eq 0) { continue }
            $variables = @{}
            $expectedOutcomes = @{}
            foreach ($property in @($scenarioCase.values.PSObject.Properties)) {
                $variables[[string]$property.Name] = [string]$property.Value.value
                $expectedOutcomes[[string]$property.Name] = $property.Value.expectedOutcome
            }
            [pscustomobject]@{
                caseId=[string]$scenarioCase.caseId;screen=$screenRows[0];account=$accountRows[0]
                variables=$variables;variableExpectedOutcomes=$expectedOutcomes;scenarioCase=$scenarioCase
            }
        }
        return
    }
    foreach ($compiledCase in @($Context.TestPack.cases)) {
        if ($selected.Count -gt 0 -and $selected -notcontains [string]$compiledCase.screenNumber) { continue }
        $screen = @($Context.Dataset.screens | Where-Object { [string]$_.screenNumber -eq [string]$compiledCase.screenNumber } | Select-Object -First 1)
        if ($screen.Count -ne 1) { throw "TestPack 케이스의 화면이 datasetSnapshot에 없습니다: $([string]$compiledCase.caseId)" }
        $variables = @{}
        foreach ($property in @($compiledCase.variables.PSObject.Properties)) { $variables[[string]$property.Name] = [string]$property.Value }
        $expectedOutcomes = @{}
        foreach ($property in @($compiledCase.variableExpectedOutcomes.PSObject.Properties)) { $expectedOutcomes[[string]$property.Name] = $property.Value }
        $account = [pscustomobject]@{
            id = [string]$compiledCase.accountId
            accountNumber = [string]$compiledCase.accountNumber
            owner = [string]$compiledCase.accountOwner
            inputMode = [string]$compiledCase.inputMode
            passwordSecret = $compiledCase.passwordSecret
            enabled = $true
        }
        [pscustomobject]@{
            caseId = [string]$compiledCase.caseId
            screen = $screen[0]
            account = $account
            variables = $variables
            variableExpectedOutcomes = $expectedOutcomes
            testPackCase = $compiledCase
        }
    }
}

function Invoke-HtsBindingDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "HTS binding dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS binding dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

function Test-HtsBindingRegion {
    param($Candidate, $Screen, [string]$Region)

    if (-not $Region -or $Region -eq 'all') { return $true }
    $centerY = ($Candidate.rect.top + $Candidate.rect.bottom) / 2
    $height = [Math]::Max(1, $Screen.rect.height)
    $ratio = ($centerY - $Screen.rect.top) / $height
    switch ($Region.ToLowerInvariant()) {
        'top' { return $ratio -le 0.45 }
        'middle' { return $ratio -gt 0.25 -and $ratio -lt 0.75 }
        'bottom' { return $ratio -ge 0.55 }
        default { return $true }
    }
}

function Resolve-HtsRoleControl {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Screen,
        [Parameter(Mandatory = $true)][string]$Role,
        $Strategies
    )

    if (-not $Strategies) { return $null }
    $children = @(Invoke-HtsBindingDependency -Context $Context -Name 'GetChildWindows' -Arguments @([Int64]$Screen.hwnd) |
        Where-Object { $_.visible -and $_.enabled -and $_.rect.width -gt 4 -and $_.rect.height -gt 4 })
    foreach ($strategy in @($Strategies)) {
        if ($null -ne $strategy.relativeX -and $null -ne $strategy.relativeY) {
            $width = if ($strategy.width) { [int]$strategy.width } else { 24 }
            $height = if ($strategy.height) { [int]$strategy.height } else { 20 }
            $centerX = [int]$Screen.rect.left + [int]$strategy.relativeX
            $centerY = [int]$Screen.rect.top + [int]$strategy.relativeY
            return [pscustomobject]@{
                hwnd=0;parent=[Int64]$Screen.hwnd;pid=$Screen.pid;visible=$true;enabled=$true;hung=$false
                className='ConfiguredVisualHotspot';rawTitle=$Role;style=0
                rect=[pscustomobject]@{left=$centerX-[int]($width/2);top=$centerY-[int]($height/2);right=$centerX+[int]($width/2);bottom=$centerY+[int]($height/2);width=$width;height=$height}
            }
        }
        $isHeuristic = $null -ne $strategy.ordinal -and [string]::IsNullOrWhiteSpace([string]$strategy.nameRegex) -and
            [string]::IsNullOrWhiteSpace([string]$strategy.className) -and [string]::IsNullOrWhiteSpace([string]$strategy.controlType)
        if ($isHeuristic) { continue }
        $matches = @($children | Where-Object {
            $classMatch = -not $strategy.className -or $_.className -eq [string]$strategy.className
            $typeMatch = -not $strategy.controlType -or
                ([string]$strategy.controlType -eq 'Button' -and $_.className -like '*Button*') -or
                $_.className -eq [string]$strategy.controlType
            $nameMatch = -not $strategy.nameRegex -or $_.rawTitle -match [string]$strategy.nameRegex
            $regionMatch = Test-HtsBindingRegion $_ $Screen ([string]$strategy.relativeRegion)
            $passwordStyleMatch = $Role -ne 'password' -or (($_.style -band 0x20) -ne 0) -or ($_.rawTitle -match '비밀번호|Password|PIN')
            $classMatch -and $typeMatch -and $nameMatch -and $regionMatch -and $passwordStyleMatch
        } | Sort-Object { $_.rect.top }, { $_.rect.left })
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1 -and $null -ne $strategy.ordinal -and [int]$strategy.ordinal -lt $matches.Count) {
            return $matches[[int]$strategy.ordinal]
        }
    }
    $null
}

function Get-HtsClaimedControlHwndMap {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Screen,
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)]$Dataset
    )

    $claimedHwnds = @{}
    foreach ($role in @('account','password')) {
        $strategies = if ($Case.screen.locators -and $Case.screen.locators.PSObject.Properties.Name -contains $role) { $Case.screen.locators.$role } else { $Dataset.defaultLocators.$role }
        $claimed = Resolve-HtsRoleControl -Context $Context -Screen $Screen -Role $role -Strategies $strategies
        if ($claimed -and [Int64]$claimed.hwnd -ne 0) { $claimedHwnds[[Int64]$claimed.hwnd] = $true }
    }
    foreach ($name in @($Case.variables.Keys)) {
        $dimensionRows = @($Dataset.variables | Where-Object { $_.name -eq $name } | Select-Object -First 1)
        $dimension = if ($dimensionRows.Count -gt 0) { $dimensionRows[0] } else { [pscustomobject]@{targetRole="condition:$name"} }
        $role = if ($dimension.targetRole) { [string]$dimension.targetRole } else { "condition:$name" }
        $strategies = if ($Case.screen.locators -and $Case.screen.locators.PSObject.Properties.Name -contains $role) { $Case.screen.locators.$role } else { $null }
        $claimed = Resolve-HtsRoleControl -Context $Context -Screen $Screen -Role $role -Strategies $strategies
        if ($claimed -and [Int64]$claimed.hwnd -ne 0) { $claimedHwnds[[Int64]$claimed.hwnd] = $true }
    }
    $claimedHwnds
}

function Set-HtsScenarioPhysicalBinding {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$PlanItem,
        [Parameter(Mandatory = $true)]$ScenarioCase,
        $PhysicalPlan
    )

    if (-not $PhysicalPlan -or [string]$PlanItem.scenarioAction -in @('Restore','AssertPopup','AssertNoTransmission')) { return $PlanItem }
    $logicalName = if ([string]$PlanItem.controlLogicalName) { [string]$PlanItem.controlLogicalName } elseif ([string]$PlanItem.control.name) { [string]$PlanItem.control.name } else { [string]$PlanItem.control.mapModelId }
    $mapCode = [string]$PlanItem.mapScreenCode
    $state = [string]$PlanItem.stateContext
    $matches = @($PhysicalPlan.resolvedBindings | Where-Object {
        [string]$_.scenarioId -eq [string]$ScenarioCase.scenarioId -and
        [string]$_.logicalName -eq $logicalName -and
        (-not $mapCode -or [string]$_.mapScreenCode -eq $mapCode) -and
        $(if($state){[string]$_.requiredStateContext -eq $state}else{[string]::IsNullOrWhiteSpace([string]$_.requiredStateContext)})
    })
    if ($matches.Count -ne 1) {
        $PlanItem.status = 'PENDING'
        $PlanItem.errorCode = 'PHYSICAL_BINDING_DRIFT'
        $PlanItem.control | Add-Member -NotePropertyName pendingReason -NotePropertyValue "물리계획의 유일한 고정 바인딩을 찾지 못했습니다. logicalName=$logicalName, map=$mapCode, state=$state, matches=$($matches.Count)" -Force
        return $PlanItem
    }
    $fixed = $matches[0]
    $PlanItem | Add-Member -NotePropertyName physicalBinding -NotePropertyValue $fixed -Force
    $controlIdMatches = [string]$PlanItem.control.controlId -eq [string]$fixed.controlId
    $locatorMatches = [string]$PlanItem.control.locatorSignature -eq [string]$fixed.locatorSignature
    $executionEligible = [bool](Invoke-HtsBindingDependency -Context $Context -Name 'TestControlExecutionEligible' -Arguments @($PlanItem.control))
    if (-not ($controlIdMatches -and $locatorMatches -and $executionEligible)) {
        $PlanItem.status = 'PENDING'
        $PlanItem.errorCode = 'PHYSICAL_BINDING_DRIFT'
        $PlanItem.control | Add-Member -NotePropertyName pendingReason -NotePropertyValue "현재 후보가 물리계획의 고정 identity와 다릅니다. expected=$([string]$fixed.controlId), actual=$([string]$PlanItem.control.controlId), controlIdMatches=$controlIdMatches, locatorMatches=$locatorMatches, executionEligible=$executionEligible, automationEngine=$([string]$PlanItem.control.automationEngine)" -Force
    }
    $PlanItem
}

function Get-HtsRequiredQueryControls {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Screen,
        $Strategies
    )

    $rows = New-Object Collections.Generic.List[object]
    $seen = @{}
    $resolved = Resolve-HtsRoleControl -Context $Context -Screen $Screen -Role 'query' -Strategies $Strategies
    if ($resolved) {
        $key = if ([Int64]$resolved.hwnd -ne 0) { "hwnd:$([Int64]$resolved.hwnd)" } else { "point:$([int](($resolved.rect.left+$resolved.rect.right)/2)):$([int](($resolved.rect.top+$resolved.rect.bottom)/2))" }
        $seen[$key] = $true
        $rows.Add($resolved)
    }
    foreach ($candidate in @(Invoke-HtsBindingDependency -Context $Context -Name 'GetChildWindows' -Arguments @([Int64]$Screen.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.rect.width -gt 12 -and $_.rect.height -gt 10 -and
        $_.rawTitle -match '^(조회|전체조회|조회하기|검색|Search|Query)$' -and
        ($_.className -like '*Button*' -or $_.className -like 'AfxWnd*')
    } | Sort-Object enumerationIndex)) {
        $key = "hwnd:$([Int64]$candidate.hwnd)"
        if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; $rows.Add($candidate) }
    }
    foreach ($candidate in @(Get-HtsFlaUiActionableControls -Context $Context.DiscoveryContext -Screen $Screen | Where-Object { $_.rawTitle -match '^(조회|전체조회|조회하기|검색|Search|Query)$' })) {
        $centerX = [int](($candidate.rect.left+$candidate.rect.right)/2)
        $centerY = [int](($candidate.rect.top+$candidate.rect.bottom)/2)
        $key = "point:$centerX`:$centerY"
        if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; $rows.Add($candidate) }
    }
    $rows.ToArray()
}
