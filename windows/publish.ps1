# Builds dist\CinqHeures.exe: one self-contained file that runs on Windows 10 1809+ / Windows 11, x64, with nothing
# installed first. Needs the .NET 10 SDK.
#
#   .\publish.ps1
#
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (Test-Path dist) { Remove-Item dist -Recurse -Force }
dotnet publish src/CinqHeures.App -c Release -p:Platform=x64 -p:PublishProfile=win-x64
if ($LASTEXITCODE -ne 0) { throw "publish failed" }
Remove-Item dist\*.pdb -ErrorAction SilentlyContinue
$exe = Get-Item dist\CinqHeures.exe
"{0}  ({1:N0} MB)" -f $exe.FullName, ($exe.Length / 1MB)
