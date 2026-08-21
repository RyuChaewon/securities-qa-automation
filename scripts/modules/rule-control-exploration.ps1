<#
.SYNOPSIS target-specific rule control 모듈의 호환 진입점이다.
.DESCRIPTION Context와 Discovery, Binding, Action 선언을 기존 소비자에게 한 번에 제공한다.
.NOTES 하위 모듈은 독립적으로 로드할 수 있으며 실행 로직과 상태는 명시적 context에만 둔다.
#>
. (Join-Path $PSScriptRoot 'hts-target-adapter.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-context.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-discovery.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-binding.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-action.ps1')
