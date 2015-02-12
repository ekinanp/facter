### Set variables from command line
# $arch => Choose 32 or 64-bit build
# $cores => Set the number of cores to use for parallel builds
# $buildSource => Choose whether to download pre-built libraries or build from source
param (
[int] $arch=64,
[int] $cores=2,
[bool] $buildSource=$FALSE,
[string] $cfacterRef='origin/master',
[string] $cfacterFork='git://github.com/puppetlabs/cfacter'
)

# Ensure TEMP directory is set and exists. Git.install can fail otherwise.
try { if (!(Test-Path $env:TEMP)) { throw } }
catch { $env:TEMP = Join-Path $env:SystemDrive 'temp' }
if (!(Test-Path $env:TEMP)) { mkdir -Path $env:TEMP }

# Starting from a base Windows Server 2008r2 or 2012r2 installation, install required tools, setup the PATH, and download and build software.
# This script can be run directly from the web using "iex ((new-object net.webclient).DownloadString('<url_to_raw>'))"

### Configuration
## Setup the working directory
$sourceDir=$pwd

echo $arch
echo $cores
echo $buildSource


$mingwVerNum = "4.8.3"
$mingwVerChoco = "${mingwVerNum}"
$mingwThreads = "win32"
if ($arch -eq 64) {
  $mingwExceptions = "seh"
  $mingwArch = "x86_64"
} else {
  $mingwExceptions = "sjlj"
  $mingwArch = "i686"
}
$mingwVer = "${mingwArch}_mingw-w64_${mingwVerNum}_${mingwThreads}_${mingwExceptions}"

$boostVer = "boost_1_55_0"
$boostPkg = "${boostVer}-${mingwVer}"

$yamlCppVerNum = "0.5.1"
$yamlCppVer = "yaml-cpp-${yamlCppVerNum}"
$yamlPkg = "${yamlCppVer}-${mingwVer}"

### Setup, build, and install
## Install Chocolatey, then use it to install required tools.
iex ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
$plmirror = "https://www.myget.org/F/puppetlabs"
choco install -y 7zip.commandline -version 9.20.0.20150210 -source $plmirror -debug
choco install -y cmake -version 3.0.2.20150210 -source $plmirror -debug
choco install -y git.install -version 1.9.5.20150210 -source $plmirror -debug
choco install -y python -version 3.4.2.20150210 -source $plmirror -debug
choco install -y doxygen.install -version 1.8.9.101 -source $plmirror -debug
if ($arch -eq 64) {
  choco install -y ruby -version 2.1.5.20150210 -source $plmirror -debug
  choco install -y mingw-w64 -version "${mingwVerChoco}" -source $plmirror -debug
} else {
  choco install -y ruby -version 2.1.5.20150210 -x86 -source $plmirror -debug
  choco install -y mingw-w32 -version "${mingwVerChoco}" -source $plmirror -debug
}
$env:PATH = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
if ($arch -eq 32) {
  $env:PATH = "C:\tools\mingw32\bin;" + $env:PATH
}
$env:PATH += [Environment]::GetFolderPath('ProgramFilesX86') + "\git\cmd"
echo $env:PATH
cd $sourceDir

## Download cfacter and setup build directories
git clone --recursive $cfacterFork cfacter
cd cfacter
git checkout $cfacterRef
mkdir -Force release
cd release
$buildDir=$pwd
$toolsDir="${sourceDir}\deps"
mkdir -Force $toolsDir
cd $toolsDir

if ($buildSource) {
  ## Download, build, and install Boost
  (New-Object net.webclient).DownloadFile("http://downloads.sourceforge.net/boost/$boostVer.7z", "$toolsDir\$boostVer.7z")
  & 7za x "${boostVer}.7z" | FIND /V "ing "
  cd $boostVer

  .\bootstrap mingw
  $args = @(
    'toolset=gcc',
    "--build-type=minimal",
    "install",
    "--with-program_options",
    "--with-system",
    "--with-filesystem",
    "--with-date_time",
    "--with-thread",
    "--with-regex",
    "--with-log",
    "--with-locale",
    "--prefix=`"$toolsDir\$boostPkg`"",
    "boost.locale.iconv=off"
    "-j$cores"
  )
  .\b2 $args
  cd $toolsDir

  ## Download, build, and install yaml-cpp
  (New-Object net.webclient).DownloadFile("https://yaml-cpp.googlecode.com/files/${yamlCppVer}.tar.gz", "$toolsDir\${yamlCppVer}.tar.gz")
  & 7za x "${yamlCppVer}.tar.gz"
  & 7za x "${yamlCppVer}.tar" | FIND /V "ing "
  cd $yamlCppVer
  mkdir build
  cd build

  $args = @(
    '-G',
    "MinGW Makefiles",
    "-DBOOST_ROOT=`"$toolsDir\$boostPkg`"",
    "-DCMAKE_INSTALL_PREFIX=`"$toolsDir\$yamlPkg`"",
    ".."
  )
  cmake $args
  mingw32-make install -j $cores
} else {
  ## Download and unpack Boost from a pre-built package in S3
  (New-Object net.webclient).DownloadFile("https://s3.amazonaws.com/kylo-pl-bucket/${boostPkg}.7z", "$toolsDir\${boostPkg}.7z")
  & 7za x "${boostPkg}.7z" | FIND /V "ing "

  ## Download and unpack yaml-cpp from a pre-built package in S3
  (New-Object net.webclient).DownloadFile("https://s3.amazonaws.com/kylo-pl-bucket/${yamlPkg}.7z", "$toolsDir\${yamlPkg}.7z")
  & 7za x "${yamlPkg}.7z" | FIND /V "ing "
}

## Build CFacter
cd $buildDir
$args = @(
  '-G',
  "MinGW Makefiles",
  "-DBOOST_ROOT=`"$toolsDir\$boostPkg`"",
  "-DBOOST_STATIC=ON",
  "-DYAMLCPP_ROOT=`"$toolsDir\$yamlPkg`"",
  ".."
)
cmake $args
mingw32-make -j $cores

## Test the results.
ctest -V 2>&1 | c++filt
