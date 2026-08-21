<#
.SYNOPSIS 한 번의 HTS rule-suite 실행에서 공유되는 대상 창과 입력 정책 상태를 격리한다.
.DESCRIPTION orchestration과 책임 모듈 사이에 명시적으로 전달되며 script/global 변수를 사용하지 않는다.
#>
function New-HtsRunContext {
    param(
        [string]$TargetWindowClassName,
        [string]$TargetWindowTitlePrefix,
        [regex]$TargetScreenIdRegex,
        [regex]$TargetScreenTitleRegex,
        [regex]$TargetMapScreenCodeRegex,
        [string[]]$InitiallyActiveMapScreenCodes = @(),
        [bool]$VisiblePointerMotion = $false,
        [int]$PointerDwellMilliseconds = 0
    )
    [pscustomobject]@{
        TargetWindowClassName = $TargetWindowClassName
        TargetWindowTitlePrefix = $TargetWindowTitlePrefix
        TargetScreenIdRegex = $TargetScreenIdRegex
        TargetScreenTitleRegex = $TargetScreenTitleRegex
        TargetMapScreenCodeRegex = $TargetMapScreenCodeRegex
        InitiallyActiveMapScreenCodes = @($InitiallyActiveMapScreenCodes)
        VisiblePointerMotion = $VisiblePointerMotion
        PointerDwellMilliseconds = $PointerDwellMilliseconds
        LastTextAutomationEngine = '미실행'
    }
}
