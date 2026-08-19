<#
.SYNOPSIS 녹화 프레임 경계와 잘림 여부를 확인하기 위한 테스트 창을 표시한다.
.DESCRIPTION 실제 HTS가 아닌 색상 패널 창으로 녹화기 자체를 검증할 때만 사용한다.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "HTS Recorder Full Window Smoke"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size 1133, 777
$form.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 248)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable

# 한쪽 창 경계에 고대비 패널을 붙여 녹화 결과의 잘림을 눈으로 판별하게 한다.
function Add-EdgePanel([System.Windows.Forms.DockStyle]$Dock, [System.Drawing.Color]$Color, [string]$Text) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = $Dock
    $panel.BackColor = $Color
    if ($Dock -in @([System.Windows.Forms.DockStyle]::Top, [System.Windows.Forms.DockStyle]::Bottom)) {
        $panel.Height = 42
    } else {
        $panel.Width = 42
    }
    $label = New-Object System.Windows.Forms.Label
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.Text = $Text
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.Font = New-Object System.Drawing.Font "Segoe UI", 11, ([System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::White
    $panel.Controls.Add($label)
    $form.Controls.Add($panel)
}

Add-EdgePanel ([System.Windows.Forms.DockStyle]::Top) ([System.Drawing.Color]::FromArgb(0, 114, 178)) "TOP EDGE - MUST BE VISIBLE"
Add-EdgePanel ([System.Windows.Forms.DockStyle]::Bottom) ([System.Drawing.Color]::FromArgb(213, 94, 0)) "BOTTOM EDGE - MUST BE VISIBLE"
Add-EdgePanel ([System.Windows.Forms.DockStyle]::Left) ([System.Drawing.Color]::FromArgb(0, 158, 115)) "L"
Add-EdgePanel ([System.Windows.Forms.DockStyle]::Right) ([System.Drawing.Color]::FromArgb(204, 121, 167)) "R"

$center = New-Object System.Windows.Forms.Label
$center.Dock = [System.Windows.Forms.DockStyle]::Fill
$center.Text = "DPI-AWARE FULL WINDOW RECORDING`r`nEvery colored edge must remain visible in the PNG and MP4."
$center.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$center.Font = New-Object System.Drawing.Font "Segoe UI", 18, ([System.Drawing.FontStyle]::Bold)
$center.ForeColor = [System.Drawing.Color]::FromArgb(24, 50, 74)
$form.Controls.Add($center)
$center.BringToFront()

[System.Windows.Forms.Application]::Run($form)
