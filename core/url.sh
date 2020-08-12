#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

: ${__CURL_OPT="--connect-timeout 10 --location -k --silent --show-error"}
DONWLOAD_BACKEND=${1-ps}

if [[ "$(basename ${BASH_SOURCE-url.sh})" == "$(basename $0)" ]]; then

set -eu -o pipefail

usage()
{
	cat <<-\EOF
	Resolve URL filename and size.

	This script is primarily intended for a sourcing.

	    . url.sh curl <- BACKEND
	              v v v
	    if info=$(URL_info "$url"); then
	        size=$(echo "$info" | cut -d' ' -f1)
	        name=$(echo "$info" | cut -d' ' -f4)
	              v v v
	        URL_download "$url" "$DIR_OUR/$name"
	    fi

	Command line frontend is available for a testing:

	    script --[curl|ps] --[head|info|get|test] [URL|file] [output]

	Options:
	    --help    - Print this help
	    --curl|ps - Use Curl (default) or Powershell
	    --head    - Print headers. HEADERs only request.
	    --force   - Print response NORMAL request.
	    --info    - Print URL info (default)
	    --get     - Download to 'output'
	    --test    - Same as '--info' but for predefined list of URLs
	                or URL read from the file, one url per file
	Examples:
	    script https://github.com/git-for-windows/git-sdk-32/tarball/master
	    script --get http://releases.llvm.org/9.0.0/LLVM-9.0.0-win32.exe out.bin
	    script --test
	    script --test URLs.txt

	EOF
}

entrypoint()
{
	[[ "$#" == 0 ]] && usage 1>&2 && return 1
	local backend="" task=3
	for arg do
		shift
		case "$arg" in
			--help) usage; return;;
			--curl) DONWLOAD_BACKEND=curl; backend=true;;
			--ps) DONWLOAD_BACKEND=ps; backend=true;;
			--head) task=1;;
			--force) task=2;;
			--info) task=3;;
			--get) task=4;;
			--test) task=5;;
			*) set -- "$@" "$arg";;
		esac
	done

	if [[ $task == 1 ]]; then
		URL_headers "$@"
	elif [[ $task == 2 ]]; then
		URL_headers_FORCE "$@"
	elif [[ $task == 3 ]]; then
		URL_info "$@" --format
	elif [[ $task == 4 ]]; then
		URL_download "$@"
	else
		local URLs=
		if [[ "$#" != 0 ]]; then
			local url_list="$1"
			URLs=$(cat "$url_list" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/#.*//' | paste)
			shift
		else
			while read url; do
				URLs="$URLs $url"
			done <<-\URL
				https://github.com/microsoft/vswhere/releases/download/2.7.1/vswhere.exe
				https://www.apple.com/itunes/download/win64
				https://go.microsoft.com/fwlink/?LinkID=733265
				https://update.code.visualstudio.com/latest/win32-archive/insider
				https://github.com/git-for-windows/git-sdk-32/tarball/master
			URL
		fi

		local wmax=0
		if command -v tput &>/dev/null; then
			if [[ -t 1 ]]; then
				wmax=$(tput cols)
				wmax=$(( wmax - 63))
			fi
		fi
		for url in $URLs; do
			local url_short="$url"
			if [[ $wmax -gt 0 && ${#url} -gt $wmax ]]; then
				local tail=$(( wmax - 15 - 3))
				url_short=${url_short#*://}
			 	[[ $tail -gt 0 ]] && url_short="${url_short:0:15}...${url_short: -$tail}"
			fi

			if [[ -n "$backend" ]]; then
				x=$(URL_info "$url" "$@" --format)
				printf "%s: %-55s %s\n" "$DONWLOAD_BACKEND" "$x" "$url_short"
			else
				for i in curl ps; do
					DONWLOAD_BACKEND=$i
					x=$(URL_info "$url" "$@" --format)
					printf "%4s: %-55s %s\n" "$DONWLOAD_BACKEND" "$x" "$url_short"
				done
			fi
		done 
		echo "Done"
	fi
}

fi

__execute_script_ps()
{
	local context="$1"; shift
	local script="$1"; shift
	if [[ "$context" == back ]]; then
		powershell -nologo -executionpolicy bypass -c "& $script "$@"" &
		wait $!
	else
		# Assume, can be interrupted with Ctrl+Break
		powershell -nologo -executionpolicy bypass -c "& $script "$@""
	fi
}

__urldecode() { local x="${*//+/ }"; printf "${x//%/\\x}"; }

####################################
#  Info
####################################
filename_from_disposition()
{
	# exp: 'attachment; filename=aria2-1.35.0-win-32bit-build1.zip'
	local data="$1"
	local data=${data//;/ } # ';' -> ' '
	local x
	for x in $data; do
		if echo "$x" | grep -q -i 'filename='; then
			x=${x#*=}
			x=${x#\"}
			x=${x%\"}
			echo "$x"
			return
		fi
	done
	return 1
}
filename_from_location_PRMS()
{
	local url="$1"
	local opt=$(echo "$url" | cut -s -d'?' -f2-)
	opt=${opt//&/ } # '&' -> ' '
	local x
	for x in $opt; do
		local key=${x%%=*}
		local val=${x#*=}
		# exp: 'attachment; filename=aria2-1.35.0-win-32bit-build1.zip'
		if echo "$key" | grep -q -i 'content-disposition'; then
			val="$(__urldecode "$val")"
			if filename_from_disposition "$val"; then
				return
			fi
		fi
	done
	return 1
}
filename_from_url() # <=> extention(basename($url)) != empty
{
	local url="$1"
	local name="${url%%\?*}" 	# xxx?***
	name="${name##*/}"  		# ***/***/xxx
	local ext="${name##*.}" 	# ***.xxx
	if [[ "$name" != "$ext" ]]; then
		echo "$name"
	else
		return 1
	fi
}
URL_info()
{
	local arg format=""
	for arg do
		shift
		[[ "$arg" == "--format" ]] && format=true && continue
		set -- "$@" "$arg"
	done

	local url="$1"
	local headers dis src
	headers=$(URL_headers "$@")

	if 		dis="$(echo "$headers" | grep -i 'Location:' | tail -n1)" &&
			dis="$(filename_from_location_PRMS "$dis")"; then
			src=PRM
	elif 	dis="$(echo "$headers" | grep -i 'Content-Disposition:' | tail -n1)" &&
			dis="$(filename_from_disposition "$dis")"; then
			src=HDR
	elif	dis="$(filename_from_url "$url")"; then
			src=url
	elif	dis="$(echo "$headers" | grep -i 'Location:' | tail -n1)" &&
			dis="$(filename_from_url "$dis")"; then
			src=loc
   	else
			echo "error: can't detect filename for '$url'" 1>&2
			return 1
	fi

	local len
	if ! len="$(echo "$headers" | grep -i 'Content-Length:' | tail -n1 | cut -s -d' ' -f2)"; then
		headers=$(URL_headers_FORCE "$@")
		if ! len="$(echo "$headers" | grep -i 'Content-Length:' | tail -n1 | cut -s -d' ' -f2)"; then
			len=0
		fi
	fi

	local suff="B" num=1
	[[ $len -ge       1000 ]] && suff="K" &&        num=1000
	[[ $len -ge    1000000 ]] && suff="M" &&     num=1000000
	[[ $len -ge 1000000000 ]] && suff="G" &&  num=1000000000
	local sz=$(( len / num)).$(( (10*len / num) % 10)) # 0.0X - 999.9Y
	[[ $len == 0 ]] && sz="?.?"
	sz="$sz$suff"

	if [[ -z "$format" ]]; then
		echo "$len $dis $sz"
	else
		printf "%6s %3s %s\n" "$sz" "$src" "$dis"
	fi
}

####################################
# Headers
####################################
URL_headers()
{
	if [[ "$DONWLOAD_BACKEND" == ps ]]; then
		URL_headers_ps_WebRequest "$@"
	else
		URL_headers_curl "$@"
	fi
}
URL_headers_FORCE()
{
	if [[ "$DONWLOAD_BACKEND" == ps ]]; then
		URL_headers_ps_WebClient "$@"
	else
		URL_headers_curl_FORCE "$@"
	fi
}
URL_headers_curl()	# only headers
{
	curl $__CURL_OPT -L -I "$@"
}
URL_headers_curl_FORCE() # start download
{
	local stderr=$(mktemp url_headers.XXXXXX)
	set +e; # note, with --max-filesize curl doesn't print 'Content-Length' header
	curl $__CURL_OPT -L "$@" --max-time 5 --limit-rate 10K --dump-header - -o . 2>"$stderr"
	local error_code=$?
	set -e
	case $error_code in
		23) error_code=0;; # Failed writing body (Force exit ;-)
		28) error_code=0;; # max-time
		63) error_code=0;; # max-filesize
		 *) cat "$stderr" 1>&2 ;;
	esac
	rm -rf "$stderr"

	return $error_code
}


#;%!  Simple credential management in a form of: 
#$%^     'Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials;'
#*&#  ... is the only reason to use powershell for url requiest
#@'*     
#-(<      -= All other reasons are for the hate =-
URL_headers_ps_WebRequest()
{
	local url="$1"
	local script=$(cat <<-'SCRIPT'
		{
	    	Param([Uri] $url)
        	[bool] $haveResponseOk = $false;
            try {
            	while($true) {
            		$req = [Net.WebRequest]::Create($url);
            		$req.Method = "HEAD";
            		$req.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials;
            		$req.AllowAutoRedirect = $false;
            		$resp = $req.GetResponse(); # this will trig exception if request fail
            		[int] $status = $resp.StatusCode;
					foreach ($i in $resp.Headers ) {
						Write-Output "${i}: $($resp.Headers[$i])";
					}
					Write-Output "";
            		if ($status -le 400) {	
            			$haveResponseOk = $true;
            		}
            		if ($status -ge 300 -and $status -lt 400) {
            			$url = $resp.GetResponseHeader('Location');
            			continue;
            		}
            		break;
    	        }
	        } catch { # Can't write to STDERR. This exception may also be trigged in a normal case
#            	Write-Output $_;	# How do people write scripts in PS ? - They have objects, they need no STDERR
            }						# Do people write real scripts in PS ? Also, this is not clear how to catch response error in this simple case.
            if (! $haveResponseOk ) {	# Is PowerScript for a scripting ?
            	exit 1;
        	}
	    	exit 0;
		}
		SCRIPT
	)
	__execute_script_ps front "$script" "$url"
}

URL_headers_ps_WebClient()
{
   	# - Can't get redirection headers with the WebClient API. This privent us from
	#   extracing 'content-disposition' header from the 'location' url (github).
	# + As usual, provides 'content-length' header we fail to get with curl 
	#	and WebRequest. Most likely, WebClient starts downloading then stops.
   	# - This hangs user process. User script should (good to) execute it in a backgound.
	local url="$1"
	local script=$(cat <<-'SCRIPT'
		{
	    	Param([Uri] $url)
            try {
				$ErrorActionPreference = "Stop";
				$c = new-object System.Net.WebClient;
				$c.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials;
				$c.OpenRead($url) | Out-Null;
				# Write-Output $c | gm
				# Write-Output $c | Select-Object -Property *
				# Write-Output $c.ResponseHeaders["Content-Length"];
				foreach ($i in $c.ResponseHeaders ) {
					Write-Output "${i}: $($c.ResponseHeaders[$i])";
				}
			} catch {
#            	Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)
	__execute_script_ps back "$script" "$url"
}

####################################
# Download
####################################
URL_download()
{
	if [[ "$DONWLOAD_BACKEND" == ps ]]; then
		URL_download_ps "$@"
	else
		URL_download_curl "$@"
	fi
}

URL_download_curl()
{
	local url="$1"; shift
	local dst="$1"; shift
	curl $__CURL_OPT -o "$dst" "$url"
}

URL_download_ps()
{
	local url="$1"; shift
	local dst="$1"; shift
	local script_show_proxy=$(cat <<-'SCRIPT'
            try {
				$progressPreference = 'silentlyContinue' 
				$ErrorActionPreference = 'Stop';
				$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
				if ($proxy) {
					$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials;
					$proxyUrl = $proxy.GetProxy("google.com");
					if ($proxyUrl) {
    	        		Write-Host "proxy: $proxyUrl";
					}
				}
			} catch {
				Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)

	local script=$(cat <<-'SCRIPT'
		{   # This does wrong things on double redirect: https://sourceforge.net/projects/sevenzip/files/7-Zip/19.00/7z1900.msi
			#
			# TODO: check proxy
			# https://stackoverflow.com/questions/20471486/how-can-i-make-invoke-restmethod-use-the-default-web-proxy
	    	Param([Uri] $url, [string] $dst)
            try {
				$progressPreference = 'silentlyContinue' 
				$ErrorActionPreference = 'Stop';
				$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
				if ($proxy.IsBypassed($url)) {
					Invoke-WebRequest -Uri $url -OutFile $dst;
				} else {
					$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials;
					$proxyUrl = $proxy.GetProxy("$url");
            		Write-Host "using proxy: $proxyUrl";
					Invoke-WebRequest -Uri $url -OutFile $dst -UseDefaultCredentials \
						-Proxy "$proxyUrl" -ProxyUseDefaultCredentials;
				}
			} catch {
				Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)
	# this hangs user script but known work with proxy well
	# 40Mb of 51Mb downloaded : http://repo.msys2.org/distrib/msys2-x86_64-latest.tar.xz
	# with an exit code of '0' - do not know what to do !!!
	# Can't handle redirect.
	local script2=$(cat <<-'SCRIPT'
		{
	    	Param([Uri] $url, $dst)
            try {
				$ErrorActionPreference = "Stop";
				$c = new-object System.Net.WebClient;
				$c.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials;
				$c.DownloadFile($url, $dst);
			} catch {
            	# Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)

	if [[ ${SHOW_PROXY-:0} == 0 ]]; then
		__execute_script_ps front "$script_show_proxy"
		export SHOW_PROXY=1
	fi
	__execute_script_ps front "$script" "$url" "$dst"
	#__execute_script_ps back "$script2" "$url" "$dst"
}

if [[ "$(basename ${BASH_SOURCE-url.sh})" == "$(basename $0)" ]]; then
	entrypoint "$@"
fi
