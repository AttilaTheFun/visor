# The dev layer on Windows, all through winget: Bazelisk (with `bazel`),
# Git and Chrome; Bazel's caches kept out of Defender's scans.
$ErrorActionPreference = 'Stop'
foreach ($id in 'Bazel.Bazelisk', 'Git.Git', 'Google.Chrome') {
  winget install --id $id --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
}
$links = "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
$target = @((Get-Item "$links\bazelisk.exe").Target)[0]
New-Item -ItemType SymbolicLink -Path "$links\bazel.exe" -Target $target -Force | Out-Null
Add-MpPreference -ExclusionPath "$env:USERPROFILE\_bazel_runner", "$env:LOCALAPPDATA\bazelisk"
"dev: " + (& 'C:\Program Files\Git\cmd\git.exe' --version)
