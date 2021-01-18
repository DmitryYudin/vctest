export CURL_OPT=" -H \"Authorization: token $(cat github_token.txt)\" -H \"Accept: application/vnd.github.v3.raw\""
 
./core/download.sh -i download.txt "$@"