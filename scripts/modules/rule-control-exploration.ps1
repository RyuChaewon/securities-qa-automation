<#
.SYNOPSIS target-specific rule control 모듈의 호환 진입점이다.
.DESCRIPTION Discovery, Binding, Action 구현을 고정된 순서로 로드한다.
.NOTES 기존 dot-source 소비자를 유지하며 실행 로직은 하위 모듈에만 둔다.
#>
. (Join-Path $PSScriptRoot 'hts-target-rule-context.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-discovery.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-binding.ps1')
. (Join-Path $PSScriptRoot 'hts-target-rule-action.ps1')
