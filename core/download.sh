#!/bin/bash
#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/url.sh"
. "$dirScript/db.sh"
. "$dirScript/utility_functions.sh"

notify() {
	cat	<<-EOT
	Install Intel MediaSdk to make hardware encoder workable:
	    https://software.intel.com/en-us/media-sdk/choose-download/client

	Executables downloading with 'powershell' may be blocked. To fix that,
	make sure 'Protection Mode' is disabled:
	    IE -> Internet Options -> Security -> Enable Protection Mode
	EOT
}

readonly DIR_BIN=$(ospath "$dirScript/../bin")
DIR_VEC=$(ospath "$dirScript/../vectors")
INPUT=
ADDR=
readonly DIR_CACHE=$DIR_VEC/cache
case ${OS:-} in 
    *_NT) 
        readonly SevenZipExe=$DIR_BIN/7z
        readonly ffmpegExe=$DIR_BIN/ffmpeg
        readonly ffprobeExe=$DIR_BIN/ffprobe
    ;;
    *)
        readonly SevenZipExe=7z        # apt install p7zip-full
        readonly ffmpegExe=ffmpeg      # apt install ffmpeg
        readonly ffprobeExe=ffprobe
        command -p -v $SevenZipExe &>/dev/null || error_exit "7z not found -> 'apt install p7zip-full'"
        command -p -v $ffmpegExe &>/dev/null || error_exit "ffmpeg not found -> 'apt install ffmpeg'"
        command -p -v $ffprobeExe &>/dev/null || error_exit "ffprobe not found -> 'apt install ffmpeg'"
    ;;
esac

readonly DB_STATUS=0
readonly DB_LEN=1
readonly DB_LEN_HR=2
readonly DB_NAME=3
readonly DB_DST=4

readonly STATUS_INIT=0
readonly STATUS_HAVE_INFO=1
readonly STATUS_DOWNLOADED=2
readonly STATUS_LANDED=3
readonly STATUS_COMPRESSED=4

MAX_FILE_SIZE_MB=1200
MAX_FRAME_SIZE=1280x720

# Sometimes, power-shell does not return error status as expected,
# but it is more NTLM proxy friendly than curl.
DONWLOAD_BACKEND=curl

usage()
{
	cat	<<-EOT
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help         Print help
	    -i|--input        URLs list, one URL per line (default: $INPUT)
	    -d|--dir          Subdirectory of './vectors' directory
	       --addr         Server address propogated to URLs list file as \$ADDR variable
	    --max-res         Video resolution limit in 'WxH' format (default: $MAX_FRAME_SIZE)
	    --max-mb          File size limit in Mb (default: $MAX_FILE_SIZE_MB)
	    --curl            Use 'curl' backend
	    --ps1             Use 'powershell' as WebRequest
	    --ps2             Use 'powershell' as WebClient
	    --map             Print content of the vectors directory grouped by video resolution
	    --stat            Print video vectors statistics

    Default backend option is '$DONWLOAD_BACKEND'

	Examples:
	    $(basename $0) -i download.txt

	EOT

    notify
}

entrypoint()
{
    local START_SEC=$SECONDS
    local do_map= do_stat=
	[[ $# == 0 ]] && usage && exit 1
    while [[ $# -gt 0 ]]; do
        local nargs=2
        case $1 in
            -h|--help)  usage && return;;
            -i|--in*)   INPUT=$2;;
               --addr)  ADDR=$2;;
            -d|--dir)   DIR_VEC=$dirScript/../vectors/$2;;
            --max-res*) MAX_FRAME_SIZE=$2;;
            --max-mb)   MAX_FILE_SIZE_MB=$2;;
            --curl)     DONWLOAD_BACKEND=curl; nargs=1;;
            --ps1)      DONWLOAD_BACKEND=ps1; nargs=1;;
            --ps2)		DONWLOAD_BACKEND=ps2; nargs=1;;
            --map)      do_map=1; nargs=1;;
            --stat)      do_stat=1; nargs=1;;
            *) error_exit "unrecognized option '$1'"
        esac
        shift $nargs
    done

    DIR_VEC=$(ospath "$DIR_VEC")
    [[ -n $do_map || -n $do_stat ]] && { map_vectors "$do_map" "$do_stat"; return; }

	[[ -z "$INPUT" ]] && error_exit "input file not set"

    print_console "Max resolution:   $MAX_FRAME_SIZE\n"
    print_console "Max size (Mb):    $MAX_FILE_SIZE_MB\n"
    print_console "Download backend: $DONWLOAD_BACKEND\n"
    print_console "\n"

    URL_set_backend "$DONWLOAD_BACKEND"
    # It make take more than 40 sec to receive headers from media.xiph.org,
    # but we can't just ignore them since we need 'content-length' to apply size limits
    URL_set_timeout_sec 100

    mkdir -p "$DIR_CACHE"

    local URLs url
    URLs=$(cat "$INPUT" | sed 's/#.*//; /^[[:space:]]*$/d' | { while read -r; do echo "${REPLY//\$ADDR/$ADDR}"; done } )

    progress_begin "[1/5] Init db"
    DB_init "$DIR_CACHE/db.txt" "%1s %12s %6s %50s %-60s"

    for url in $URLs; do
        add_db_entry "$url"
    done
    progress_end

    progress_begin "[2/5] Request info"
    for url in $URLs; do
        request_url_info "$url"
    done
    progress_end

    progress_begin "[3/5] Download to cache"
    for url in $URLs; do
        download_in_cache "$url"
    done
    progress_end

    progress_begin "[4/5] Landing to '$DIR_BIN' and '$DIR_VEC'"
    for url in $URLs; do
        install_from_cache "$url"
    done
    progress_end

    progress_begin "[5/5] Compress cache"
    for url in $URLs; do
        compress_cache "$url"
    done
    progress_end

    map_vectors "" "1"

    return

    local name
    for name in $(echo "${GLOBAL_DST_VALS:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '); do
        echo "$name"
    done
}

PROGRESS_SEC=
progress_begin()
{
    PROGRESS_SEC=$SECONDS
    print_console "$*\n"
}
progress_end()
{
    local duration=$(( SECONDS - PROGRESS_SEC ))
    duration=$(date +%H:%M:%S -u -d @${duration})
    print_console "$duration Done\n"
}

add_db_entry()
{
    local url=$1; shift

    print_console "%8s %-40s\r" "" "$url"

    if DB_add "$url"; then # set status=0 if newly added
        DB_set_item "$url" $DB_STATUS $STATUS_INIT
    fi

    if ! DB_get_item "$url" $DB_STATUS; then
        DB_set_item "$url" $DB_STATUS $STATUS_INIT
    fi
}

request_url_info()
{
    local url=$1; shift
    print_console "%8s %-40s\r" "" "${url##*/}"

    local status name len len_hr
    DB_get_item "$url" $DB_STATUS; status=$REPLY

    if [[ $status -ge $STATUS_HAVE_INFO ]]; then
        DB_get_item "$url" $DB_LEN_HR; len_hr=$REPLY

        print_console "%8s %-40s\r" "$len_hr" "${url##*/}"
        return
    fi

    print_console "%8s %-40s %s\r" "" "${url##*/}" "request info..."

    local info
    URL_info "$url"; info=$REPLY

    len=$(echo "$info" | cut -s -d' ' -f1)
    len_hr=$(echo "$info" | cut -s -d' ' -f3)
    name=$(echo "$info" | cut -s -d' ' -f2)
    DB_set_item "$url" $DB_STATUS $STATUS_HAVE_INFO
    DB_set_item "$url" $DB_NAME "$name"
    DB_set_item "$url" $DB_LEN $len
    DB_set_item "$url" $DB_LEN_HR "$len_hr"

    print_console "%8s %-40s\n" "$len_hr" "${url##*/}"
}

is_binary_package()
{
    local name=$1; shift
    case $name in
        ffmpeg-*) : ;;
        MediaSamples_MSDK_*) : ;;
        HM-Win64-Release.zip) : ;;
        ks265codec-master.zip) : ;;
        Win64-Release.zip) : ;;
        x265-64bit*) : ;;
        x265-3*) : ;;
        ASHEVCEnc.dll|VMFPlatform.dll|cli_ashevc.exe|ashevc_example.cfg) : ;;
        vvenc*|vvdec*) : ;;
        *) return 1 ;;
    esac
    return 0
}

download_in_cache()
{
    local url=$1; shift
    print_console "%8s %-40s\r" "" "${url##*/}"

    local status name len len_hr
    DB_get_item "$url" $DB_STATUS; status=$REPLY
    DB_get_item "$url" $DB_NAME; name=$REPLY
    DB_get_item "$url" $DB_LEN; len=$REPLY
    DB_get_item "$url" $DB_LEN_HR; len_hr=$REPLY

    if [[ $status -ge $STATUS_DOWNLOADED ]]; then
        print_console "%8s %-40s\r" "$len_hr" "${url##*/}"
        return
    fi

    check_blacklist() {
        # ignore color space different from 420 if 420 is already present
        BLACKLIST="\
            _mono.y4m _mono_ \
            football_422_cif.y4m \
            claire_qcif-5.994Hz \
            ducks_take_off_444_720p50.y4m   ducks_take_off_422_720p50.y4m \
            in_to_tree_444_720p50.y4m       in_to_tree_422_720p50.y4m \
            old_town_cross_444_720p50.y4m   old_town_cross_422_720p50.y4m \
            park_joy_444_720p50.y4m         park_joy_422_720p50.y4m \
            big_buck_bunny \
            elephants_dream \
            sita_sings_the_blues \
        "
        local url=$1; shift
        local name=${url##*/} i
        for i in $BLACKLIST; do
            case $name in *"$i"*) return 0;; esac
        done
        return 1
    }
    if check_blacklist "$url"; then
        print_console "%8s %-40s %s\n" "$len_hr" "${url##*/}" "blacklisted"
        return
    fi

    if ! is_binary_package "$name"; then
        if [[ -n ${MAX_FILE_SIZE_MB:-} ]]; then
            if [[ $len -gt $(( MAX_FILE_SIZE_MB * 1000000 )) ]]; then
                print_console "%8s %-40s %s\n" "$len_hr" "${url##*/}"\
                    "file size limit: $MAX_FILE_SIZE_MB Mb"
                return
            fi
        fi

        if [[ -n ${MAX_FRAME_SIZE:-} ]]; then
            if detect_resolution_string "$url"; then # try
                local width=${REPLY%x*} height=${REPLY#*x}
                local max_w=${MAX_FRAME_SIZE%x*} max_h=${MAX_FRAME_SIZE#*x}
                local max_sz=$((max_w * max_h))
                if [[ $max_sz -gt 0 && $(( width * height )) -gt $max_sz ]]; then
                    print_console "%8s %-40s %s\n" "$len_hr" "${url##*/}"\
                        "frame size limit: $MAX_FRAME_SIZE"
                    return
                fi
            fi
        fi
    fi

    print_console "%8s %-40s %s\r" "$len_hr" "${url##*/}" "downloading ..."

    local dst="$DIR_CACHE/$name"
    URL_download "$url" "$dst"

    if [[ "$len" != 0 ]]; then
        local numBytes=$(stat -c %s "$dst")
        # 'url.sh' may report wrong 'length' if 'Transfer-Encoding: chunked'
        [[ "$len" -gt "$numBytes" ]] && error_exit "file size does not match "\
                "$len(header) > $numBytes(actual) $dst"
    fi
    DB_set_item "$url" $DB_STATUS $STATUS_DOWNLOADED

    print_console "%8s %-40s\n" "$len_hr" "${url##*/}"
}

install_from_cache()
{
    update_known_dst() {
        # there is no associated arrays in bash, so we use two lists instead
        local url=$1; shift
        local dst=$1; shift
        local known_dst idx=

        set -- ${GLOBAL_DST_VALS:-}
        for known_dst do
            shift
            if [[ "$known_dst" == "$dst" ]]; then
                local source_url idx=$#
                set -- ${GLOBAL_DST_KEYS:-}
                for source_url do # find the source url
                    shift
                    if [[ $idx == $# ]]; then
                        error_exit "can't process '$url' to '$dst'"\
                                   "because this destination is already taken by '$source_url'"
                    fi
                done
            fi
        done
        GLOBAL_DST_KEYS="${GLOBAL_DST_KEYS:-} $url"
        GLOBAL_DST_VALS="${GLOBAL_DST_VALS:-} $dst"
    }

    local url=$1; shift
    print_console "%8s %-40s\r" "" "${url##*/}"

    local status name
    DB_get_item "$url" $DB_STATUS; status=$REPLY
    DB_get_item "$url" $DB_NAME; name=$REPLY

    if [[ $status -lt $STATUS_DOWNLOADED ]]; then # blacklisted
        return
    fi

    local action=landing
    if [[ $status -ge $STATUS_LANDED ]]; then
        if ! DB_get_item "$url" $DB_DST; then
            return
        else
            local dst=$REPLY
            if [[ ${dst%/*} == "$DIR_VEC" ]]; then
                update_known_dst "$url" $REPLY
                return
            else
                # landed in different directory? - re-install it
                DB_set_item "$url" $DB_STATUS $((STATUS_LANDED - 1))

                action=re-landing
            fi
        fi
    fi

    local src="$DIR_CACHE/$name"

    print_console "%8s %-40s %s\r" "" "${url##*/}" "$action ..."

    on_processed() {
        trim_from_left() {
            local str=$1 max=$2 # > 3
            if [[ ${#str} -gt $max ]]; then
                str=...${str: -$(( max - 3 ))}
            fi
            REPLY=$str
        }
        local url=$1 dst=$2 name
        DB_set_item $url $DB_STATUS $STATUS_LANDED
        DB_get_item $url $DB_NAME; name=$REPLY
        trim_from_left "$dst" 50; dst=$REPLY
        print_console "%8s %-40s -> %s\n" "ok" "$name" "$dst"
    }

    # Binaries here
    if is_binary_package "$name"; then
        case $name in
            ffmpeg-*)
                dst=$DIR_BIN
                $SevenZipExe e -y "$src" -o"$dst" -i"!*/bin/ffmpeg.exe" -i"!*/bin/ffprobe.exe" >/dev/null
            ;;
            MediaSamples_MSDK_*)
                dst="$DIR_BIN/windows/intel"
                $SevenZipExe x -y "$src" -o"$dst" -i"!*File_sample_encode.exe0" >/dev/null
                mv "$dst/File_sample_encode.exe0" "$dst/sample_encode.exe"
            ;;
            HM-Win64-Release.zip)
                dst="$DIR_BIN"
                $SevenZipExe x -y "$src" -o"$dst" >/dev/null
            ;;
            ks265codec-master.zip)
                dst="$DIR_BIN/.../kingsoft"
                $SevenZipExe e -y "$src" -o"$DIR_BIN/android/kingsoft" -i!"ks265codec-master/android_arm64/*" >/dev/null
                $SevenZipExe e -y "$src" -o"$DIR_BIN/linux-intel/kingsoft" -i!"ks265codec-master/ubuntu_x64/*" >/dev/null
                $SevenZipExe e -y "$src" -o"$DIR_BIN/windows/kingsoft" -i!"ks265codec-master/win/*" >/dev/null
                chmod +777 "$DIR_BIN/android/kingsoft/"* "$DIR_BIN/linux-intel/kingsoft/"*
            ;;
            Win64-Release.zip)
                dst="$DIR_BIN/windows/kvazaar"
                $SevenZipExe x -y "$src" -o"$dst" >/dev/null
            ;;
            x265-64bit*)
                dst="$DIR_BIN/windows/x265"
                make_link "$dst" "$src"
            ;;
            x265-3*)
                dst="$DIR_BIN/windows/x265"
                $SevenZipExe x -y "$src" -o"$dst" -i"!x265-8b.exe" >/dev/null
                mv "$dst/x265-8b.exe" "$dst/x265.exe"
            ;;
            vvenc*)
                dst="$DIR_BIN/windows/vvenc"
                $SevenZipExe x -y "$src" -o"$dst" -i"!vvencapp.exe" >/dev/null
            ;;
            vvdec*)
                dst=$DIR_BIN
                $SevenZipExe x -y "$src" -o"$dst" >/dev/null
            ;;
            ASHEVCEnc.dll|VMFPlatform.dll|cli_ashevc.exe|ashevc_example.cfg)
                dst="$DIR_BIN/windows/ashevc"
                make_link "$DIR_BIN/windows/ashevc" "$src"
            ;;
            *) error_exit "unknown package '$name'"
            ;;
        esac
        on_processed "$url" "$dst"
        return 0
    fi

    # Anything not caught above is considered as a test sequence
    mkdir -p "$DIR_VEC"

    local unzipped=
    case $name in
        *.7z|*.xz) # hopfully the content is a single file
            mkdir -p "$DIR_CACHE/temp"
            $SevenZipExe x -y "$src" -o"$DIR_CACHE/temp" >/dev/null
            name=$(command ls "$DIR_CACHE/temp" | tr $'\n' ' ')
            name=${name% }
            [[ ${name// /} != ${name} ]] && error_exit "invalid archive content: [$name]"
            src="$DIR_CACHE/temp/$name"

            unzipped=1
        ;;
    esac

    # just in case we have original source recompressed then removed
    if [[ ! -f "$src" && -f "$src.nut" ]]; then
        print_console "%8s %-40s %s\r" "" "${url##*/}" "decompress from $src.nut"
        mkdir -p "$DIR_VEC/temp"
        ffmpeg -i "$src.nut" "$DIR_VEC/temp/$name" >/dev/null
        mv "$DIR_VEC/temp/$name" "$src" >/dev/null
        rm -d "$DIR_VEC/temp"
    fi

    local width= height= fps=
    case $name in
        *.yuv)
            detect_resolution_string "$name"; width=${REPLY%x*}; height=${REPLY#*x};
            detect_framerate_string "$name"; fps=$REPLY
        ;;
        *.y4m)
            # get content size and FPS value
            local info=
            info=$(ffprobe -show_streams "$src" | tr -d $'\\r')

            # Format:
            #   avg_frame_rate=30000/1001
            #   width=176
            #   height=144
            local avg_frame_rate=
            width=$(echo "$info" | grep "^width=" | cut -d'=' -f 2)
            height=$(echo "$info" | grep "^height=" | cut -d'=' -f 2)
            avg_frame_rate=$(echo "$info" | grep "avg_frame_rate=" | cut -d '=' -f 2)
            fps=$(echo $fps | awk "{ print int($avg_frame_rate + .5) }")
            while [[ $fps -gt 30 ]]; do
                fps=$(( fps /2 ))
            done
        ;;
        *) error_exit "unknown package $name"
        ;;
    esac

    # remove picture size and FPS info from file name
    get_moviename() {
        local url=$1; shift

        local name=$url
        name=${name##*/} # dir
        name=${name%%.*} # ext
        local tokens=$name
        tokens=${tokens//_/ } # '_' -> ' '
        tokens=${tokens//-/ } # '-' -> ' '
        local token= retval=
        for token in $tokens; do
            case $token in [0-9]*) continue; esac
            case $token in ntsc|sqsif|qsif|sif|pal|sqcif|qcif|cif) continue; esac
            case $token in NTSC|sqsif|QSIF|SIF|PAL|SQCIF|QCIF|CIF) continue; esac
            retval=${retval}_${token}
        done
        retval=${retval#_}
        REPLY=$retval
    }
    local moviename
    get_moviename "$name"; moviename=${REPLY}_${width}x${height}_${fps}fps.yuv

    local dst="$DIR_VEC/$moviename"
    update_known_dst "$url" "$dst"
    DB_set_item "$url" $DB_DST "$dst"

    case $name in
        *.yuv)
            if [[ -n $unzipped ]]; then
                mv -f "$src" "$dst"
            else
                make_link "$DIR_VEC" "$src" "$moviename"
            fi
        ;;
        *.y4m)
            ffmpeg -i "$src" -r $fps -vf format=yuv420p "$dst"  >/dev/null

            # remove source if extracted from archive
            [[ -n $unzipped ]] && rm -f "$src"
        ;;
        *) error_exit "unknown package $name"
        ;;
    esac
    rm -f -d "$DIR_CACHE/temp"
    on_processed "$url" "$dst"
}

compress_cache()
{
    local url=$1; shift
    print_console "%8s %-40s\r" "" "${url##*/}"

    local status name
    DB_get_item "$url" $DB_STATUS; status=$REPLY
    DB_get_item "$url" $DB_NAME; name=$REPLY

    [[ $status -lt $STATUS_DOWNLOADED ]] && return # blacklisted
    [[ $status -ge $STATUS_COMPRESSED ]] && return

    local src="$DIR_CACHE/$name"

    case $name in
        *.y4m) :;;
        *.yuc) return;; # TODO
        *) return;;
    esac

    print_console "%8s %-40s %s\r" "" "${url##*/}" "compress ..."

    local dst="$src.nut"
    ffmpeg -i "$src" -vcodec ffv1 -level 3 -f nut -threads 4 -coder 1 -context 1 -g 1 -slices 4 "$dst" >/dev/null
    rm -f "$src"

    DB_set_item "$url" $DB_STATUS $STATUS_COMPRESSED

    print_console "%8s %-40s -> %s\n" "ok" "${url##*/}" "$dst"
}

ffmpeg()
{
    command $ffmpegExe -y -hide_banner -loglevel error -nostats "$@"
}
ffprobe()
{
    command $ffprobeExe -loglevel error "$@"
}

map_vectors()
{
    local do_map=$1; shift
    local do_stat=$1; shift
    local filename resolutions res

    # map[WxH]="file1 file2 ..."
    declare -A map
    for filename in "$DIR_VEC/"*.yuv; do
        case $filename in *"*.yuv") error_exit "no vectors found in '$DIR_VEC'"; esac
        filename=${filename##*/}
        filename=${filename%%$'\r'}
        detect_resolution_string "$filename"; res=$REPLY
        map["$res"]+="$filename "
    done

    # collect keys
    resolutions=$(for i in "${!map[@]}"; do echo "$i"; done | sort -n | { while read -r; do printf "$REPLY "; done; } )

    # prefix with subdir
    local dirVec=$(ospath "$dirScript/../vectors")
    local pref=${DIR_VEC#$dirVec};
    pref=${pref#/}
    [[ -n "$pref" ]] && pref=$pref/

    # print map
    if [[ -n "$do_map" ]]; then
        for res in $resolutions; do
            echo "vec_$res="'"\'

            set -- ${map[$res]}
            { for filename; do echo "$pref$filename"; done } | sort |
            { while read -r; do echo "    $REPLY \\"; done; }

            echo '"'
        done
    fi

    if [[ -n "$do_stat" ]]; then
        printf "# $pref\n"
        local countTot=0
        local bytesTot=0
        for res in $resolutions; do
            local numBytesTot=0
            set -- ${map[$res]}
            for filename; do
            	local numBytes=$(stat -c %s "$DIR_VEC/$filename")
                numBytesTot=$(( numBytesTot + numBytes ))
            done
            countTot=$(( countTot + $# ))
            bytesTot=$(( bytesTot + numBytesTot ))
            human_readable_bytes "$numBytesTot"; numBytesTot=$REPLY
            printf "# %9s %4s %6s\n" "$res" "$#" "$numBytesTot"
        done
        human_readable_bytes "$bytesTot"; bytesTot=$REPLY
        printf "# %9s %4s %6s\n" "Total:" "$countTot" "$bytesTot"
    fi
}

entrypoint "$@"
