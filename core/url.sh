#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

: ${__CURL_OPT="--location -k --silent --show-error"}
URL_BACKEND=${1-curl}
URL_TIMEOUT_SEC=

if [[ "$(basename ${BASH_SOURCE-url.sh})" == "$(basename $0)" ]]; then

set -eu -o pipefail

usage()
{
	cat <<-\EOF
	Resolve URL filename and size.

	This script is primarily intended for a sourcing.

	    . url.sh

	    URL_set_backend curl # or 'ps'

	    if info=$(URL_info "$url"); then
	        size=$(echo "$info" | cut -d' ' -f1)
	        name=$(echo "$info" | cut -d' ' -f4)

	        URL_download "$url" "$DIR_OUR/$name"
	    fi

	Command line frontend is available for a testing:

	    script --[curl|ps] --[head|info|get|test] [URL|file] [output]

	Options:
	    --help         - Print this help
	    --curl|ps1|ps2 - Use Curl (default) or Powershell
	                         ps1 - use WebRequest API
	                         ps2 - use WebClient API
	                     'ps' works well with corporate proxy, try both
	                     variants to check which one works best in your case.
	    --head         - Print headers. HEADERs only request.
	    --force        - Print response NORMAL request.
	    --info         - Print URL info (default)
	    --get          - Download to 'output'
	    --test         - Same as '--info' but for predefined list of URLs
	                     or URL read from the file, one url per file
	Examples:
	    url.sh https://github.com/git-for-windows/git-sdk-32/tarball/master
	    url.sh --get http://releases.llvm.org/9.0.0/LLVM-9.0.0-win32.exe out.bin
	    url.sh --test
	    url.sh --test URLs.txt

	EOF
}

entrypoint()
{
	[[ $# == 0 ]] && usage 1>&2 && return 1
	local backend="" task=3
	for arg do
		shift
		case "$arg" in
			-h|--help) usage; return;;
			--curl) URL_BACKEND=curl; backend=true;;
			--ps1)  URL_BACKEND=ps1; backend=true;;
            --ps2)  URL_BACKEND=ps2; backend=true;;
			--head) task=1;;
			--force) task=2;;
			--info) task=3;;
			--get) task=4;;
			-t|--test) task=5;;
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
		if [[ $# != 0 ]]; then
			local url_list=$1
			URLs=$(cat "$url_list" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/#.*//' | grep '^http' | paste)
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
        make_short_name() {
            local wmax=$1; shift
            local name=$1; shift
			if [[ $wmax -eq 0 || ${#name} -le $wmax ]]; then
                REPLY=$name
            else
				local tail=$(( wmax - 15 - 3 ))
				name=${name#*://}
			 	[[ $tail -gt 0 ]] && REPLY=${name:0:15}...${name: -$tail}
			fi
        }
		for url in $URLs; do
			local url_short=$url
            make_short_name $wmax $url; url_short=$REPLY
			if [[ -n "$backend" ]]; then
				URL_info "$url" "$@" --format
				printf "%s: %-55s %s\n" "$URL_BACKEND" "$REPLY" "$url_short"
			else
				for i in curl ps1 ps2; do
					URL_BACKEND=$i
					URL_info "$url" "$@" --format
					printf "%4s: %-55s %s\n" "$URL_BACKEND" "$REPLY" "$url_short"
				done
			fi
		done 
		echo "Done"
	fi
}

fi

__execute_script_ps()
{
	local context=$1; shift
	local script=$1; shift
	if [[ "$context" == back ]]; then
		powershell -nologo -executionpolicy bypass -c "& $script "$@"" &
		wait $!
	else
		# Assume, can be interrupted with Ctrl+Break
		powershell -nologo -executionpolicy bypass -c "& $script "$@""
	fi
}

__urldecode() { local x=${*//+/ }; printf "${x//%/\\x}"; }

URL_set_backend()
{
    local backend=$1; shift
    case $backend in
        curl) URL_BACKEND=curl;;
        ps1)  URL_BACKEND=ps1;;
        ps2)  URL_BACKEND=ps2;;
        *)    echo "error: unknown backend '$backend'" 1>&2 && return 1
    esac    
}

URL_set_timeout_sec()
{
    URL_TIMEOUT_SEC=$1
}

####################################
#  Info
####################################
filename_from_url() # <=> basename($url)
{
	local url=$1
	local name=${url%%\?*} 	# xxx?***
	name=${name##*/}  		# ***/***/xxx
    REPLY=${name}
}

filename_from_request()
{
	local url=$1
    local addr=${url%%'?'*}
    local args=${url#$addr}
    [[ -n "$args" ]] && REPLY= && return
    filename_from_url "$url"
}

trim_leading_spaces()
{
	REPLY=${1#"${1%%[! $'\t']*}"} # Remove leading whitespaces 
}

extract_value_from_headers()
{
    local headers=${1//$'\r'/}; shift
    local TARGET_KEY=$1; shift
    local RETVAL_key= RETVAL_val=

    process_kw() {
        local key=$1; shift
        local val=$1; shift
        extract_value_by_key() { # key=val; key=val; ...
            local data=${1// /}; shift
            local wanted_key=$1; shift
            data=${data//;/ }
            for REPLY in $data; do
                local key=${REPLY%%=*}
                if [[ $key == $wanted_key ]]; then
                    REPLY=${REPLY#$wanted_key}; REPLY=${REPLY#=}
                    return
                fi
            done
            REPLY=
        }
        REPLY=
        if [[ $TARGET_KEY == disposition ]]; then
            case $key in *[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Dd][Ii][Ss][Pp][Oo][Ss][Ii][Tt][Ii][Oo][Nn])
                extract_value_by_key "$val" filename;;
            esac
        fi
        if [[ $TARGET_KEY == location ]]; then
            case $key in [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]) filename_from_request "$val"; esac
        fi
        if [[ $TARGET_KEY == filesize ]]; then
            case $key in *[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]) REPLY=$val;; esac
        fi
        if [[ -n "$REPLY" ]]; then
             RETVAL_key=$key
             RETVAL_val=$REPLY
             return 1 # stop reading
        fi
    }

    process_url_headers() {
        local headers=$1; shift
        local process_kw=$1; shift
    
        process_url_request() {
            local url=$1; shift
            local process_kw=$1; shift
            local addr=${url%%'?'*} kw
            local args=${url#$addr}; args=${args#'?'} args=${args//'&'/ }
            #printf "%s\n%s\n" "addr=$addr" "args=$args"
            urldecode() { local x=${*//+/ }; printf -v REPLY "${x//%/\\x}"; }
            for kw in $args; do
                urldecode $kw; kw=$REPLY
                local key=${kw%%=*}
                local val=${kw#$key}; val=${val#=}
                $process_kw "$key" "$val" || return
            done
            if [[ -z "$args" ]]; then
               $process_kw "location" "$addr" || return
            fi
        }
        while read -r; do
            local key=${REPLY%%:*}
            local val=${REPLY#$key}; val=${val#:}
            trim_leading_spaces "$val"; val=$REPLY
            REPLY=
            case $key in
                [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn])
                    process_url_request "$val" $process_kw || return 0;;
                *) $process_kw "$key" "$val" || return 0;;
            esac
        done <<-EOF
    		$headers
EOF
    }

    process_url_headers "$headers" process_kw
#    echo "[$RETVAL_key]=$RETVAL_val"
    REPLY=$RETVAL_val
}

URL_info()
{
	local arg format=""
	for arg do
		shift
		[[ "$arg" == --format ]] && format=true && continue
		set -- "$@" "$arg"
	done

	local url=$1
	local headers filename= filesize=
	headers=$(URL_headers "$@")
    # reverse list since we need latest headers first
    headers=$(echo "$headers" | tac | tr -d $'\r')

    [[ -z "$filename" ]] && extract_value_from_headers "$headers" disposition && filename=$REPLY
    [[ -z "$filename" ]] && extract_value_from_headers "$headers" location && filename=$REPLY
	[[ -z "$filename" ]] && filename_from_url "$url" && filename=$REPLY
    filename=${filename//\"/} # trim quotes
    [[ -z "$filename" ]] && echo "error: can't detect filename for '$url'" 1>&2 && return 1
    [[ -z "$filesize" ]] && extract_value_from_headers "$headers" filesize && filesize=$REPLY
	local len
	if [[ -z "$filesize" ]]; then
		headers=$(URL_headers_FORCE "$@")
        headers=$(echo "$headers" | tac | tr [A-Z] [a-z])
        extract_value_from_headers "$headers" filesize; filesize=$REPLY
	fi
    [[ -z "$filesize" ]] && filesize=0

	local len=$filesize suff=B num=1
	[[ $len -ge       1000 ]] && suff="K" &&        num=1000
	[[ $len -ge    1000000 ]] && suff="M" &&     num=1000000
	[[ $len -ge 1000000000 ]] && suff="G" &&  num=1000000000
	local sz=$(( len / num)).$(( (10*len / num) % 10)) # 0.0X - 999.9Y
	[[ $len == 0 ]] && sz="?.?"
	sz="$sz$suff"

	if [[ -z "$format" ]]; then
		REPLY="$len $filename $sz"
	else
		printf -v REPLY "%6s %s" "$sz" "$filename"
	fi
}

####################################
# Headers
####################################
URL_headers()
{
	if [[ "$URL_BACKEND" == curl ]]; then
        URL_headers_curl "$@"
    else
        URL_headers_ps_WebRequest "$@"
	fi
}
URL_headers_FORCE()
{
	if [[ "$URL_BACKEND" == curl ]]; then
		if ! URL_headers_curl "$@"; then
    		URL_headers_curl_FORCE "$@"
        fi
	else
		URL_headers_ps_WebClient "$@"
	fi
}
URL_headers_curl()	# only headers
{
	curl $__CURL_OPT ${URL_TIMEOUT_SEC:+ --connect-timeout $URL_TIMEOUT_SEC} -L -I "$@"
}
URL_headers_curl_FORCE() # start download
{
	local stderr=$(mktemp url_headers.XXXXXX)
	set +e; # note, with --max-filesize curl doesn't print 'Content-Length' header
	curl $__CURL_OPT ${URL_TIMEOUT_SEC:+ --connect-timeout $URL_TIMEOUT_SEC} -L "$@" \
        --max-time 5 --limit-rate 10K --dump-header - -o . 2>"$stderr"
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
	local url=$1
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
	local url=$1
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
	if [[ "$URL_BACKEND" == curl ]]; then
		URL_download_curl "$@"
	else
		URL_download_ps "$@"
	fi
}

URL_download_curl()
{
	local url=$1; shift
	local dst=$1; shift
	curl $__CURL_OPT ${URL_TIMEOUT_SEC:+ --connect-timeout $URL_TIMEOUT_SEC} -o "$dst" "$url"
}

URL_download_ps()
{
	local url=$1; shift
	local dst=$1; shift
	local script_show_proxy=$(cat <<-'SCRIPT'
        {
            try {
                $url='http://google.com'
				$progressPreference = 'silentlyContinue' 
				$ErrorActionPreference = 'Stop';
				$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
				if ($proxy) {
					$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials;
					$proxyUrl = $proxy.GetProxy($url);
					if ($proxyUrl -eq $url) {
    	        		Write-Host "url.sh: no proxy";
					} else {
    	        		Write-Host "url.sh: using proxy $proxyUrl";
                    }
				}
			} catch {
				Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)

	local script_WebRequest=$(cat <<-'SCRIPT'
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
            #		Write-Host "using proxy: $proxyUrl";
					Invoke-WebRequest -Uri $url -OutFile $dst -UseDefaultCredentials -Proxy "$proxyUrl" -ProxyUseDefaultCredentials;
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
	local script_WebClient=$(cat <<-'SCRIPT'
		{
	    	Param([Uri] $url, $dst)
            try {
				$ErrorActionPreference = "Stop";
				$c = new-object System.Net.WebClient;
				$c.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials;
				$c.DownloadFile($url, $dst);
			} catch {
            	Write-Output $_;
				exit 1
			}
		}
		SCRIPT
	)

	if [[ ${SHOW_PROXY:-0} == 0 ]]; then
		__execute_script_ps front "$script_show_proxy"
		export SHOW_PROXY=1
	fi
    if [[ "$URL_BACKEND" == ps1 ]]; then
        __execute_script_ps front "$script_WebRequest" "$url" "$dst"
    else
        __execute_script_ps back "$script_WebClient" "$url" "$dst"
    fi
}

if [[ "$(basename ${BASH_SOURCE-url.sh})" == "$(basename $0)" ]]; then
	entrypoint "$@"
fi
