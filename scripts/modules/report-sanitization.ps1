<#
.SYNOPSIS 결과 객체 안의 계좌번호·비밀번호·민감 입력값을 재귀적으로 마스킹한다.
.DESCRIPTION 실행기에서 dot-source하며 저장 직전 방어선으로 사용하므로 원문 비밀값을 반환하지 않는다.
.INPUTS 결과 객체와 제거해야 할 민감 문자열 집합.
.OUTPUTS 같은 구조를 유지한 채 문자열 값이 마스킹된 객체.
.NOTES 새 결과 필드를 추가할 때 저장 직전에 이 모듈을 통과하는지 확인하고 평문 비밀값을 로그에 남기지 않는다.
#>
function Set-RuleObjectStringProtection($Value, [Collections.Generic.HashSet[string]]$SensitiveValues) {
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType) { return }

    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($Value[$key] -is [string]) {
                $text = [string]$Value[$key]
                foreach ($sensitiveValue in $SensitiveValues) { $text = $text.Replace($sensitiveValue, "******") }
                $Value[$key] = $text
            } else {
                Set-RuleObjectStringProtection $Value[$key] $SensitiveValues
            }
        }
        return
    }

    if ($Value -is [Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            if ($Value[$index] -is [string]) {
                $text = [string]$Value[$index]
                foreach ($sensitiveValue in $SensitiveValues) { $text = $text.Replace($sensitiveValue, "******") }
                $Value[$index] = $text
            } else {
                Set-RuleObjectStringProtection $Value[$index] $SensitiveValues
            }
        }
        return
    }

    foreach ($property in $Value.psobject.Properties) {
        if ($property.Value -is [string]) {
            $text = [string]$property.Value
            foreach ($sensitiveValue in $SensitiveValues) { $text = $text.Replace($sensitiveValue, "******") }
            $property.Value = $text
        } else {
            Set-RuleObjectStringProtection $property.Value $SensitiveValues
        }
    }
}

# 화면 상단의 계좌형 숫자를 찾아 결과 행 전체에서 같은 원문을 재귀적으로 치환한다.
function Protect-RuleReportedSensitiveValues($ResultRow) {
    $sensitiveValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sensitiveControlIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($control in @($ResultRow.discoveredControls)) {
        $name = [string]$control.name
        $locatorParts = @([string]$control.locatorSignature -split '\|')
        $centerY = if ($locatorParts.Count -ge 4 -and $locatorParts[3] -match '^\d+$') { [int]$locatorParts[3] } else { [int]::MaxValue }
        $isOpaqueNumericAfx = $control.controlKind -eq "Button" -and $control.className -like "AfxWnd*" -and
            $name -match '^\d{4,8}$' -and [int]$control.tabOrder -le 2 -and $centerY -le 180
        if ($isOpaqueNumericAfx) {
            [void]$sensitiveValues.Add($name)
            [void]$sensitiveControlIds.Add([string]$control.controlId)
        }
    }

    if ($sensitiveValues.Count -eq 0) { return }
    Set-RuleObjectStringProtection $ResultRow $sensitiveValues
    foreach ($control in @($ResultRow.discoveredControls)) {
        if ($sensitiveControlIds.Contains([string]$control.controlId)) {
            $control.name = "민감 숫자(마스킹)"
            $control.initialValue = "******"
        }
    }
}
