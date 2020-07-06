set -eu -o pipefail

USE_POWERSHELL=1
# Sometimes, power-shell does not return error status as expected,
# but it is more NTLM proxy friendly than curl.
. ./core/url.sh $( [[ $USE_POWERSHELL == 1 ]] && echo ps || echo curl )

notify() {
	echo ""
	echo "You need to install Intel MediaSdk to make hardware encoder workable:"
	echo "    https://software.intel.com/en-us/media-sdk/choose-download/client"
	if [[ $USE_POWERSHELL == 1 ]]; then
		echo ""
		echo "In case of problems with downloading executable modules through the"
		echo "corporate proxy, make sure that 'Protection Mode' is disabled in"
		echo "Internet Explorer settings:"
		echo "    IE -> Internet Options -> Security -> Enable Protection Mode"
	fi
	echo ""
}
#readonly KEEP_CACHE=1

readonly dirBin=bin
readonly dirVec=vectors
readonly SevenZipExe=$dirBin/7z
readonly ffmpegExe=$dirBin/ffmpeg

readonly URLS=$(cat <<'EOT'
	# ffmpeg
	https://ffmpeg.zeranoe.com/builds/win64/static/ffmpeg-20200525-6268034-win64-static.zip

	# Encoders
	https://software.intel.com/sites/default/files/managed/61/d0/MediaSamples_MSDK_2017_8.0.24.271.msi
	https://github.com/ksvc/ks265codec/raw/master/win/AppEncoder_x64.exe
	https://github.com/ksvc/ks265codec/raw/master/android_arm64/appencoder
	https://github.com/ultravideo/kvazaar/releases/download/v1.3.0/Win64-Release.zip
	https://builds.x265.eu/x265-64bit-8bit-latest.exe

	# ARC
	https://github.com/DmitryYudin/encoders_pk_script/raw/master/bin/ASHEVCEnc.dll
	https://github.com/DmitryYudin/encoders_pk_script/raw/master/bin/VMFPlatform.dll
	https://github.com/DmitryYudin/encoders_pk_script/raw/master/bin/cli_ashevc.exe
	https://github.com/DmitryYudin/encoders_pk_script/raw/master/bin/ashevc_example.cfg

	# Vectors
	http://trace.eas.asu.edu/yuv/akiyo/akiyo_qcif.7z
	http://trace.eas.asu.edu/yuv/akiyo/akiyo_cif.7z
	http://trace.eas.asu.edu/yuv/foreman/foreman_qcif.7z
	http://trace.eas.asu.edu/yuv/foreman/foreman_cif.7z

	https://storage.googleapis.com/media.webmproject.org/devsite/vp9/bitrate-modeling/output/Q_g_1_crf_0_120s_tears_of_steel_1080p.webm

	https://media.xiph.org/video/derf/y4m/FourPeople_1280x720_60.y4m
	https://media.xiph.org/video/derf/y4m/Johnny_1280x720_60.y4m
	https://media.xiph.org/video/derf/y4m/KristenAndSara_1280x720_60.y4m
	https://media.xiph.org/video/derf/y4m/720p5994_stockholm_ter.y4m
	https://media.xiph.org/video/derf/y4m/speed_bag_1080p.y4m
	https://media.xiph.org/video/derf/y4m/vidyo1_720p_60fps.y4m
	https://media.xiph.org/video/derf/y4m/vidyo3_720p_60fps.y4m
	https://media.xiph.org/video/derf/y4m/vidyo4_720p_60fps.y4m

	#https://www.itu.int/wftp3/av-arch/video-site/sequences/

	#description:https://tools.ietf.org/id/draft-ietf-netvc-testing-06.html
	#https://people.xiph.org/~tdaede/sets/
	#http://medialab.sjtu.edu.cn/web4k/index.html

	#https://github.com/google/compare-codecs
	#http://downloads.webmproject.org/ietf_tests/desktop_640_360_30.yuv.xz
	http://downloads.webmproject.org/ietf_tests/gipsrecmotion_1280_720_50.yuv.xz
	http://downloads.webmproject.org/ietf_tests/gipsrecstat_1280_720_50.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/kirland_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/macmarcomoving_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/macmarcostationary_640_480_30.yuv.xz
	http://downloads.webmproject.org/ietf_tests/niklas_1280_720_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/niklas_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/tacomanarrows_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/tacomasmallcameramovement_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/thaloundeskmtg_640_480_30.yuv.xz
	#http://downloads.webmproject.org/ietf_tests/vp8_vs_h264.tar.xz
EOT
)

entrypoint()
{
	local dirLog=$dirVec/log
	local dirCache=$dirVec/cache
	local url=

	notify

	local oldIFS=$IFS
	IFS=$'\n';
	for url in $URLS; do
		IFS=$oldIFS
		url=${url#"${url%%[! $'\t']*}"}; # leading spaces
		case $url in '#'*) continue; esac

		local name=$(basename "$url")
		local dst="$dirCache/$name"

		mkdir -p "$dirLog" "$dirCache"
		if [[ -f "$dirLog/$name.downloaded.stamp" ]]; then
			echo "Already downloaded $url"
		else
			echo "Downloading $url -> $dst"			
			URL_download "$url" "$dst" || { echo "Download failed" >&2 && return 1; }

			rm -f "$dirLog/$name.unpacked.stamp"
			date "+%Y.%m.%d-%H.%M.%S" > "$dirLog/$name.downloaded.stamp"
		fi

		if [[ -f "$dirLog/$name.unpacked.stamp" ]]; then
			echo "Already unpacked $dst"
		else
			echo "Unpacking $dst"
			local ffmpeg="$ffmpegExe -hide_banner -y -loglevel error -nostats"
			case $name in
				ffmpeg-*)
					$SevenZipExe e -y "$dst" -o"$dirBin" -i"!*/bin/ffmpeg.exe" -i"!*/bin/ffprobe.exe" > /dev/null;;
#
# Encoder
#
				MediaSamples_MSDK_*)
					mkdir -p "$dirBin/windows/intel"
					$SevenZipExe x -y "$dst" -o"$dirBin/tmp_intel" > /dev/null
					mv -f "$dirBin/tmp_intel/File_sample_encode.exe0" "$dirBin/windows/intel/sample_encode.exe"
					rm -rf "$dirBin/tmp_intel"
				;;
				AppEncoder_x64.exe)
					mkdir -p "$dirBin/windows/kingsoft"
					mv -f "$dst" "$dirBin/windows/kingsoft";;
				appencoder)
					mkdir -p "$dirBin/android/kingsoft"
					mv -f "$dst" "$dirBin/android/kingsoft";;
				Win64-Release.zip)
					mkdir -p "$dirBin/windows/kvazaar"
					$SevenZipExe x -y "$dst" -o"$dirBin/windows/kvazaar" > /dev/null ;;
				x265-*)
					mkdir -p "$dirBin/windows/x265"
					mv -f "$dst" "$dirBin/windows/x265/x265.exe";;
				ASHEVCEnc.dll|VMFPlatform.dll|cli_ashevc.exe|ashevc_example.cfg)
					mkdir -p "$dirBin/windows/ashevc"
					mv -f "$dst" "$dirBin/windows/ashevc/";;
#
# Vectors
#
				*.7z)
					$SevenZipExe x -y "$dst" -o"$dirVec" > /dev/null ;;
				Q_g_1_crf_0_120s_tears_of_steel_1080p.webm)
					$ffmpeg -i "$dst" "$dirVec/tears_of_steel_1920x800_24.webm.yuv" > /dev/null
					#$ffmpeg -s 1920x800 -i "$dirVec/tears_of_steel_1920x800_24.webm.yuv" -vf scale=-1:720 "$dirVec/tears_of_steel_1728x720_24.webm.yuv" > /dev/null
					$ffmpeg -s 1920x800 -i "$dirVec/tears_of_steel_1920x800_24.webm.yuv" -vf scale=-1:720,crop=1280:720 "$dirVec/tears_of_steel_1280x720_24.webm.yuv" > /dev/null
					;;
				FourPeople_1280x720_60.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/FourPeople_1280x720_30.y4m.yuv" > /dev/null ;;
				Johnny_1280x720_60.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/Johnny_1280x720_30.y4m.yuv" > /dev/null ;;
				KristenAndSara_1280x720_60.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/KristenAndSara_1280x720_30.y4m.yuv" > /dev/null ;;
				720p5994_stockholm_ter.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/stockholm_ter_1280x720_30.y4m.yuv" > /dev/null ;;
				speed_bag_1080p.y4m)
					$ffmpeg -i "$dst" -vf scale=-1:720,format=yuv420p "$dirVec/speed_bag_720p_30.y4m.yuv" > /dev/null ;;
				vidyo1_720p_60fps.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/vidyo1_720p_30fps.y4m.yuv" > /dev/null ;;
				vidyo3_720p_60fps.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/vidyo3_720p_30fps.y4m.yuv" > /dev/null ;;
				vidyo4_720p_60fps.y4m)
					$ffmpeg -i "$dst" -r 30 "$dirVec/vidyo4_720p_30fps.y4m.yuv" > /dev/null ;;
				*.xz)
					$SevenZipExe x -y "$dst" -o"$dirCache" > /dev/null
					case $name in
						gipsrecmotion_1280_720_50.yuv.xz)
							mv "$dirCache/${name%.xz}" "$dirVec/gipsrecmotion_1280x720_25.yuv" > /dev/null ;;
						gipsrecstat_1280_720_50.yuv.xz)
							mv "$dirCache/${name%.xz}" "$dirVec/gipsrecstat_1280x720_25.yuv" > /dev/null ;;
						niklas_1280_720_30.yuv.xz)
							mv "$dirCache/${name%.xz}" "$dirVec/niklas_1280x720_30.yuv" > /dev/null ;;
					esac
					;;
			esac
			date "+%Y.%m.%d-%H.%M.%S" > "$dirLog/$name.unpacked.stamp"

			if [[ "${KEEP_CACHE:-}" != 1 ]]; then
				rm -rf "$dirCache"
			fi
		fi
	done

	notify

	echo Done
}

entrypoint "$@"
