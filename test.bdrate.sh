set -eu -o pipefail

# first codec used as the reference
#CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
#CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo"
CODECS="kingsoft; kingsoft --preset ultrafast; kingsoft --preset superfast; kingsoft --preset fast"

# 4 point required
case 0 in
	0)	PRMS=" 60    80  120   150"
		VECTORS="akiyo_qcif.yuv foreman_qcif.yuv" # fast check
	;;
	1)	PRMS="500  1000 1500  2000"  # BR
		#PRMS="28 34 39 44"          # QP
		VECTORS="\
			tears_of_steel_1280x720_24.webm.yuv\
			FourPeople_1280x720_30.y4m.yuv\
			stockholm_ter_1280x720_30.y4m.yuv\
			vidyo4_720p_30fps.y4m.yuv\
		"
	;;
esac
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)

./core/bdrate.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o "bdrate.log" -r "report" "$@"
